#!/usr/bin/env bash
# =============================================================
# 03. 계정 · 그룹 · 디렉터리 · 권한(ACL)
#
#   계정                       그룹
#   agent-admin (운영, cron)   agent-common : admin, dev, test   → 공유 디렉터리
#   agent-dev   (개발)         agent-core   : admin, dev         → 보안 디렉터리
#   agent-test  (QA)
#
#   디렉터리                        소유자:그룹                 권한
#   $AGENT_HOME                     agent-admin:agent-common    2750
#   $AGENT_HOME/upload_files        agent-admin:agent-common    2770 + ACL(common rwx)
#   $AGENT_HOME/api_keys            agent-admin:agent-core      2770 + ACL(core rwx)
#   $AGENT_HOME/bin                 agent-dev:agent-core        2750
#   /var/log/agent-app              agent-admin:agent-core      2770 + ACL(core rwx)
#
# 사용법: sudo ./setup/03_accounts.sh
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

USERS=(agent-admin agent-dev agent-test)
declare -A GROUP_MEMBERS=(
    [agent-common]="agent-admin agent-dev agent-test"
    [agent-core]="agent-admin agent-dev"
)

step "acl 도구 설치 확인"
command -v setfacl >/dev/null 2>&1 || { run apt-get update -qq; run apt-get install -y -qq acl; }
ok "setfacl/getfacl 사용 가능"

step "그룹 생성"
for g in agent-common agent-core; do
    getent group "$g" >/dev/null || run groupadd "$g"
    ok "$g"
done

step "계정 생성 (홈 디렉터리 + bash)"
for u in "${USERS[@]}"; do
    id "$u" >/dev/null 2>&1 || run useradd -m -s /bin/bash "$u"
    ok "$u"
done

step "그룹 멤버 지정"
for g in "${!GROUP_MEMBERS[@]}"; do
    for u in ${GROUP_MEMBERS[$g]}; do
        run usermod -aG "$g" "$u"
    done
done
# agent-test 가 agent-core 에 실수로 들어가 있으면 제거 (최소 권한)
if [[ " $(id -nG agent-test) " == *" agent-core "* ]]; then
    run gpasswd -d agent-test agent-core
fi
for u in "${USERS[@]}"; do echo "    $(id "$u")"; done

# ---------- 디렉터리 ----------
# mkdir_perm <경로> <소유자> <그룹> <모드>
mkdir_perm() {
    install -d -o "$2" -g "$3" -m "$4" "$1"
    chown "$2:$3" "$1"; chmod "$4" "$1"     # 이미 있던 경우에도 강제 적용
}

# acl_group <경로> <그룹> <권한>  : 지금 있는 것 + 앞으로 생길 파일(default ACL) 모두
acl_group() {
    setfacl -m "g:$2:$3" "$1"
    setfacl -d -m "u::rwx,g::rwx,g:$2:$3,o::---" "$1"
}

step "AGENT_HOME 상위 경로 통과 권한"
# Ubuntu 22.04 는 홈 디렉터리가 750 이라 dev/test 가 /home/agent-admin 을 지나갈 수 없다.
# 목록 보기(r)는 주지 않고 통과(x)만 agent-common 에 허용한다.
run setfacl -m g:agent-common:--x /home/agent-admin
ok "/home/agent-admin : agent-common 통과(x)만 허용"

step "디렉터리 생성 및 권한"
mkdir_perm "$AGENT_HOME"              agent-admin agent-common 2750
mkdir_perm "$AGENT_UPLOAD_DIR"        agent-admin agent-common 2770
mkdir_perm "$AGENT_HOME/api_keys"     agent-admin agent-core   2770
mkdir_perm "$AGENT_HOME/bin"          agent-dev   agent-core   2750
mkdir_perm "$AGENT_LOG_DIR"           agent-admin agent-core   2770

acl_group "$AGENT_UPLOAD_DIR"     agent-common rwx
acl_group "$AGENT_HOME/api_keys"  agent-core   rwx
acl_group "$AGENT_LOG_DIR"        agent-core   rwx
ok "setgid(2xxx): 안에서 만든 파일이 디렉터리 그룹을 자동으로 물려받음"
ok "default ACL: 누가 어떤 umask 로 만들어도 그룹 rw 가 유지됨"

step "확인: ls -ld"
ls -ld /home/agent-admin "$AGENT_HOME" "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_HOME/bin" "$AGENT_LOG_DIR" | sed 's/^/    /'

step "확인: getfacl"
for d in "$AGENT_UPLOAD_DIR" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR"; do
    getfacl -p "$d" 2>/dev/null | sed 's/^/    /'
done

# ---------- 실제 접근 테스트 ----------
step "접근 테스트 (각 계정으로 직접 시도)"
# expect <계정> <기대: allow|deny> <설명> <명령...>
fail=0
expect() {
    local u="$1" want="$2" desc="$3"; shift 3
    if runuser -u "$u" -- "$@" >/dev/null 2>&1; then got=allow; else got=deny; fi
    if [ "$got" = "$want" ]; then ok "$(printf '%-12s %-6s %s' "$u" "$got" "$desc")"
    else warn "$(printf '%-12s %-6s %s (기대: %s)' "$u" "$got" "$desc" "$want")"; fail=1; fi
}
probe="$AGENT_UPLOAD_DIR/.acl_probe_$$"
for u in agent-admin agent-dev agent-test; do
    expect "$u" allow "upload_files 쓰기" touch "$probe.$u"
done
for u in agent-admin agent-dev agent-test; do
    expect "$u" allow "upload_files 의 다른 사람 파일 수정" sh -c "echo x >> '$probe.agent-admin'"
done
expect agent-admin allow "api_keys 목록"       ls "$AGENT_HOME/api_keys"
expect agent-dev   allow "api_keys 목록"       ls "$AGENT_HOME/api_keys"
expect agent-test  deny  "api_keys 목록"       ls "$AGENT_HOME/api_keys"
expect agent-admin allow "로그 디렉터리 쓰기"  touch "$AGENT_LOG_DIR/.probe"
expect agent-dev   allow "로그 디렉터리 쓰기"  touch "$AGENT_LOG_DIR/.probe"
expect agent-test  deny  "로그 디렉터리 읽기"  ls "$AGENT_LOG_DIR"
expect agent-test  deny  "/home/agent-admin 목록 보기" ls /home/agent-admin
rm -f "$probe".* "$AGENT_LOG_DIR/.probe"

[ "$fail" -eq 0 ] || die "기대와 다른 접근 결과가 있습니다 (위 WARN 확인)"
ok "공유(upload_files) = agent-common, 보안(api_keys, 로그) = agent-core ONLY 확인"
