#!/usr/bin/env bash
# setup/*.sh 공통 함수. 직접 실행하지 않고 각 스크립트가 source 한다.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_step=$'\e[36m'; c_off=$'\e[0m'
step() { echo; echo "${c_step}==> $*${c_off}"; }
ok()   { echo "  ${c_ok}[OK]${c_off} $*"; }
warn() { echo "  ${c_warn}[WARN]${c_off} $*"; }
die()  { echo "  ${c_err}[FAIL]${c_off} $*" >&2; exit 1; }
run()  { echo "  \$ $*"; "$@"; }     # 실행하는 명령을 그대로 화면에 남긴다 (수행 내역서 캡처용)

require_root() {
    [ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다: sudo $0"
}

# shellcheck source=../config/agent-app.env
source "$REPO_ROOT/config/agent-app.env"
