#!/usr/bin/env bash
# =============================================================
# 06. 증거 수집 — 수행 내역서 체크리스트 8개 항목을 evidence/*.txt 로 저장
#
# 전제: 앱이 다른 터미널에서 agent-admin 으로 실행 중이고,
#       부팅 출력이 /tmp/agent-boot.log 에 저장돼 있다 (README 4단계 참고).
# 사용법: sudo ./setup/06_collect_evidence.sh
#   cron 자동 실행 확인을 위해 약 70초 동안 기다린다.
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

OUT="$REPO_ROOT/evidence"
mkdir -p "$OUT"
BOOT_LOG="${BOOT_LOG:-/tmp/agent-boot.log}"

# cap <파일> <명령...> : 명령과 결과를 같이 저장
cap() {
    local f="$OUT/$1"; shift
    # 증거 수집은 명령이 실패해도 멈추지 않고 종료 코드까지 기록한다 (set -e 무력화)
    # 기록용 명령 문자열: `bash -c "..."` 는 안쪽 명령만, 공백 있는 인자는 따옴표로 감싼다
    local shown="" a
    if [ "$1" = bash ] && [ "${2:-}" = -c ]; then shown="$3"
    else for a in "$@"; do [[ "$a" == *" "* ]] && shown+=" '$a'" || shown+=" $a"; done; shown="${shown# }"; fi
    { echo "\$ $shown"; local rc=0; "$@" 2>&1 || rc=$?; [ "$rc" -eq 0 ] || echo "(exit code: $rc)"; echo; } >> "$f"
}
new() { local f="$OUT/$1"; : > "$f"; echo "# $2" >> "$f"; echo "# 수집: $(date '+%Y-%m-%d %H:%M:%S %Z')  host: $(hostname)" >> "$f"; echo >> "$f"; echo "  -> evidence/$1"; }

step "0. 서버 정보"
new 00-system.txt "서버 환경"
cap 00-system.txt uname -a
cap 00-system.txt bash -c "grep PRETTY_NAME /etc/os-release; echo cores: \$(nproc); timedatectl | grep 'Time zone'"
cap 00-system.txt free -h
cap 00-system.txt df -h /

step "1. SSH 포트 20022 + root 원격 로그인 차단"
new 01-ssh.txt "SSH 설정"
cap 01-ssh.txt grep -nE '^(Port|PermitRootLogin)[[:space:]]' /etc/ssh/sshd_config
cap 01-ssh.txt bash -c "sshd -T | grep -E '^(port|permitrootlogin) '"
cap 01-ssh.txt bash -c "ss -tulnp | grep -E 'sshd|:20022'"

step "2. 방화벽"
new 02-firewall.txt "UFW 방화벽"
cap 02-firewall.txt ufw status verbose

step "3. 계정/그룹"
new 03-accounts.txt "계정 및 그룹"
for u in agent-admin agent-dev agent-test; do cap 03-accounts.txt id "$u"; done
cap 03-accounts.txt getent group agent-common agent-core

step "4. 디렉터리/권한/ACL"
new 04-permissions.txt "디렉터리 구조와 권한"
cap 04-permissions.txt ls -ld /home/agent-admin "$AGENT_HOME" "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_HOME/bin" "$AGENT_LOG_DIR"
cap 04-permissions.txt ls -l "$AGENT_HOME/api_keys" "$AGENT_HOME/bin"
cap 04-permissions.txt getfacl -p /home/agent-admin "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR"
{
    echo "# 실제 접근 테스트 (각 계정으로 시도)"
    t() { if runuser -u "$1" -- "${@:3}" >/dev/null 2>&1; then r=ALLOW; else r=DENY; fi; printf '%-12s %-6s %s\n' "$1" "$r" "$2"; }
    for u in agent-admin agent-dev agent-test; do t "$u" "upload_files 쓰기" touch "$AGENT_UPLOAD_DIR/.probe.$u"; done
    for u in agent-admin agent-dev agent-test; do t "$u" "api_keys 읽기" ls "$AGENT_HOME/api_keys"; done
    for u in agent-admin agent-dev agent-test; do t "$u" "로그 디렉터리 쓰기" touch "$AGENT_LOG_DIR/.probe.$u"; done
    for u in agent-admin agent-dev agent-test; do t "$u" "monitor.sh 실행 권한" test -x "$AGENT_HOME/bin/monitor.sh"; done
    rm -f "$AGENT_UPLOAD_DIR"/.probe.* "$AGENT_LOG_DIR"/.probe.*
} >> "$OUT/04-permissions.txt" 2>&1

step "5. 환경 변수 + 앱 Boot Sequence"
new 05-app-boot.txt "환경 변수, 키 파일, 앱 부팅, 포트 LISTEN"
cap 05-app-boot.txt runuser -l agent-admin -c 'env | grep ^AGENT_ | sort'
cap 05-app-boot.txt bash -c "ls -l '$AGENT_KEY_PATH'; cat '$KEY_FILE'"
if [ -s "$BOOT_LOG" ]; then
    cap 05-app-boot.txt head -n 22 "$BOOT_LOG"
    echo "(이후 $(($(wc -l < "$BOOT_LOG") - 22))줄은 앱 동작 로그 — 전체: $BOOT_LOG)" >> "$OUT/05-app-boot.txt"
else
    warn "부팅 로그가 없습니다: $BOOT_LOG  (README 4단계처럼 tee 로 저장해 주세요)"
    echo "(부팅 로그 없음: $BOOT_LOG)" >> "$OUT/05-app-boot.txt"
fi
cap 05-app-boot.txt bash -c "ps -o user,pid,ppid,cmd -e | grep -E '[a]gent-app-linux|[a]gent_app\\.py'"
cap 05-app-boot.txt bash -c "ss -tlnp | grep ':${AGENT_PORT}'"

step "6. monitor.sh 실행 결과 (agent-admin)"
new 06-monitor-run.txt "monitor.sh 수동 실행"
{
    echo "\$ sudo -u agent-admin $AGENT_HOME/bin/monitor.sh"
    rc=0; runuser -u agent-admin -- "$AGENT_HOME/bin/monitor.sh" 2>&1 || rc=$?; echo "(exit code: $rc)"; echo
    echo "# ---------------------------------------------------------------"
    echo "# 경고 동작 시연: 앱 부하는 주기적으로 오르내리고(코어 $(nproc)개 중 1개 점유) 측정 시점에 따라"
    echo "# 임계값 아래일 수 있다. 경고 로직 확인을 위해 임계값만 낮춰 1회 실행한다."
    echo "# (기본값은 그대로이며 cron 실행에는 영향 없음)"
    echo "# ---------------------------------------------------------------"
    echo "\$ sudo -u agent-admin env CPU_WARN=0 MEM_WARN=1 DISK_WARN=0 $AGENT_HOME/bin/monitor.sh"
    rc=0; runuser -u agent-admin -- env CPU_WARN=0 MEM_WARN=1 DISK_WARN=0 "$AGENT_HOME/bin/monitor.sh" 2>&1 || rc=$?; echo "(exit code: $rc)"
} >> "$OUT/06-monitor-run.txt"

step "7·8. crontab 등록 + 자동 실행 확인 (약 70초 대기)"
new 07-cron.txt "crontab 등록과 monitor.log 자동 누적"
cap 07-cron.txt crontab -u agent-admin -l
cap 07-cron.txt systemctl is-active cron
before=$(wc -l < "$AGENT_LOG_DIR/monitor.log")
{ echo "# 대기 전: $(date '+%H:%M:%S')  monitor.log ${before}줄"; echo "\$ tail -n 3 $AGENT_LOG_DIR/monitor.log"; tail -n 3 "$AGENT_LOG_DIR/monitor.log"; echo; } >> "$OUT/07-cron.txt"
for i in $(seq 70 -10 10); do printf '\r  대기 중... %2ds ' "$i"; sleep 10; done; echo
after=$(wc -l < "$AGENT_LOG_DIR/monitor.log")
{ echo "# 대기 후: $(date '+%H:%M:%S')  monitor.log ${after}줄 (+$((after - before)))"; echo "\$ tail -n 5 $AGENT_LOG_DIR/monitor.log"; tail -n 5 "$AGENT_LOG_DIR/monitor.log"; echo; } >> "$OUT/07-cron.txt"
cap 07-cron.txt bash -c "journalctl -u cron --since '-3 min' --no-pager | grep -i agent-admin | tail -5"
cap 07-cron.txt ls -l "$AGENT_LOG_DIR"
[ "$after" -gt "$before" ] && ok "cron 이 monitor.log 에 $((after - before))줄 추가함" || warn "70초 동안 로그가 늘지 않았습니다. cron/앱 상태를 확인하세요"

step "(보너스 1) report.sh"
new 08-report.txt "report.sh 통계 리포트"
cap 08-report.txt runuser -u agent-admin -- "$AGENT_HOME/bin/report.sh"
first=$(sed -nE 's/^\[([0-9-]{10} [0-9:]{8})\] PID:.*/\1/p' "$AGENT_LOG_DIR/monitor.log" | head -1)
last=$(sed -nE 's/^\[([0-9-]{10} [0-9:]{8})\] PID:.*/\1/p' "$AGENT_LOG_DIR/monitor.log" | tail -1)
cap 08-report.txt runuser -u agent-admin -- "$AGENT_HOME/bin/report.sh" --from "$first" --to "$last" --last 3

step "(보너스 2) log_retention.sh — 날짜를 조작한 시연용 파일로"
new 09-retention.txt "log_retention.sh 보존 정책 시연"
ARCH=/var/log/monitor/agent-app/archive
{
    echo "# 시연용 파일 준비 (agent-admin 으로 생성, 수정 시각만 과거로)"
    echo "#   demo-old.log      : 8일 전  → 압축·이동 대상"
    echo "#   demo-new.log      : 지금    → 대상 아님"
    echo "#   demo-expired.log.gz: 31일 전 → 아카이브 삭제 대상"
} >> "$OUT/09-retention.txt"
runuser -u agent-admin -- bash -c "echo demo > '$AGENT_LOG_DIR/demo-old.log'; touch -d '8 days ago' '$AGENT_LOG_DIR/demo-old.log'
  echo demo > '$AGENT_LOG_DIR/demo-new.log'
  echo demo | gzip > '$ARCH/demo-expired.log.gz'; touch -d '31 days ago' '$ARCH/demo-expired.log.gz'"
cap 09-retention.txt ls -l --time-style=long-iso "$AGENT_LOG_DIR" "$ARCH"
cap 09-retention.txt runuser -u agent-admin -- "$AGENT_HOME/bin/log_retention.sh" --dry-run
cap 09-retention.txt runuser -u agent-admin -- "$AGENT_HOME/bin/log_retention.sh"
cap 09-retention.txt ls -l --time-style=long-iso "$AGENT_LOG_DIR" "$ARCH"
cap 09-retention.txt runuser -u agent-admin -- "$AGENT_HOME/bin/log_retention.sh"
rm -f "$AGENT_LOG_DIR/demo-new.log" "$ARCH"/demo-*.gz

ok "수집 완료: $OUT"
ls -l "$OUT" | sed 's/^/    /'
