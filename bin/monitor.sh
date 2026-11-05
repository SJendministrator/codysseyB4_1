#!/usr/bin/env bash
# =============================================================
# monitor.sh — agent-app 시스템 상태 수집 및 로깅
#
# 위치/권한 : $AGENT_HOME/bin/monitor.sh  (agent-dev:agent-core, 750)
# 실행 주기 : agent-admin crontab, 매분
#
# 순서
#   1) Health Check  : 앱 프로세스, 15034 LISTEN   → 실패 시 에러 기록 후 exit 1
#   2) 상태 점검     : 방화벽 활성 여부            → 비활성이면 [WARNING]만
#   3) 자원 수집     : CPU / MEM / DISK(/) 사용률   → 임계 초과 시 [WARNING]만
#   4) 로그 기록     : /var/log/agent-app/monitor.log (10MB 넘으면 회전, 최대 10개 유지)
#   5) 통계          : 같은 폴더의 report.sh 가 있으면 최근 10개 샘플 요약 출력
#
# 종료 코드: 0 정상(경고 포함), 1 Health Check 실패, 2 환경 문제(로그 쓰기 불가 등)
# =============================================================
set -u

# ---------- 설정 ----------
# cron 은 로그인 셸 설정(/etc/profile.d)을 읽지 않으므로 직접 불러온다.
if [ -z "${AGENT_HOME:-}" ] && [ -r /etc/profile.d/agent-app.sh ]; then
    # shellcheck disable=SC1091
    . /etc/profile.d/agent-app.sh
fi
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

APP_PORT="${AGENT_PORT:-15034}"
LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$LOG_DIR/monitor.log"
# 제공 앱 실행 파일명 (PyInstaller 바이너리 또는 python3 agent_app.py)
# 명령줄의 "맨 앞"이 앱일 때만 매칭한다. 그냥 -f 로 이름만 찾으면
# `vim .../agent-app-linux-arm64` 처럼 파일명이 인자로 들어간 다른 프로세스까지 잡힌다.
APP_PATTERN="${APP_PATTERN:-^([^ ]*/)?(agent-app-linux-[a-z0-9_]+|python3?(\.[0-9]+)? ([^ ]*/)?agent_app\.py)( |$)}"

# 임계값 (%). 환경 변수로 덮어쓸 수 있다 — 경고 동작 시연·테스트용
CPU_WARN="${CPU_WARN:-20}"
MEM_WARN="${MEM_WARN:-10}"
DISK_WARN="${DISK_WARN:-80}"
MAX_LOG_BYTES=$((10 * 1024 * 1024))   # 10MB
MAX_LOG_FILES=10                      # monitor.log 포함 총 개수

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"
WARN_COUNT=0

say()  { echo "$*"; }
warn() { echo "[WARNING] $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
gt()   { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }   # 실수 비교 a > b

log_error() {   # Health Check 실패도 운영 추적을 위해 로그에 남긴다
    [ -w "$LOG_DIR" ] && echo "[$NOW] [ERROR] $*" >> "$LOG_FILE"
}

# ---------- 동시 실행 방지 ----------
# 이전 회차와 겹쳐 실행되면 로그 회전이 꼬일 수 있다.
# 한 회차는 2초 남짓이므로 최대 10초 기다려 보고, 그래도 잠겨 있으면 이번 회차를 건너뛴다.
if [ ! -d "$LOG_DIR" ] || [ ! -w "$LOG_DIR" ]; then
    echo "[ERROR] 로그 디렉터리에 쓸 수 없습니다: $LOG_DIR (user=$(id -un))" >&2
    exit 2
fi
exec 9>"$LOG_DIR/.monitor.lock"
if ! flock -w 10 9; then
    echo "[INFO] 다른 monitor.sh 가 10초 넘게 실행 중이라 이번 회차는 건너뜁니다."
    exit 0
fi

say "====== SYSTEM MONITOR RESULT ======"
say ""

# =============================================================
# 1) Health Check
# =============================================================
say "[HEALTH CHECK]"

PIDS="$(pgrep -f -- "$APP_PATTERN" | tr '\n' ' ')"
PIDS="${PIDS% }"
if [ -z "$PIDS" ]; then
    say "Checking process 'agent-app'... [FAIL] not running"
    log_error "Health check failed: process not running"
    exit 1
fi

# PyInstaller 바이너리는 부모(압축 해제)·자식(실제 앱) 2개로 뜬다.
# 포트를 실제로 잡고 있는 프로세스를 대표 PID 로 쓴다.
LISTEN_LINE="$(ss -Hltnp "sport = :$APP_PORT" 2>/dev/null)"
MAIN_PID="$(grep -o 'pid=[0-9]*' <<< "$LISTEN_LINE" | head -1 | cut -d= -f2)"
# 포트를 잡은 프로세스가 앱이 아니면(다른 프로그램이 포트 점유) 무시하고 가장 최근 앱 PID 사용
case " $PIDS " in *" $MAIN_PID "*) ;; *) MAIN_PID="$(pgrep -n -f -- "$APP_PATTERN")" ;; esac
APP_NAME="$(ps -o comm= -p "$MAIN_PID" 2>/dev/null)"
say "Checking process '${APP_NAME:-agent-app}'... [OK] (PID: $MAIN_PID${PIDS:+, all: $PIDS})"

if [ -z "$(ss -Hltn "sport = :$APP_PORT" 2>/dev/null)" ]; then
    say "Checking port $APP_PORT... [FAIL] not listening"
    log_error "Health check failed: port $APP_PORT not listening (PID:$MAIN_PID)"
    exit 1
fi
BIND="$(ss -Hltn "sport = :$APP_PORT" | awk '{print $4}' | head -1)"
say "Checking port $APP_PORT... [OK] (LISTEN $BIND)"
say ""

# =============================================================
# 2) 방화벽 상태 점검 (경고만)
# =============================================================
say "[FIREWALL]"
fw_state="unknown"; fw_name="none"
if command -v ufw >/dev/null 2>&1; then
    fw_name="ufw"
    if [ "$(id -u)" -eq 0 ]; then
        ufw status 2>/dev/null | grep -q '^Status: active' && fw_state=active || fw_state=inactive
    else
        # 일반 계정(cron)은 'ufw status'를 못 쓴다(root 필요).
        # sudo 를 시도하면 권한 없는 계정은 매분 auth.log 에 경고가 쌓이므로 쓰지 않고,
        # 누구나 읽을 수 있는 설정 파일(ENABLED=yes) + 서비스 상태로 판단한다.
        if grep -qiE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null \
           && systemctl is-active --quiet ufw 2>/dev/null; then
            fw_state=active
        else
            fw_state=inactive
        fi
    fi
elif command -v firewall-cmd >/dev/null 2>&1; then
    fw_name="firewalld"
    systemctl is-active --quiet firewalld 2>/dev/null && fw_state=active || fw_state=inactive
fi

if [ "$fw_state" = active ]; then
    say "Firewall ($fw_name)... [OK] active"
else
    [ "$fw_name" = none ] && fw_state="not installed"
    say "Firewall ($fw_name)... $fw_state"
    warn "Firewall is not active ($fw_name: $fw_state)"
fi
say ""

# =============================================================
# 3) 자원 수집
# =============================================================
say "[RESOURCE MONITORING]"

# CPU: /proc/stat 을 1초 간격으로 두 번 읽어 그 사이 사용률 계산
#   사용률 = 1 - (idle 증가량 / 전체 증가량)
read_cpu() { awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print total, idle }' /proc/stat; }
read -r t1 i1 < <(read_cpu); sleep 1; read -r t2 i2 < <(read_cpu)
CPU="$(awk -v dt=$((t2 - t1)) -v di=$((i2 - i1)) 'BEGIN { printf "%.1f", (dt > 0) ? (1 - di / dt) * 100 : 0 }')"

# MEM: 실제로 쓸 수 있는 여유분(MemAvailable)을 뺀 비율. 캐시는 사용 중으로 치지 않는다.
MEM="$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END { printf "%.1f", (t - a) / t * 100 }' /proc/meminfo)"

# DISK: 루트(/) 파티션 사용률
DISK="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"

say "CPU Usage  : ${CPU}%"
say "MEM Usage  : ${MEM}%"
say "DISK Used  : ${DISK}%"
say ""

before=$WARN_COUNT
gt "$CPU"  "$CPU_WARN"  && warn "CPU threshold exceeded (${CPU}% > ${CPU_WARN}%)"
gt "$MEM"  "$MEM_WARN"  && warn "MEM threshold exceeded (${MEM}% > ${MEM_WARN}%)"
gt "$DISK" "$DISK_WARN" && warn "DISK threshold exceeded (${DISK}% > ${DISK_WARN}%)"
[ "$WARN_COUNT" -gt "$before" ] && say ""

# =============================================================
# 4) 로그 기록 (+ 용량 관리)
# =============================================================
# 10MB 이상이면 monitor.log → monitor.YYYYmmdd-HHMMSS.log 로 이름을 바꾸고 새로 시작.
# 회전된 파일이 9개를 넘으면 오래된 것부터 삭제 → monitor.log 포함 최대 10개.
if [ -f "$LOG_FILE" ] && [ "$(stat -c %s "$LOG_FILE")" -ge "$MAX_LOG_BYTES" ]; then
    rotated="$LOG_DIR/monitor.$(date '+%Y%m%d-%H%M%S').log"
    mv "$LOG_FILE" "$rotated"
    say "[INFO] Log rotated: $rotated"
    ls -1t "$LOG_DIR"/monitor.*.log 2>/dev/null | tail -n +"$MAX_LOG_FILES" | while read -r old; do
        rm -f -- "$old" && say "[INFO] Old log removed: $old"
    done
fi

echo "[$NOW] PID:$MAIN_PID CPU:${CPU}% MEM:${MEM}% DISK_USED:${DISK}%" >> "$LOG_FILE"

# =============================================================
# 5) 통계 (report.sh 가 있으면 최근 10개 샘플)
# =============================================================
if [ -x "$SCRIPT_DIR/report.sh" ]; then
    "$SCRIPT_DIR/report.sh" --last 10 --file "$LOG_FILE" || true
fi

say ""
say "[INFO] Log appended: $LOG_FILE"
exit 0
