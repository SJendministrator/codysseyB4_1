# agent-app 운영 환경 구축 · 관제 자동화

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

# 머신 안
sudo timedatectl set-timezone Asia/Seoul        # 로그 시각을 한국 시간으로
cd /Users/<맥 사용자>/Desktop/<이 레포>
```

### 1~3. 보안 · 계정 · 권한

```bash
sudo ./setup/01_ssh.sh
sudo ./setup/02_firewall.sh
sudo ./setup/03_accounts.sh
```

### 4. 앱 실행 환경 → 앱 실행

```bash
sudo ./setup/04_app_env.sh /Users/<맥 사용자>/<압축 푼 위치>/agent-app-linux-arm64   # uname -m 이 x86_64 면 x86 파일
```

**새 터미널**을 열어 앱을 일반 계정으로 실행합니다 (root 금지, 종료는 Ctrl+C). 부팅 출력은 증거용으로 파일에도 남깁니다.

```bash
orb -m agent-server
sudo -iu agent-admin
PYTHONUNBUFFERED=1 $AGENT_HOME/agent-app-linux-arm64 2>&1 | tee /tmp/agent-boot.log
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
| 방화벽은 일반 계정일 때 `/etc/ufw/ufw.conf` + `systemctl is-active ufw` 로 판단 | `ufw status` 는 root 전용. sudo 를 시도하면 매분 보안 로그에 경고가 쌓인다 |
| 프로세스는 명령줄 **맨 앞**이 앱일 때만 인정 | 그냥 이름으로 찾으면 `vim agent-app-...` 같은 프로세스도 잡힌다 |
| 대표 PID = 15034 를 실제로 LISTEN 하는 프로세스 | PyInstaller 앱은 부모·자식 2개로 뜬다 |
| CPU 는 `/proc/stat` 을 1초 간격으로 두 번 읽어 계산 | 한 번만 읽으면 부팅 이후 평균이 나온다 |
| MEM 은 `MemAvailable` 기준 | 캐시는 필요하면 바로 비울 수 있어 사용 중으로 보지 않는다 |
| `flock` 으로 동시 실행 방지 | 이전 회차가 늦게 끝나 겹치면 로그 회전이 꼬일 수 있다 |
| 회전 파일명을 `monitor.<시각>.log` 로 | 보존 정책(`*.log` 7일 경과 압축)과 자연스럽게 이어진다 |

## 테스트 (가짜 앱으로 사전 검증)

| 경우 | 결과 |
|---|---|
| 앱 미실행 | `[FAIL] not running`, monitor.log 에 `[ERROR]`, exit 1 |
| 프로세스는 있는데 포트 미LISTEN | `[FAIL] not listening`, exit 1 |
| 정상 | 로그 1줄 추가, exit 0 |
| cron 과 같은 빈 환경(`env -i`) | 정상 동작 (환경 변수 자체 로드) |
| 동시 실행 | 두 번째 실행은 건너뜀 |
| monitor.log 10MB + 회전 파일 12개 | 회전 후 총 10개만 유지 (오래된 것부터 삭제) |
| agent-test 로 실행 | Permission denied (750) |
| 보존 정책: 7일 지난 로그 / 30일 지난 아카이브 / 권한 없음 / 대상 0개 | 압축·이동 / 삭제 / 원본 유지하고 오류 / 안내 후 정상 종료 |
| report.sh 기간 필터·최근 N개·ERROR 줄 섞임·빈 결과·잘못된 시각 | 모두 기대대로 |
