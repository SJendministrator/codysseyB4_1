#!/usr/bin/env bash
# =============================================================
# 01. SSH 보안 설정
#   - 접속 포트 22 → 20022
#   - root 원격 로그인 차단 (PermitRootLogin no)
# 사용법: sudo ./setup/01_ssh.sh
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

CONF=/etc/ssh/sshd_config
SSH_PORT=20022

step "openssh-server 설치 확인"
if ! command -v sshd >/dev/null 2>&1; then
    run apt-get update -qq
    run apt-get install -y -qq openssh-server
fi
ok "sshd: $(command -v sshd)"

step "설정 백업"
[ -f "$CONF.orig" ] || run cp -p "$CONF" "$CONF.orig"
ok "원본 보관: $CONF.orig"

# key 값 설정: 주석 처리된 줄(#Port 22)까지 찾아 교체, 없으면 끝에 추가
set_conf() {
    local key="$1" val="$2"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$CONF"; then
        sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$CONF"
    else
        echo "${key} ${val}" >> "$CONF"
    fi
}

step "Port ${SSH_PORT}, PermitRootLogin no 적용"
set_conf Port "$SSH_PORT"
set_conf PermitRootLogin no
grep -nE '^(Port|PermitRootLogin)[[:space:]]' "$CONF"

# sshd_config.d/*.conf 가 먼저 읽히고, sshd 는 "처음 나온 값"을 쓴다.
# 그래서 드롭인 파일에 같은 키가 있으면 메인 파일 수정이 무시된다.
step "드롭인 설정 충돌 확인 (/etc/ssh/sshd_config.d)"
if grep -rnE '^[[:space:]]*(Port|PermitRootLogin)[[:space:]]' /etc/ssh/sshd_config.d/ 2>/dev/null; then
    die "위 드롭인 파일이 설정을 덮어씁니다. 해당 줄을 지우거나 주석 처리하세요."
fi
ok "충돌 없음"

step "문법 검사 (sshd -t)"
mkdir -p /run/sshd
run sshd -t
ok "문법 오류 없음"

step "sshd 재시작"
# Ubuntu 22.10+ 는 ssh.socket(소켓 활성화)이 포트를 잡는다. 22.04 는 보통 ssh.service.
if systemctl is-enabled ssh.socket >/dev/null 2>&1 && systemctl is-active ssh.socket >/dev/null 2>&1; then
    warn "ssh.socket 사용 중 → 포트 설정을 sshd_config 로 일원화하기 위해 ssh.service 로 전환"
    run systemctl disable --now ssh.socket
    run systemctl enable ssh.service
fi
run systemctl restart ssh
sleep 1

step "검증"
echo "  [실제 적용값: sshd -T]"
sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin) ' | sed 's/^/    /'
echo "  [LISTEN 상태: ss -tulnp]"
ss -tulnp | grep -E "sshd|:${SSH_PORT}\b" | sed 's/^/    /' || true

sshd -T 2>/dev/null | grep -qx "port ${SSH_PORT}"       || die "포트가 ${SSH_PORT} 가 아닙니다"
sshd -T 2>/dev/null | grep -qx "permitrootlogin no"     || die "PermitRootLogin 이 no 가 아닙니다"
ss -tln | grep -q ":${SSH_PORT}\b"                       || die "${SSH_PORT} 포트가 LISTEN 상태가 아닙니다"
ok "SSH: ${SSH_PORT}/tcp LISTEN, root 원격 로그인 차단"
