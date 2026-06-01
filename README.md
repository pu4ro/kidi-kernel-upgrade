# RHEL 커널 업그레이드 + Kubernetes 검증 (make 기반)

RHEL/호환 노드에서 **Kubernetes를 설치**하고, **OS/커널을 업그레이드(예: 9.3 → 9.6)**한 뒤
**k8s가 정상 동작하는지 검증**하는 작업을 전부 `make` 타겟으로 관리합니다.
모든 값은 `.env`로 설정합니다.

**저장소:** https://github.com/pu4ro/kidi-kernel-upgrade

> 참고: 9.3 → 9.6은 **마이너 업그레이드**라 `leapp`을 쓰지 않고 `dnf`로 처리합니다.
> 커널 업그레이드는 OS 전체 업데이트로 수행하며, 기존 커널은 남겨 두어 롤백할 수 있습니다.

## 빠른 시작 (Clone & 사용 예시)

```bash
# 1) 저장소 clone
git clone https://github.com/pu4ro/kidi-kernel-upgrade.git
cd kidi-kernel-upgrade

# 2) 환경 설정 (.env)
cp .env.example .env
vi .env                  # ISO 경로, Target OS, k8s 버전 등 환경에 맞게 수정
make help                # 타겟/현재 변수값 확인

# 3) Phase 1 — Kubernetes 설치 (root)
sudo make set-dns DNS_SERVER=8.8.8.8    # 노드 DNS가 없을 때만
sudo make local-repo                    # RPM 디렉토리에 repodata가 없을 때만
sudo make k8s-install                   # prep + pkgs + init + Flannel
sudo make verify-k8s                    # 업그레이드 전 기준선 확인

# 4) Phase 2 — 커널/OS 업그레이드 (root)
sudo make prepare                       # preflight + mount + repo + backup
sudo make upgrade                       # ISO repo만으로 전체 dnf upgrade
sudo reboot

# 5) 재부팅 후 검증 + 확정
sudo make commit                        # verify + verify-k8s 통과 시 최신 커널 확정
```

원격(예: 검증 노드)에서 그대로 쓰려면:

```bash
scp -r kidi-kernel-upgrade root@<node>:/root/
ssh root@<node> 'cd /root/kidi-kernel-upgrade && make help'
```

변수는 `.env` 대신 명령줄로도 덮어쓸 수 있습니다(우선순위가 더 높음):

```bash
sudo make upgrade ISO=/root/rhel-9.6-x86_64-dvd.iso TARGET_VERSION=9.6
sudo make k8s-install K8S_VERSION=1.23.17 LOCAL_RPM_REPO=/root/repo
```

## 구성 (.env)

```bash
cp .env.example .env
vi .env     # ISO 경로, Target OS, k8s 버전 등 수정
```

우선순위: **명령줄 인자 > `.env` > Makefile 기본값**. `.env`는 커밋되지 않습니다.

| 변수 | 용도 | 예시 |
|------|------|------|
| `ISO` | Target 버전 DVD ISO 경로 | `/root/rhel-9.6-x86_64-dvd.iso` |
| `EXPECTED_CURRENT` / `TARGET_VERSION` | 현재 / 목표 OS 마이너 버전 | `9.3` / `9.6` |
| `MOUNT` | ISO 마운트 위치 | `/mnt/rhel-iso` |
| `BACKUP_ROOT` | 업그레이드 전 스냅샷 저장 | `/root/kernel-upgrade-verify/backup` |
| `LOCAL_RPM_REPO` | k8s+docker RPM repo(오프라인) | `/root/repo` |
| `K8S_VERSION` | 설치할 k8s 버전 | `1.23.17` |
| `POD_CIDR` | 파드 네트워크 CIDR (CNI와 일치) | `10.244.0.0/16` |
| `CRI_SOCKET` | CRI 소켓 (dockershim) | `/var/run/dockershim.sock` |
| `FLANNEL_URL` | CNI 매니페스트 | flannel release URL |
| `DNS_SERVER` | 에어갭 DNS 보정용 | `8.8.8.8` |
| `KUBECONFIG` | API 접근용 kubeconfig | `/etc/kubernetes/admin.conf` |
| `SOURCE_ISO` / `UNDO_ID` | 패키지 롤백용 소스 ISO / 업그레이드 트랜잭션 ID | `/root/rhel-9.3-x86_64-dvd.iso` / `4` |
| `EXTRA_REPOS` / `CUSTOM_REPO_*` | 업그레이드 시 추가 repo | (선택) |

## 전체 흐름

```bash
# ── Phase 1: Kubernetes 설치 (kubeadm 단일 컨트롤플레인) ──
sudo make set-dns DNS_SERVER=8.8.8.8   # 노드 DNS가 없을 때만 (이미지 pull용)
sudo make local-repo                   # RPM 디렉토리에 repodata가 없을 때만 (createrepo)
sudo make k8s-install                  # prep + pkgs(docker/kube*) + init + Flannel
sudo make verify-k8s                   # 업그레이드 전 기준선: 클러스터 정상 확인

# ── Phase 2: OS/커널 업그레이드 (9.3 → 9.6) ──
sudo make prepare                      # preflight + mount + repo + backup
sudo make upgrade                      # ISO repo만으로 전체 dnf upgrade (k8s 패키지 미변경)
sudo reboot

# ── 재부팅 후 검증 + 확정 ──
sudo make commit                       # verify + verify-k8s 통과 시에만 최신 커널 기본 부팅 확정
```

## Phase 1 — Kubernetes 설치 상세

| 타겟 | 동작 |
|------|------|
| `set-dns` | `DNS_SERVER`를 `/etc/resolv.conf`에 기록 (원본은 `.kidi.bak`로 백업). 에어갭에서 registry.k8s.io 이미지 pull용 |
| `local-repo` | RPM만 있는 디렉토리(`RPM_SRC`)에 `createrepo_c`로 메타데이터(repodata) 생성. createrepo_c가 없으면 ISO repo에서 자동 설치. **이미 repodata가 있으면 불필요** |
| `k8s-prep` | swap off, SELinux permissive, firewalld 비활성, `overlay`/`br_netfilter` 로드, sysctl 설정 |
| `k8s-pkgs` | `LOCAL_RPM_REPO`를 repo로 등록 → docker-ce + kubelet/kubeadm/kubectl `K8S_VERSION` 설치 → Docker 설정(systemd cgroup) + 기동 |
| `k8s-init` | 컨트롤플레인 이미지 pull → `kubeadm init` → kubeconfig → Flannel 적용 → 단일노드 테인트 제거 → 전 파드 Ready 대기 |
| `k8s-install` | 위 prep+pkgs+init 한 번에 |
| `k8s-reset` | `kubeadm reset` + 관련 디렉토리 정리 (재설치 전) |
| `k8s-status` | `kubectl get nodes/pods` |

> 런타임은 **Docker**입니다. 번들에 cri-dockerd가 없고 k8s 1.23이 **dockershim을 내장**하므로,
> kubelet이 dockershim(`/var/run/dockershim.sock`)으로 Docker에 연결합니다(1.24부터는 dockershim 제거됨).
> 컨트롤플레인 이미지는 `registry.k8s.io`에서 `docker pull`로 받으므로 인터넷(또는 사내 미러)이 필요합니다.
> 완전 폐쇄망이면 이미지 tar를 미리 `docker load`로 적재해야 합니다.

## Phase 2 — OS/커널 업그레이드 상세

| 타겟 | 동작 |
|------|------|
| `preflight` | root/ISO/현재버전(`EXPECTED_CURRENT`)/디스크 점검 |
| `mount` | ISO를 `MOUNT`에 loop,ro 마운트 |
| `repo` | BaseOS+AppStream 로컬 repo 작성 (+ 선택적 custom repo) |
| `backup` | 현재 커널/부트엔트리/패키지/dnf history 스냅샷 |
| `upgrade` | `dnf --disablerepo=* --enablerepo=rhel-iso-* upgrade` (전체). **k8s 패키지는 ISO repo에 없어 미변경** |
| `verify` | 릴리스가 `TARGET_VERSION`이고 새 커널로 부팅됐는지 |
| `verify-k8s` | 모듈/sysctl/swap/런타임/kubelet/crictl/노드 Ready/kube-system 파드 점검 |
| `set-default` | 최신 커널을 기본 부팅 엔트리로 |
| `commit` | `verify` + `verify-k8s` 모두 통과 시에만 `set-default` 실행 |
| `rollback` | 백업 시점(이전) 커널로 기본 부팅 복구 |
| `clean` | ISO 언마운트 + 생성한 repo 파일 제거 |

핵심: `--disablerepo=* --enablerepo=rhel-iso-*` 덕분에 커널/base만 올라가고
**k8s/docker 런타임 패키지는 건드리지 않습니다.**

## 롤백

### 1) 부팅 커널만 롤백

```bash
sudo make rollback     # 이전 커널을 기본 부팅으로
sudo reboot
```

`rollback`은 **부팅 커널만** 되돌립니다(빠르고 안전).

### 2) 패키지까지 롤백 (`make rollback-pkgs`)

업그레이드로 바뀐 패키지 전체를 소스 버전(`EXPECTED_CURRENT`)으로 **다운그레이드**합니다.
`dnf history undo`를 사용하며, 소스 버전 DVD ISO(`SOURCE_ISO`)에서 패키지를 가져옵니다.

```bash
# 먼저 부팅 커널을 이전 것으로 돌리고 재부팅 (새 커널 제거가 깔끔하도록)
sudo make rollback && sudo reboot

# 재부팅 후: 소스 ISO + 업그레이드 트랜잭션 ID로 패키지 다운그레이드
sudo make rollback-pkgs SOURCE_ISO=/root/rhel-9.3-x86_64-dvd.iso UNDO_ID=4
#   UNDO_ID를 모르면 'dnf history list'에서 업그레이드(I, U) 트랜잭션 ID 확인

sudo make verify-k8s   # k8s 정상 확인
sudo make clean        # 소스 ISO repo/마운트 정리
```

가드: **최신 커널로 부팅 중이면** 거부합니다(먼저 `make rollback` + reboot 필요).
`rollback-pkgs`는 **부팅 커널 롤백을 포함하지 않으므로** 위 순서대로 실행하세요.

> 패키지 다운그레이드는 대규모 트랜잭션이라 위험합니다. 반드시 `make backup` 스냅샷과
> 소스/타깃 ISO를 준비해 두고, 문제 시 타깃 ISO로 재업그레이드할 수 있게 하세요.

### 백업/롤백 검증 결과 (실제 노드, RHEL 9.3 → 9.6)

`make backup` 산출물과 `make rollback` 경로를 실제 노드에서 검증했습니다.

**1) 백업 산출물 무결성** — `$BACKUP_ROOT/<timestamp>/`에 6개 파일 모두 생성·정상:

| 파일 | 내용 | 결과 |
|------|------|------|
| `running-kernel.txt` | `5.14.0-362.8.1.el9_3.x86_64` | ✅ 업그레이드 전 커널 |
| `release.txt` | `Red Hat Enterprise Linux release 9.3` | ✅ |
| `default-kernel.txt` | `/boot/vmlinuz-...el9_3.x86_64` | ✅ |
| `packages.txt` | 629개 (k8s/런타임 포함 전체 패키지) | ✅ |
| `dnf-history.txt` / `grub-entries.txt` | 기록됨 | ✅ |
| `latest` → `<timestamp>` 심볼릭 링크 | 정상 | ✅ |

**2) 롤백 전제조건** — 백업에 기록된 el9_3 커널이 디스크에 그대로 있고 grubby도 인식(index=1) ✅

**3) 롤백 경로 실제 테스트** (재부팅 없이 grubby 기본값만 전환 후 복구):

```text
before:           default = el9_6
make rollback   → default = el9_3   # 백업값으로 정확히 전환 ✅
make set-default → default = el9_6  # 복구 ✅
final:            default = el9_6
```

**4) 패키지 레벨 롤백 실제 수행** (`make rollback-pkgs`):

`make rollback` + 재부팅(el9_3 부팅) 후, 9.3 ISO repo로 `dnf history undo 4` 실행 →

| 항목 | 결과 |
|------|------|
| 트랜잭션 | 삭제 73 + 하향설치 410 = **483개** (업그레이드와 동일 규모) |
| 릴리스 | 9.6 → **9.3 복귀** ✅ |
| 커널 | el9_6 제거, **el9_3 단독** ✅ |
| 잔존 el9_6 패키지 | **0개** ✅ |
| 의존성 무결성 | `dnf check` 정상 ✅ |
| k8s | 다운그레이드 후에도 노드 Ready, 전 파드 Running ✅ |

→ **부팅 커널 롤백 + 패키지 레벨 롤백 모두 실제 검증 완료.** k8s는 9.6 업그레이드와
9.3 다운그레이드 양방향에서 정상 동작했습니다.

## 검증 기준 (commit 게이트)

`make commit`은 다음을 **모두** 통과해야 최신 커널을 기본 부팅으로 확정합니다.

- `verify`     : `/etc/redhat-release`가 `TARGET_VERSION`, 실행 커널 = 최신 설치 커널
- `verify-k8s` : `overlay`/`br_netfilter`, sysctl 2종, swap off, 런타임 active,
  kubelet active, crictl 동작, 노드 `Ready`, kube-system 파드 전부 Running/Completed

하나라도 실패하면 기본 부팅 커널을 바꾸지 않고 종료(exit 1)합니다.

## 참고 — 폐쇄망/서브스크립션

- 노드가 RHSM 미등록이면 **ISO에 담긴 패키지(=Target GA 스냅샷)까지만** 적용됩니다.
  Target GA 이후의 보안 errata(z-stream)는 ISO에 없어 적용되지 않으므로,
  운영 환경은 RHSM/Satellite/사내 미러 등록을 권장합니다.
- 커널 업그레이드 자체는 ISO repo만 사용하므로 인터넷이 없어도 됩니다.
  (k8s 이미지 pull 단계에서만 인터넷/미러가 필요)
