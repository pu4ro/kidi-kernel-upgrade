# RHEL kernel upgrade + Kubernetes verification (make-driven, .env-configurable)
#
# Two phases (all values configurable via .env - see .env.example):
#
# Phase 1 - Install Kubernetes (kubeadm single control-plane node):
#   make set-dns DNS_SERVER=8.8.8.8   # only if the node has no working DNS
#   make k8s-install                  # k8s-prep + k8s-pkgs + k8s-init
#   make verify-k8s                   # baseline: cluster healthy before upgrade
#
# Phase 2 - Upgrade the OS/kernel (EXPECTED_CURRENT -> TARGET_VERSION via ISO):
#   make prepare                      # preflight + mount + repo + backup
#   make upgrade                      # full dnf upgrade from the ISO repo
#   <reboot>
#   make commit                       # verify + verify-k8s + set-default
#
# Recovery:
#   make rollback                     # boot the pre-upgrade kernel
#   make k8s-reset                    # tear down the cluster (kubeadm reset)
#   make clean                        # unmount ISO, remove generated repo files

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.SILENT:

# ---- Configurable variables ----
# Precedence: command-line args > .env file > defaults below.
# Copy .env.example to .env to set values without touching the Makefile.
-include .env

# ---- Target OS / ISO (override in .env) ----
# ISO              : path to the TARGET-version DVD ISO
# MOUNT            : where the ISO is loop-mounted
# EXPECTED_CURRENT : current (source) OS minor version
# TARGET_VERSION   : target OS minor version (present on the ISO)
# FORCE=1          : skip the current-version check
ISO              ?= rhel-9.6.iso
MOUNT            ?= /mnt/rhel-iso
EXPECTED_CURRENT ?= 9.3
TARGET_VERSION   ?= 9.6
BACKUP_ROOT      ?= backup
FORCE            ?= 0

# ---- Package-level rollback (downgrade to EXPECTED_CURRENT) ----
# SOURCE_ISO   : DVD ISO of the current/source version (for 'make rollback-pkgs')
# SOURCE_MOUNT : where the source ISO is mounted
# UNDO_ID      : dnf history transaction id of the upgrade to undo (see 'dnf history list')
SOURCE_ISO   ?=
SOURCE_MOUNT ?= /mnt/rhel-src
UNDO_ID      ?=

# Custom repo support (used in ADDITION to the ISO repo).
# Case A - repo already configured on the system: list its id(s) here
#          (comma-separated), e.g. EXTRA_REPOS=internal,thirdparty
EXTRA_REPOS        ?=
# Case B - let this Makefile create the repo: give it an id + baseurl.
CUSTOM_REPO_ID     ?=
CUSTOM_REPO_URL    ?=
CUSTOM_REPO_GPGKEY ?=

# Kubernetes verification (verify-k8s): kubeconfig used to reach the API.
# On a control-plane node this lets us check node Ready + kube-system pods.
KUBECONFIG         ?= /etc/kubernetes/admin.conf

# ---- Kubernetes install (kubeadm single control-plane node) ----
# LOCAL_RPM_REPO : createrepo'd dir with k8s + containerd RPMs
# K8S_VERSION    : kubeadm/kubelet/kubectl version to install
# POD_CIDR       : pod network CIDR (Flannel default)
# CRI_SOCKET     : CRI endpoint (containerd)
# FLANNEL_URL    : CNI manifest applied after kubeadm init
# DNS_SERVER     : if set, 'make set-dns' writes it to /etc/resolv.conf
LOCAL_RPM_REPO  ?= /root/repo
# Directory of .rpm files to index with 'make local-repo' (defaults to LOCAL_RPM_REPO).
RPM_SRC         ?= $(LOCAL_RPM_REPO)
K8S_VERSION     ?= 1.23.17
POD_CIDR        ?= 10.244.0.0/16
CRI_SOCKET      ?= /run/containerd/containerd.sock
FLANNEL_URL     ?= https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
DNS_SERVER      ?=

# ---- Internal constants ----
REPO_FILE := /etc/yum.repos.d/rhel-iso.repo
REPO_GLOB := rhel-iso-*
MARKER    := managed-by-kidi-kernel-upgrade

# Repos enabled during the transaction: ISO repos + extras + created custom repo.
# Everything else is disabled (offline-safe).
ENABLE_LIST := $(REPO_GLOB)
ifneq ($(strip $(EXTRA_REPOS)),)
ENABLE_LIST := $(ENABLE_LIST),$(EXTRA_REPOS)
endif
ifneq ($(strip $(CUSTOM_REPO_ID)),)
ENABLE_LIST := $(ENABLE_LIST),$(CUSTOM_REPO_ID)
endif
DNF_ARGS := --disablerepo=* --enablerepo=$(ENABLE_LIST)

.PHONY: help set-dns local-repo k8s-prep k8s-pkgs k8s-init k8s-install k8s-reset k8s-status \
        preflight mount repo backup upgrade verify verify-k8s set-default commit \
        rollback rollback-pkgs prepare status clean

help:
	@echo "RHEL $(EXPECTED_CURRENT) -> $(TARGET_VERSION) kernel upgrade + Kubernetes verification"
	@echo
	@echo "Phase 1 - install Kubernetes (run as root):"
	@echo "  set-dns     Write DNS_SERVER to /etc/resolv.conf (air-gapped DNS fix)"
	@echo "  local-repo  Build repodata (createrepo_c) on a dir of RPMs (RPM_SRC)"
	@echo "  k8s-prep    swap off, SELinux permissive, firewalld off, modules, sysctl"
	@echo "  k8s-pkgs    Install containerd + kubelet/kubeadm/kubectl from LOCAL_RPM_REPO"
	@echo "  k8s-init    Pull images, kubeadm init, kubeconfig, Flannel CNI, untaint"
	@echo "  k8s-install k8s-prep + k8s-pkgs + k8s-init"
	@echo "  k8s-reset   Tear down the cluster (kubeadm reset)"
	@echo "  k8s-status  Show nodes and pods"
	@echo
	@echo "Phase 2 - upgrade OS/kernel (run as root):"
	@echo "  preflight   Check root, ISO, current version, disk space"
	@echo "  mount       Loop-mount the ISO read-only at $(MOUNT)"
	@echo "  repo        Write the ISO repo (+ optional custom repo)"
	@echo "  backup      Snapshot current kernel/boot/package state"
	@echo "  upgrade     dnf upgrade the whole system from the enabled repos"
	@echo "  verify      Post-reboot check that the system is on $(TARGET_VERSION)"
	@echo "  verify-k8s  Post-reboot health check of the existing Kubernetes node"
	@echo "  set-default Set the newest installed kernel as the default boot entry"
	@echo "  commit      verify + verify-k8s + set-default (default set only if all pass)"
	@echo "  rollback    Set the default boot entry back to the pre-upgrade kernel"
	@echo "  rollback-pkgs  Downgrade packages to EXPECTED_CURRENT (dnf history undo UNDO_ID)"
	@echo "  status      Show current kernel / default boot / release / mount"
	@echo "  prepare     preflight + mount + repo + backup"
	@echo "  clean       Unmount the ISO and remove generated repo files"
	@echo
	@echo "Variables: ISO=$(ISO) TARGET_VERSION=$(TARGET_VERSION) K8S_VERSION=$(K8S_VERSION)"
	@echo "Repos enabled for upgrade: $(ENABLE_LIST)"

# Fail fast with a clear message if not running as root.
define require_root
	if [[ "$$(id -u)" -ne 0 ]]; then
		echo "ERROR: must run as root." >&2
		exit 1
	fi
endef

# ============================ Phase 1: Kubernetes ============================

set-dns:
	$(require_root)
	if [[ -z "$(DNS_SERVER)" ]]; then
		echo "ERROR: set DNS_SERVER (e.g. make set-dns DNS_SERVER=8.8.8.8)." >&2
		exit 1
	fi
	echo "==> Setting DNS to $(DNS_SERVER)"
	[[ -f /etc/resolv.conf.kidi.bak ]] || cp -a /etc/resolv.conf /etc/resolv.conf.kidi.bak 2>/dev/null || true
	printf 'nameserver %s\n' "$(DNS_SERVER)" > /etc/resolv.conf
	if getent hosts registry.k8s.io >/dev/null 2>&1; then
		echo "    DNS OK (registry.k8s.io resolves)."
	else
		echo "WARNING: still cannot resolve registry.k8s.io." >&2
	fi

local-repo:
	$(require_root)
	echo "==> Building local RPM repo metadata in $(RPM_SRC)"
	if [[ ! -d "$(RPM_SRC)" ]]; then
		echo "ERROR: $(RPM_SRC) not found." >&2
		exit 1
	fi
	if [[ -z "$$(find "$(RPM_SRC)" -maxdepth 2 -name '*.rpm' -print -quit)" ]]; then
		echo "ERROR: no .rpm files under $(RPM_SRC)." >&2
		exit 1
	fi
	if ! command -v createrepo_c >/dev/null 2>&1; then
		echo "    createrepo_c missing; installing from the ISO repo..."
		dnf -y --disablerepo=* --enablerepo=$(REPO_GLOB) install createrepo_c >/dev/null 2>&1 \
			|| { echo "ERROR: install createrepo_c first (e.g. 'make mount repo', then retry)." >&2; exit 1; }
	fi
	createrepo_c --update "$(RPM_SRC)"
	echo "    repodata files: $$(ls "$(RPM_SRC)/repodata" 2>/dev/null | wc -l)"
	echo "==> Local repo ready at $(RPM_SRC) (point LOCAL_RPM_REPO here for k8s-pkgs)."

k8s-prep:
	$(require_root)
	echo "==> Preparing the node for Kubernetes"
	swapoff -a
	sed -ri 's/^([^#].*[[:space:]]swap[[:space:]].*)$$/#\1/' /etc/fstab
	setenforce 0 2>/dev/null || true
	sed -ri 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
	systemctl disable --now firewalld >/dev/null 2>&1 || true
	printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
	modprobe overlay; modprobe br_netfilter
	printf 'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n' > /etc/sysctl.d/k8s.conf
	sysctl --system >/dev/null
	echo "    swap=off selinux=$$(getenforce) modules=$$(lsmod | grep -cE '^(overlay|br_netfilter)') ip_forward=$$(sysctl -n net.ipv4.ip_forward)"
	echo "==> Node prepared."

k8s-pkgs:
	$(require_root)
	echo "==> Installing Kubernetes packages from $(LOCAL_RPM_REPO)"
	if [[ ! -d "$(LOCAL_RPM_REPO)/repodata" ]]; then
		echo "ERROR: $(LOCAL_RPM_REPO)/repodata not found." >&2
		echo "       Build it first: make local-repo RPM_SRC=$(LOCAL_RPM_REPO)" >&2
		exit 1
	fi
	printf '%s\n' \
		"# $(MARKER)" \
		"[kidi-local]" \
		"name=KIDI local k8s bundle" \
		"baseurl=file://$(LOCAL_RPM_REPO)" \
		"enabled=1" \
		"gpgcheck=0" \
		> /etc/yum.repos.d/kidi-local.repo
	dnf -y --disablerepo=* --enablerepo=kidi-local install \
		containerd.io kubelet-$(K8S_VERSION) kubeadm-$(K8S_VERSION) kubectl-$(K8S_VERSION)
	# Configure containerd with the systemd cgroup driver (RHEL 9 / cgroup v2).
	mkdir -p /etc/containerd
	containerd config default > /etc/containerd/config.toml
	sed -ri 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
	printf 'runtime-endpoint: unix://%s\nimage-endpoint: unix://%s\ntimeout: 10\n' "$(CRI_SOCKET)" "$(CRI_SOCKET)" > /etc/crictl.yaml
	systemctl enable --now containerd >/dev/null 2>&1
	systemctl enable kubelet >/dev/null 2>&1
	echo "    installed: $$(rpm -q kubelet kubeadm kubectl containerd.io | tr '\n' ' ')"
	echo "==> Packages installed; containerd active."

k8s-init:
	$(require_root)
	if [[ -f /etc/kubernetes/admin.conf ]]; then
		echo "==> Cluster already initialized. Run 'make k8s-reset' first to redo."
		exit 0
	fi
	echo "==> Pulling control-plane images (k8s v$(K8S_VERSION))"
	kubeadm config images pull --kubernetes-version v$(K8S_VERSION) --cri-socket=$(CRI_SOCKET)
	echo "==> kubeadm init (pod-cidr $(POD_CIDR))"
	kubeadm init --pod-network-cidr=$(POD_CIDR) --kubernetes-version v$(K8S_VERSION) --cri-socket=$(CRI_SOCKET)
	mkdir -p $$HOME/.kube && cp -f /etc/kubernetes/admin.conf $$HOME/.kube/config
	export KUBECONFIG=/etc/kubernetes/admin.conf
	echo "==> Applying Flannel CNI"
	kubectl apply -f "$(FLANNEL_URL)"
	# Single node: allow workloads on the control-plane.
	kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
	kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
	echo "==> Waiting for all pods to become Ready..."
	for i in $$(seq 1 60); do
		notready="$$(kubectl get pods -A --no-headers 2>/dev/null | awk '{split($$3,a,"/"); if(a[1]!=a[2]) c++} END{print c+0}')" || notready=1
		[[ "$$notready" == "0" ]] && { echo "    all pods Ready"; break; }
		sleep 5
	done
	kubectl get nodes
	echo "==> Kubernetes cluster ready."

k8s-install: k8s-prep k8s-pkgs k8s-init
	@echo "==> Kubernetes installed. Run 'make verify-k8s' for a health check."

k8s-reset:
	$(require_root)
	echo "==> Resetting Kubernetes (kubeadm reset)"
	kubeadm reset -f --cri-socket=$(CRI_SOCKET) 2>/dev/null || true
	rm -rf /etc/cni/net.d $$HOME/.kube /etc/kubernetes
	echo "==> Reset done."

k8s-status:
	export KUBECONFIG="$(KUBECONFIG)"
	kubectl get nodes -o wide 2>&1 || true
	echo
	kubectl get pods -A 2>&1 || true

# ========================= Phase 2: OS / kernel =========================

preflight:
	$(require_root)
	echo "==> Preflight checks"
	# 1) ISO file present.
	if [[ ! -f "$(ISO)" ]]; then
		echo "ERROR: ISO not found: $(ISO)" >&2
		echo "       Pass ISO=/path/to/rhel-$(TARGET_VERSION).iso" >&2
		exit 1
	fi
	echo "    ISO: $(ISO) ($$(du -h "$(ISO)" | cut -f1))"
	# 2) Current OS must be the expected starting version (override with FORCE=1).
	current="$$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1 || true)"
	echo "    Current release: $${current:-unknown}"
	if [[ "$${current}" != "$(EXPECTED_CURRENT)" && "$(FORCE)" != "1" ]]; then
		echo "ERROR: expected RHEL $(EXPECTED_CURRENT) but found '$${current}'." >&2
		echo "       Re-run with FORCE=1 to override." >&2
		exit 1
	fi
	# 3) Required tools.
	for t in dnf grubby mount; do
		command -v $$t >/dev/null || { echo "ERROR: missing tool: $$t" >&2; exit 1; }
	done
	# 4) Free space on /var for the download/transaction (warn only).
	avail_kb="$$(df -Pk /var | awk 'NR==2 {print $$4}')"
	if [[ "$${avail_kb}" -lt 2097152 ]]; then
		echo "WARNING: less than 2 GiB free on /var ($$((avail_kb/1024)) MiB)." >&2
	fi
	echo "==> Preflight OK"

mount:
	$(require_root)
	echo "==> Mounting $(ISO) at $(MOUNT)"
	if mountpoint -q "$(MOUNT)"; then
		echo "    Already mounted."
	else
		mkdir -p "$(MOUNT)"
		mount -o loop,ro "$(ISO)" "$(MOUNT)"
	fi
	# Sanity check: a RHEL DVD has BaseOS and AppStream trees.
	for d in BaseOS AppStream; do
		if [[ ! -d "$(MOUNT)/$$d" ]]; then
			echo "ERROR: $(MOUNT)/$$d missing - is this a full RHEL DVD ISO?" >&2
			exit 1
		fi
	done
	echo "==> Mounted."

repo:
	$(require_root)
	echo "==> Writing $(REPO_FILE)"
	if ! mountpoint -q "$(MOUNT)"; then
		echo "ERROR: $(MOUNT) is not mounted. Run 'make mount' first." >&2
		exit 1
	fi
	# Prefer GPG verification when the key ships on the ISO.
	gpgkey="$(MOUNT)/RPM-GPG-KEY-redhat-release"
	if [[ -f "$$gpgkey" ]]; then
		isogpg=1; isogpgline="gpgkey=file://$$gpgkey"
	else
		echo "WARNING: GPG key not found on ISO; disabling gpgcheck." >&2
		isogpg=0; isogpgline=""
	fi
	printf '%s\n' \
		"# $(MARKER)" \
		"[rhel-iso-baseos]" \
		"name=RHEL ISO - BaseOS" \
		"baseurl=file://$(MOUNT)/BaseOS" \
		"enabled=1" \
		"gpgcheck=$$isogpg" \
		"$$isogpgline" \
		"" \
		"[rhel-iso-appstream]" \
		"name=RHEL ISO - AppStream" \
		"baseurl=file://$(MOUNT)/AppStream" \
		"enabled=1" \
		"gpgcheck=$$isogpg" \
		"$$isogpgline" \
		> "$(REPO_FILE)"
	# Optional custom repo: create it from a baseurl if one was provided (Case B).
	if [[ -n "$(CUSTOM_REPO_URL)" ]]; then
		cid="$(CUSTOM_REPO_ID)"
		if [[ -z "$$cid" ]]; then
			echo "ERROR: set CUSTOM_REPO_ID together with CUSTOM_REPO_URL." >&2
			exit 1
		fi
		cfile="/etc/yum.repos.d/$$cid.repo"
		if [[ -n "$(CUSTOM_REPO_GPGKEY)" ]]; then
			cgpg=1; cgpgline="gpgkey=$(CUSTOM_REPO_GPGKEY)"
		else
			cgpg=0; cgpgline=""
		fi
		echo "==> Writing custom repo $$cfile"
		printf '%s\n' \
			"# $(MARKER)" \
			"[$$cid]" \
			"name=Custom repo $$cid" \
			"baseurl=$(CUSTOM_REPO_URL)" \
			"enabled=1" \
			"gpgcheck=$$cgpg" \
			"$$cgpgline" \
			> "$$cfile"
	fi
	echo "    Repos enabled for upgrade: $(ENABLE_LIST)"
	dnf $(DNF_ARGS) makecache
	echo "==> Repo ready."

backup:
	$(require_root)
	ts="$$(date +%Y%m%d-%H%M%S)"
	dir="$(BACKUP_ROOT)/$$ts"
	mkdir -p "$$dir"
	echo "==> Backing up current state to $$dir"
	uname -r                              > "$$dir/running-kernel.txt"
	cat /etc/redhat-release               > "$$dir/release.txt"
	grubby --default-kernel               > "$$dir/default-kernel.txt"
	grubby --info=ALL                     > "$$dir/grub-entries.txt"
	rpm -qa | sort                        > "$$dir/packages.txt"
	dnf history list | head -20           > "$$dir/dnf-history.txt" 2>/dev/null || true
	# Symlink 'latest' so rollback can find the most recent snapshot.
	ln -sfn "$$ts" "$(BACKUP_ROOT)/latest"
	echo "    Saved: kernel=$$(cat "$$dir/running-kernel.txt") default=$$(cat "$$dir/default-kernel.txt")"
	echo "==> Backup done."

upgrade:
	$(require_root)
	echo "==> Upgrading system (installs the $(TARGET_VERSION) kernel)"
	if [[ ! -f "$(REPO_FILE)" ]]; then
		echo "ERROR: $(REPO_FILE) missing. Run 'make repo' first." >&2
		exit 1
	fi
	echo "    Repos enabled for upgrade: $(ENABLE_LIST)"
	dnf -y $(DNF_ARGS) upgrade
	echo
	echo "==> Upgrade transaction complete."
	echo "    New default kernel: $$(grubby --default-kernel)"
	echo "    REBOOT the machine, then run 'make commit' (verify + verify-k8s + set-default)."

verify:
	echo "==> Verifying upgrade"
	current="$$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1 || true)"
	running="$$(uname -r)"
	echo "    Release: $${current:-unknown} (target $(TARGET_VERSION))"
	echo "    Running kernel: $${running}"
	# Newest installed kernel should match the running one after reboot.
	newest="$$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
	echo "    Newest installed kernel-core: $${newest}"
	ok=1
	if [[ "$${current}" != "$(TARGET_VERSION)" ]]; then
		echo "FAIL: release is not $(TARGET_VERSION)." >&2; ok=0
	fi
	if [[ "$${running}" != "$${newest}" ]]; then
		echo "FAIL: running kernel is not the newest installed one (reboot needed?)." >&2; ok=0
	fi
	if [[ "$$ok" -eq 1 ]]; then
		echo "==> VERIFY OK: system is on $(TARGET_VERSION) and booted the new kernel."
	else
		exit 1
	fi

verify-k8s:
	echo "==> Verifying the existing Kubernetes node after the kernel upgrade"
	ok=1
	# 1) Kernel modules required by the CNI / kube-proxy must be loaded.
	for m in overlay br_netfilter; do
		if lsmod | grep -q "^$$m"; then
			echo "    module $$m: loaded"
		else
			echo "FAIL: kernel module $$m not loaded." >&2; ok=0
		fi
	done
	# 2) Required sysctls (br_netfilter must be loaded for the bridge one).
	for kv in "net.ipv4.ip_forward=1" "net.bridge.bridge-nf-call-iptables=1"; do
		key="$${kv%=*}"; want="$${kv#*=}"
		got="$$(sysctl -n "$$key" 2>/dev/null)" || got="missing"
		if [[ "$$got" == "$$want" ]]; then
			echo "    sysctl $$key=$$got"
		else
			echo "FAIL: sysctl $$key=$$got (want $$want)." >&2; ok=0
		fi
	done
	# 3) Swap must stay off after reboot (a kernel/grub change can re-enable it).
	if [[ -z "$$(swapon --show)" ]]; then
		echo "    swap: off"
	else
		echo "FAIL: swap is ON (k8s requires swap off; check /etc/fstab)." >&2; ok=0
	fi
	# 4) Container runtime service active (detect which one).
	rt=""
	for svc in containerd crio docker; do
		if systemctl is-active --quiet "$$svc" 2>/dev/null; then rt="$$svc"; break; fi
	done
	if [[ -n "$$rt" ]]; then
		echo "    runtime: $$rt active"
	else
		echo "FAIL: no container runtime active (containerd/crio/docker)." >&2; ok=0
	fi
	# 5) kubelet active.
	if systemctl is-active --quiet kubelet; then
		echo "    kubelet: active"
	else
		echo "FAIL: kubelet not active." >&2; ok=0
	fi
	# 6) Node-local container check via crictl (works on workers too).
	if command -v crictl >/dev/null 2>&1 && crictl ps >/dev/null 2>&1; then
		running="$$(crictl ps -q 2>/dev/null | wc -l)" || running=0
		echo "    crictl: $$running running container(s)"
	fi
	# 7) Cluster checks when this node can reach the API (control-plane / kubeconfig).
	export KUBECONFIG="$(KUBECONFIG)"
	if command -v kubectl >/dev/null 2>&1 && kubectl get --raw='/readyz' >/dev/null 2>&1; then
		hns="$$(hostname -s 2>/dev/null || true) $$(hostname -f 2>/dev/null || true) $$(hostname 2>/dev/null || true)"
		node=""
		for n in $$hns; do
			if kubectl get node "$$n" >/dev/null 2>&1; then node="$$n"; break; fi
		done
		if [[ -n "$$node" ]]; then
			status="$$(kubectl get node "$$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" || status=""
			if [[ "$$status" == "True" ]]; then
				echo "    node $$node: Ready"
			else
				echo "FAIL: node $$node not Ready (status=$${status:-unknown})." >&2; ok=0
			fi
		else
			echo "WARNING: could not match this host to a k8s node name." >&2
		fi
		notready="$$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -Ev 'Running|Completed' | wc -l)" || notready=0
		if [[ "$$notready" -eq 0 ]]; then
			echo "    kube-system pods: all Running/Completed"
		else
			echo "FAIL: $$notready kube-system pod(s) not healthy." >&2; ok=0
		fi
	else
		echo "    (API not reachable here - node-local checks only; run on a control-plane for cluster checks)"
	fi
	if [[ "$$ok" -eq 1 ]]; then
		echo "==> K8S VERIFY OK"
	else
		echo "==> K8S VERIFY FAILED - do NOT commit; investigate or 'make rollback'." >&2
		exit 1
	fi

set-default:
	$(require_root)
	echo "==> Setting the newest installed kernel as the default boot entry"
	newest="$$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
	vmlinuz="/boot/vmlinuz-$$newest"
	if [[ ! -e "$$vmlinuz" ]]; then
		echo "ERROR: $$vmlinuz not found." >&2
		echo "       Installed kernels:" >&2
		rpm -q kernel-core >&2
		exit 1
	fi
	grubby --set-default="$$vmlinuz"
	echo "    Default kernel is now: $$(grubby --default-kernel)"
	echo "==> Done."

# Make the newest kernel the permanent default ONLY if BOTH the OS check and
# the Kubernetes health check pass (i.e. the upgrade booted cleanly, no problems).
commit: verify verify-k8s set-default
	echo "==> Verified OK (OS + k8s); newest kernel committed as default boot entry."

rollback:
	$(require_root)
	dir="$(BACKUP_ROOT)/latest"
	if [[ ! -e "$$dir/default-kernel.txt" ]]; then
		echo "ERROR: no backup found at $$dir. Cannot determine previous kernel." >&2
		exit 1
	fi
	prev="$$(cat "$$dir/default-kernel.txt")"
	echo "==> Rolling back default boot kernel to: $$prev"
	if [[ ! -e "$$prev" ]]; then
		echo "ERROR: previous kernel $$prev is no longer installed." >&2
		echo "       Available entries:" >&2
		grubby --info=ALL | grep -E '^kernel=' >&2 || true
		exit 1
	fi
	grubby --set-default="$$prev"
	echo "    Default kernel is now: $$(grubby --default-kernel)"
	echo "==> Reboot to boot the previous kernel."
	echo "    NOTE: this reverts the BOOT kernel only. To revert upgraded packages"
	echo "          too, reboot then run 'make rollback-pkgs' (see below)."

# Package-level rollback: downgrade every package the upgrade changed back to
# the EXPECTED_CURRENT version via 'dnf history undo', using the source-version
# ISO as the package source. Run AFTER 'make rollback' + reboot (so the node is
# booted on the pre-upgrade kernel and the new kernel can be removed cleanly).
rollback-pkgs:
	$(require_root)
	echo "==> Package-level rollback (downgrade to RHEL $(EXPECTED_CURRENT))"
	# Guard: must be booted on the pre-upgrade kernel, not the newest one.
	newest="$$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
	if [[ "$$(uname -r)" == "$$newest" ]]; then
		echo "ERROR: running the newest kernel ($$newest)." >&2
		echo "       Run 'make rollback' + reboot first, then re-run this target." >&2
		exit 1
	fi
	# Need the upgrade's transaction id.
	if [[ -z "$(UNDO_ID)" ]]; then
		echo "ERROR: set UNDO_ID=<upgrade transaction id>. Recent dnf history:" >&2
		dnf history list 2>/dev/null | grep -E '^[[:space:]]*[0-9]+ ' | head -8 >&2
		exit 1
	fi
	# Need the source-version ISO to supply the downgrade packages.
	if [[ ! -f "$(SOURCE_ISO)" ]]; then
		echo "ERROR: SOURCE_ISO not found: '$(SOURCE_ISO)' (the $(EXPECTED_CURRENT) DVD ISO)." >&2
		exit 1
	fi
	mkdir -p "$(SOURCE_MOUNT)"
	mountpoint -q "$(SOURCE_MOUNT)" || mount -o loop,ro "$(SOURCE_ISO)" "$(SOURCE_MOUNT)"
	for d in BaseOS AppStream; do
		[[ -d "$(SOURCE_MOUNT)/$$d" ]] || { echo "ERROR: $(SOURCE_MOUNT)/$$d missing." >&2; exit 1; }
	done
	printf '%s\n' \
		"# $(MARKER)" \
		"[rhel-src-baseos]" "name=RHEL source BaseOS" "baseurl=file://$(SOURCE_MOUNT)/BaseOS" "enabled=1" "gpgcheck=0" "" \
		"[rhel-src-appstream]" "name=RHEL source AppStream" "baseurl=file://$(SOURCE_MOUNT)/AppStream" "enabled=1" "gpgcheck=0" \
		> /etc/yum.repos.d/rhel-src.repo
	echo "    Undoing transaction $(UNDO_ID) using the $(EXPECTED_CURRENT) ISO repo..."
	dnf history undo $(UNDO_ID) -y --disablerepo=* --enablerepo=rhel-src-*
	echo
	echo "==> Downgrade complete. Release: $$(cat /etc/redhat-release)"
	echo "    Verify with 'make verify-k8s'; run 'make clean' to drop the source repo."

status:
	echo "Release:        $$(cat /etc/redhat-release 2>/dev/null || echo n/a)"
	echo "Running kernel: $$(uname -r)"
	echo "Default kernel: $$(grubby --default-kernel 2>/dev/null || echo n/a)"
	if mountpoint -q "$(MOUNT)" 2>/dev/null; then
		echo "ISO mount:      $(MOUNT) (mounted)"
	else
		echo "ISO mount:      $(MOUNT) (not mounted)"
	fi
	echo "Repo file:      $$(test -f "$(REPO_FILE)" && echo present || echo absent)"
	echo "Enabled repos:  $(ENABLE_LIST)"

prepare: preflight mount repo backup
	@echo "==> Prepared. Next: 'make upgrade', reboot, then 'make verify' (or 'make commit')."

clean:
	$(require_root)
	echo "==> Cleaning up"
	if [[ -f "$(REPO_FILE)" ]]; then
		rm -f "$(REPO_FILE)"
		echo "    Removed $(REPO_FILE)"
	fi
	# Remove a custom repo file only if THIS tool created it (marker present).
	if [[ -n "$(CUSTOM_REPO_ID)" ]]; then
		cfile="/etc/yum.repos.d/$(CUSTOM_REPO_ID).repo"
		if [[ -f "$$cfile" ]] && grep -q "$(MARKER)" "$$cfile"; then
			rm -f "$$cfile"
			echo "    Removed $$cfile"
		fi
	fi
	if mountpoint -q "$(MOUNT)"; then
		umount "$(MOUNT)"
		echo "    Unmounted $(MOUNT)"
	fi
	# Source-version repo/mount used by rollback-pkgs.
	if [[ -f /etc/yum.repos.d/rhel-src.repo ]]; then
		rm -f /etc/yum.repos.d/rhel-src.repo
		echo "    Removed /etc/yum.repos.d/rhel-src.repo"
	fi
	if mountpoint -q "$(SOURCE_MOUNT)"; then
		umount "$(SOURCE_MOUNT)"
		echo "    Unmounted $(SOURCE_MOUNT)"
	fi
	echo "==> Clean done (backups under $(BACKUP_ROOT)/ are kept)."
