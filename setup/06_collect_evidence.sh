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
    { echo "\$ $*"; "$@" 2>&1; echo; } >> "$f"
}
new() { local f="$OUT/$1"; : > "$f"; echo "# $2" >> "$f"; echo "# 수집: $(date '+%Y-%m-%d %H:%M:%S %Z')  host: $(hostname)" >> "$f"; echo >> "$f"; echo "  -> evidence/$1"; }

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
cap 05-app-boot.txt bash -c "ls -l '$KEY_FILE'; cat '$KEY_FILE'"
if [ -s "$BOOT_LOG" ]; then
    cap 05-app-boot.txt cat "$BOOT_LOG"
else
    warn "부팅 로그가 없습니다: $BOOT_LOG  (README 4단계처럼 tee 로 저장해 주세요)"
    echo "(부팅 로그 없음: $BOOT_LOG)" >> "$OUT/05-app-boot.txt"
fi
cap 05-app-boot.txt bash -c "ps -o user,pid,ppid,cmd -e | grep -E '[a]gent-app-linux|[a]gent_app\\.py'"
cap 05-app-boot.txt bash -c "ss -tlnp | grep ':${AGENT_PORT}'"

step "6. monitor.sh 실행 결과 (agent-admin)"
new 06-monitor-run.txt "monitor.sh 수동 실행"
cap 06-monitor-run.txt runuser -u agent-admin -- "$AGENT_HOME/bin/monitor.sh"
echo "exit code: $(runuser -u agent-admin -- "$AGENT_HOME/bin/monitor.sh" >/dev/null 2>&1; echo $?)" >> "$OUT/06-monitor-run.txt"

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

ok "수집 완료: $OUT"
ls -l "$OUT" | sed 's/^/    /'
