# codysseyB4_1 — agent-app 운영 환경 구축 · 관제 자동화

서버를 운영하는 엔지니어처럼 **보안 기본 설정 → 역할 기반 권한 → 앱 실행 환경 → 관제 스크립트 → 자동 실행**까지 직접 구성하는 미션입니다.

- 수행 내역서: [docs/수행내역서.md](docs/수행내역서.md)
- 관제 스크립트: [bin/monitor.sh](bin/monitor.sh) · 보너스 [bin/report.sh](bin/report.sh) · [bin/log_retention.sh](bin/log_retention.sh)
- 증거 원본: [evidence/](evidence/)

## 구성 요약

| 영역 | 설정 |
|---|---|
| SSH | 포트 **20022**, `PermitRootLogin no` |
| 방화벽 | UFW, 인바운드 기본 차단, **20022/tcp · 15034/tcp만 허용** |
| 계정 | `agent-admin`(운영·cron) · `agent-dev`(개발·monitor.sh 작성) · `agent-test`(QA) |
| 그룹 | `agent-common` = admin, dev, test / `agent-core` = admin, dev |
| 공유 디렉터리 | `$AGENT_HOME/upload_files` → agent-common 읽기·쓰기 |
| 보안 디렉터리 | `$AGENT_HOME/api_keys`, `/var/log/agent-app` → **agent-core만** 읽기·쓰기 |
| 관제 | `$AGENT_HOME/bin/monitor.sh` (agent-dev:agent-core, 750), agent-admin crontab **매분** |
| 로그 | `/var/log/agent-app/monitor.log`, 10MB 넘으면 회전, **최대 10개** 유지 |
| 보너스 | `report.sh` 통계 / `log_retention.sh` 7일 압축·아카이브, 30일 삭제 |

## 결과 한눈에

실제 서버(OrbStack 리눅스 머신, Ubuntu 22.04.5, x86_64)에서 수집한 결과입니다. 자세한 출력은 [수행 내역서](docs/수행내역서.md) §2, 원본은 [evidence/](evidence/).

| # | 필수 증거 | 핵심 결과 | 원본 |
|---|---|---|---|
| 1 | SSH 20022 + root 원격 차단 | `sshd -T` → `port 20022`, `permitrootlogin no` / `0.0.0.0:20022 LISTEN` | [01](evidence/01-ssh.txt) |
| 2 | 방화벽 2포트만 허용 | `Status: active`, `Default: deny (incoming)`, ALLOW 는 `20022/tcp`·`15034/tcp` 뿐 | [02](evidence/02-firewall.txt) |
| 3 | 계정 3 · 그룹 2 | `agent-core:x:1001:agent-admin,agent-dev` — agent-test 는 core 에 없음 | [03](evidence/03-accounts.txt) |
| 4 | 디렉터리 · 권한 · ACL | 계정별 직접 시도 12건 기대대로 (예: `agent-test DENY api_keys 읽기`) | [04](evidence/04-permissions.txt) |
| 5 | Boot 5단계 + Agent READY | `[1/5]`~`[5/5]` 모두 `[OK]`, `All Boot Checks Passed!`, `Agent READY`, `0.0.0.0:15034` LISTEN | [05](evidence/05-app-boot.txt) |
| 6 | monitor.sh 실행 결과 | 프로세스·포트·방화벽 `[OK]`, CPU 2.6% / MEM 5.4% / DISK 1%, 임계값 낮춘 시연에서 `[WARNING]` 3종 | [06](evidence/06-monitor-run.txt) |
| 7 | monitor.log 누적 | `[2026-11-05 21:57:01] PID:5232 CPU:3.4% MEM:5.8% DISK_USED:1%` | [07](evidence/07-cron.txt) |
| 8 | cron 매분 + 1분 후 증가 | 70초 대기 동안 줄 수 20 → 21, `journalctl` 에 `(agent-admin) CMD (.../monitor.sh ...)` 매분 기록 | [07](evidence/07-cron.txt) |
| + | 보너스 | `report.sh` 21샘플 평균·최대·최소 / 보존 정책: 8일 전 파일만 압축·이동, 31일 전 아카이브만 삭제 | [08](evidence/08-report.txt) · [09](evidence/09-retention.txt) |

## 미션 문서와 실제 앱이 다른 점

| 항목 | 미션 문서 | 실제 앱이 요구한 것 (부팅 오류 메시지 기준) |
|---|---|---|
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys/t_secret.key` (파일) | `$AGENT_HOME/api_keys` (**디렉터리**) — `Key Path Mismatch. Expected: .../api_keys` |
| 키 파일 이름 | `t_secret.key` | **`secret.key`** — `Missing File: secret.key` |

실제 파일은 `secret.key` 로 만들고, 문서 이름 `t_secret.key` 는 같은 파일을 가리키는 심볼릭 링크로 남겨 두 기준을 모두 만족시켰습니다 ([config/agent-app.env](config/agent-app.env)).

## 과제 목표 — 한 줄 요약

자세한 설명은 [수행 내역서 §3](docs/수행내역서.md#3-과제-목표--설명).

| 질문 | 요약 |
|---|---|
| SSH 포트 변경 · root 차단은 왜 기본 보안인가 | 22번 대상 자동 스캔을 피하고, 누구나 아는 계정명 `root` 로 바로 최고 권한을 노리는 길을 막는다 |
| "필요 포트만 허용"을 어떻게 구성·검증했나 | 기본 차단 + 20022·15034 예외. 20022 를 먼저 허용한 뒤 활성화하고, 허용 목록이 정확히 2개인지 스크립트가 검사 |
| 계정·그룹·ACL 로 공유/보안 디렉터리를 나누는 이유 | 최소 권한. 권한은 사람이 아니라 그룹에 주고, default ACL 로 앞으로 생길 파일까지 같은 규칙 적용 |
| 환경 변수로 실행 환경을 고정하는 이유와 검증 | 같은 프로그램을 설정만 바꿔 어디서든 동일하게 실행. 실행 계정 로그인 셸의 `env` + 앱의 `[2/5] [OK]` 로 이중 확인 |
| 스크립트로 수집 → 로그로 추적하는 흐름 | 살아있나 → 방어선 켜졌나 → 자원 여유 있나 순서로 확인하고 시각이 찍힌 고정 형식 한 줄로 남겨, 언제부터 이상했는지 거슬러 올라갈 수 있다 |
| cron 주기 실행과 로그 보존 정책이 필요한 이유 | 아무도 안 볼 때의 상태까지 기록. 로그가 디스크를 채워 서비스를 멈추지 않도록 크기(10MB×10)·시간(7일 압축, 30일 삭제) 상한 |

## 폴더 구조

```
config/
  agent-app.env           환경 변수 단일 원본 (/etc/profile.d 로 설치, monitor.sh 도 이 값 사용)
  crontab.agent-admin     agent-admin crontab
setup/                    sudo 로 한 번씩 실행하는 설정 스크립트 (순서대로)
  01_ssh.sh               SSH 포트·root 차단 + 검증
  02_firewall.sh          UFW 규칙 + 검증
  03_accounts.sh          계정·그룹·디렉터리·ACL + 계정별 접근 테스트
  04_app_env.sh           환경 변수·키 파일·앱 배치 + 검증
  05_deploy_cron.sh       bin/*.sh 배치(750) + cron 등록
  06_collect_evidence.sh  수행 내역서 체크리스트 8개 증거를 evidence/ 에 저장
bin/                      서버의 $AGENT_HOME/bin 에 배치되는 스크립트
evidence/                 06 이 수집한 실제 출력
docs/                     수행 내역서
```

모든 설정 스크립트는 **실행한 명령을 화면에 그대로 출력**하고, 끝에 **스스로 검증**합니다. 여러 번 실행해도 같은 결과가 되도록(멱등) 작성했습니다.

## 실행 순서

### 0. 리눅스 머신 (OrbStack)

Docker 컨테이너에는 systemd 가 없어 sshd · cron · ufw 가 서비스로 동작하지 않으므로, 실제 서버처럼 systemd 가 도는 OrbStack 리눅스 머신을 사용합니다. 맥의 `/Users` 가 머신 안에 같은 경로로 연결돼 있어 레포를 그대로 쓸 수 있습니다.

```bash
# macOS
orb create ubuntu:jammy agent-server
orb -m agent-server

# macOS 에서 레포 받기 (맥에는 git 이 이미 있음)
cd ~ && git clone https://github.com/SJendministrator/codysseyB4_1.git

# 머신 안 (프롬프트가 user@agent-server 인지 확인)
cd /Users/<맥 사용자>/codysseyB4_1              # 맥 폴더가 같은 경로로 보인다
sudo apt-get install -y -qq git                 # 머신 안에서 git pull 하려면 (맥과 별개)
sudo timedatectl set-timezone Asia/Seoul        # 로그 시각을 한국 시간으로
```

### 1~3. 보안 · 계정 · 권한

```bash
sudo ./setup/01_ssh.sh
sudo ./setup/02_firewall.sh
sudo ./setup/03_accounts.sh
```

### 4. 앱 실행 환경 → 앱 실행

```bash
sudo ./setup/04_app_env.sh /Users/<맥 사용자>/<압축 푼 위치>/agent-app-linux-x86   # uname -m 결과에 맞는 파일 (aarch64 면 arm64)
```

**새 터미널**을 열어 앱을 일반 계정으로 실행합니다 (root 금지, 종료는 Ctrl+C). 부팅 출력은 증거용으로 파일에도 남깁니다.

```bash
orb -m agent-server
sudo -iu agent-admin
PYTHONUNBUFFERED=1 $AGENT_HOME/agent-app-linux-* 2>&1 | tee /tmp/agent-boot.log
```

> `PYTHONUNBUFFERED=1`: 출력을 파이프(`| tee`)로 보내면 파이썬이 출력을 모아뒀다가 늦게 내보내서 화면에 아무것도 안 보일 수 있습니다. 즉시 출력하게 합니다.

### 5. 관제 스크립트 배치 + cron

원래 터미널로 돌아와서:

```bash
sudo ./setup/05_deploy_cron.sh
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh     # 수동 실행 확인
```

### 6. 증거 수집 (약 70초)

```bash
sudo ./setup/06_collect_evidence.sh
```

`evidence/` 에 8개 항목별 출력이 저장됩니다. 맥에서 커밋·푸시하면 수행 내역서에 반영합니다.

## monitor.sh 동작

```
[1] Health Check   앱 프로세스 실행 중?  15034 LISTEN?     → 아니면 monitor.log 에 [ERROR] 남기고 exit 1
[2] 방화벽 점검    UFW 활성?                              → 아니면 [WARNING] (계속 진행)
[3] 자원 수집      CPU / MEM / DISK(/) 사용률              → 20% / 10% / 80% 초과 시 [WARNING]
[4] 로그 기록      [YYYY-MM-DD HH:MM:SS] PID:.. CPU:..% MEM:..% DISK_USED:..%
                   10MB 넘으면 monitor.YYYYmmdd-HHMMSS.log 로 회전, 총 10개 초과분 삭제
[5] 통계           report.sh 로 최근 10개 샘플 요약 출력
```

| 설계 포인트 | 이유 |
|---|---|
| `/etc/profile.d/agent-app.sh` 를 스크립트가 직접 읽음 | cron 은 로그인 셸이 아니라 환경 변수가 비어 있다 |
| 방화벽은 일반 계정일 때 `/etc/ufw/ufw.conf` 의 `ENABLED=yes` + `ufw.service` 활성/부팅 시 자동 시작으로 판단 | `ufw status` 는 root 전용. sudo 를 시도하면 매분 보안 로그에 경고가 쌓인다. `ufw.service` 는 부팅 때 한 번 실행되고 끝나는 서비스라 `ufw enable` 직후엔 `is-active` 가 inactive 로 나온다 (실제로 이것 때문에 오탐이 났다) |
| 프로세스는 명령줄 **맨 앞**이 앱일 때만 인정 | 그냥 이름으로 찾으면 `vim agent-app-...` 같은 프로세스도 잡힌다 |
| 대표 PID = 15034 를 실제로 LISTEN 하는 프로세스 | PyInstaller 앱은 부모·자식 2개로 뜬다 |
| CPU 는 `/proc/stat` 을 1초 간격으로 두 번 읽어 계산 | 한 번만 읽으면 부팅 이후 평균이 나온다 |
| MEM 은 `MemAvailable` 기준 | 캐시는 필요하면 바로 비울 수 있어 사용 중으로 보지 않는다 |
| `flock -w 10` 으로 동시 실행 방지 | 겹쳐 실행되면 로그 회전이 꼬일 수 있다. 바로 포기하지 않고 최대 10초 기다려 회차를 빠뜨리지 않는다 |
| 회전 파일명을 `monitor.<시각>.log` 로 | 보존 정책(`*.log` 7일 경과 압축)과 자연스럽게 이어진다 |

## 테스트 (가짜 앱으로 사전 검증)

| 경우 | 결과 |
|---|---|
| 앱 미실행 | `[FAIL] not running`, monitor.log 에 `[ERROR]`, exit 1 |
| 프로세스는 있는데 포트 미LISTEN | `[FAIL] not listening`, exit 1 |
| 정상 | 로그 1줄 추가, exit 0 |
| cron 과 같은 빈 환경(`env -i`) | 정상 동작 (환경 변수 자체 로드) |
| 동시 실행 | 두 번째 실행은 앞 회차가 끝날 때까지 기다렸다가 정상 실행 |
| monitor.log 10MB + 회전 파일 12개 | 회전 후 총 10개만 유지 (오래된 것부터 삭제) |
| agent-test 로 실행 | Permission denied (750) |
| 보존 정책: 7일 지난 로그 / 30일 지난 아카이브 / 권한 없음 / 대상 0개 | 압축·이동 / 삭제 / 원본 유지하고 오류 / 안내 후 정상 종료 |
| report.sh 기간 필터·최근 N개·ERROR 줄 섞임·빈 결과·잘못된 시각 | 모두 기대대로 |
