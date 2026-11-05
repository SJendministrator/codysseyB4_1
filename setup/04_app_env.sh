#!/usr/bin/env bash
# =============================================================
# 04. 앱 실행 환경
#   - 환경 변수를 /etc/profile.d 에 등록 (모든 로그인 셸에서 동일한 값)
#   - 키 파일 생성: $AGENT_HOME/api_keys/t_secret.key
#   - (선택) 앱 바이너리를 $AGENT_HOME 으로 복사
#
# 사용법: sudo ./setup/04_app_env.sh [앱 바이너리 경로]
#   예)   sudo ./setup/04_app_env.sh /Users/<맥아이디>/Downloads/agent-app/agent-app-linux-arm64
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

APP_SRC="${1:-}"

step "환경 변수 등록: /etc/profile.d/agent-app.sh"
run install -o root -g root -m 644 "$REPO_ROOT/config/agent-app.env" /etc/profile.d/agent-app.sh
sed 's/^/    /' /etc/profile.d/agent-app.sh | grep export

step "키 파일 생성: $AGENT_KEY_PATH"
printf 'agent_api_key_test\n' > "$AGENT_KEY_PATH"
chown agent-admin:agent-core "$AGENT_KEY_PATH"
chmod 640 "$AGENT_KEY_PATH"
ls -l "$AGENT_KEY_PATH" | sed 's/^/    /'
echo "    내용: $(cat "$AGENT_KEY_PATH")  ($(wc -l < "$AGENT_KEY_PATH")줄)"

if [ -n "$APP_SRC" ]; then
    step "앱 바이너리 배치"
    [ -f "$APP_SRC" ] || die "파일이 없습니다: $APP_SRC"
    dst="$AGENT_HOME/$(basename "$APP_SRC")"
    run install -o agent-admin -g agent-core -m 750 "$APP_SRC" "$dst"
    file "$dst" 2>/dev/null | sed 's/^/    /' || true
    arch=$(uname -m)
    case "$(basename "$dst")" in
        *arm64*)  [ "$arch" = aarch64 ] || warn "이 서버는 $arch 인데 arm64 바이너리입니다" ;;
        *x86*|*amd64*) [ "$arch" = x86_64 ] || warn "이 서버는 $arch 인데 x86 바이너리입니다" ;;
    esac
    ok "$dst"
fi

step "검증: agent-admin 로그인 셸에서 보이는 값"
runuser -l agent-admin -c 'env | grep ^AGENT_ | sort' | sed 's/^/    /'
for v in AGENT_HOME AGENT_PORT AGENT_UPLOAD_DIR AGENT_KEY_PATH AGENT_LOG_DIR; do
    runuser -l agent-admin -c "[ -n \"\${$v:-}\" ]" || die "$v 가 agent-admin 셸에 없습니다"
done
runuser -u agent-admin -- test -r "$AGENT_KEY_PATH" || die "agent-admin 이 키 파일을 읽을 수 없습니다"
runuser -u agent-admin -- test -w "$AGENT_LOG_DIR"  || die "agent-admin 이 로그 디렉터리에 쓸 수 없습니다"
ok "환경 변수 5개, 키 파일 읽기, 로그 디렉터리 쓰기 확인"

echo
echo "  다음: 새 터미널에서 앱 실행 (root 금지, Ctrl+C 로 종료)"
echo "    sudo -iu agent-admin"
echo "    \$AGENT_HOME/agent-app-linux-*"
