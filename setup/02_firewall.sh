#!/usr/bin/env bash
# =============================================================
# 02. 방화벽 (UFW)
#   - 기본 정책: 들어오는 연결 전부 차단, 나가는 연결 허용
#   - 허용: 20022/tcp (SSH), 15034/tcp (APP) 두 개만
# 사용법: sudo ./setup/02_firewall.sh
#
# 주의: 원격 SSH 로 접속한 서버라면 반드시 20022 허용 "후에" enable 해야
#       접속이 끊기지 않는다. 이 스크립트는 그 순서를 지킨다.
# =============================================================
source "$(dirname "$0")/common.sh"
require_root

ALLOW_PORTS=(20022/tcp "${AGENT_PORT}/tcp")

step "ufw 설치 확인"
if ! command -v ufw >/dev/null 2>&1; then
    run apt-get update -qq
    run apt-get install -y -qq ufw
fi
ver="$(ufw version)"; ok "ufw: ${ver%%$'\n'*}"

step "규칙 초기화 (이전에 열어둔 22 등 남은 규칙 제거)"
run ufw --force reset >/dev/null

step "기본 정책"
run ufw default deny incoming
run ufw default allow outgoing

step "허용 포트 추가 (enable 전에 먼저)"
for p in "${ALLOW_PORTS[@]}"; do
    run ufw allow "$p"
done

step "방화벽 활성화"
if ! ufw --force enable; then
    die "ufw 활성화 실패. 컨테이너라면 iptables 권한이 없을 수 있습니다 (OrbStack 머신 또는 --privileged 필요)"
fi

step "검증 (ufw status verbose)"
ufw status verbose | sed 's/^/    /'

status="$(ufw status)"
grep -q '^Status: active' <<< "$status" || die "ufw 가 비활성 상태입니다"
# 허용된 포트 목록이 정확히 두 개인지 (IPv4/IPv6 중복 제거)
allowed=$(ufw status | awk '/ALLOW/ {print $1}' | sed 's/ (v6)//' | sort -u | tr '\n' ' ')
expected=$(printf '%s\n' "${ALLOW_PORTS[@]}" | sort -u | tr '\n' ' ')
[ "$allowed" = "$expected" ] || die "허용 포트가 다릅니다. 현재: $allowed / 기대: $expected"
ok "UFW active, 인바운드 허용: $allowed"
