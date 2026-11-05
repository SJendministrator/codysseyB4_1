#!/usr/bin/env bash
# =============================================================
# 05. 스크립트 배치 + cron 등록
#   - bin/*.sh → $AGENT_HOME/bin/  (소유 agent-dev, 그룹 agent-core, 750)
#   - (보너스) 아카이브 디렉터리 /var/log/monitor/agent-app/archive
#   - agent-admin crontab 등록 (매분 monitor.sh, 매일 log_retention.sh)
#
# 사용법: sudo ./setup/05_deploy_cron.sh
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

BIN="$AGENT_HOME/bin"
ARCHIVE=/var/log/monitor/agent-app/archive

step "스크립트 배치: $BIN"
for s in monitor.sh report.sh log_retention.sh; do
    run install -o agent-dev -g agent-core -m 750 "$REPO_ROOT/bin/$s" "$BIN/$s"
done
ls -l "$BIN" | sed 's/^/    /'

step "실행 권한 확인 (750 = 소유자 rwx, agent-core r-x, 그 외 없음)"
fail=0
check() {
    if runuser -u "$1" -- test -x "$BIN/monitor.sh"; then got=allow; else got=deny; fi
    [ "$got" = "$2" ] && ok "$1: $got" || { warn "$1: $got (기대: $2)"; fail=1; }
}
check agent-dev allow; check agent-admin allow; check agent-test deny
[ "$fail" -eq 0 ] || die "실행 권한이 기대와 다릅니다"

step "(보너스) 아카이브 디렉터리: $ARCHIVE"
install -d -o agent-admin -g agent-core -m 2770 /var/log/monitor /var/log/monitor/agent-app "$ARCHIVE"
setfacl -d -m u::rwx,g::rwx,o::--- "$ARCHIVE"
ls -ld /var/log/monitor/agent-app "$ARCHIVE" | sed 's/^/    /'

step "cron 서비스"
command -v crontab >/dev/null 2>&1 || { run apt-get update -qq; run apt-get install -y -qq cron; }
run systemctl enable --now cron
systemctl is-active cron | sed 's/^/    cron: /'

step "agent-admin crontab 등록"
run crontab -u agent-admin "$REPO_ROOT/config/crontab.agent-admin"
crontab -u agent-admin -l | grep -v '^#' | grep -v '^$' | sed 's/^/    /'

ok "등록 완료. 1~2분 뒤 확인: tail -n 3 $AGENT_LOG_DIR/monitor.log"
