#!/usr/bin/env bash
# =============================================================
# log_retention.sh — 시간 기반 로그 보존 정책 (보너스 2)
#
#   1) /var/log/agent-app/*.log 중 7일 이상 지난 파일 → gzip 압축
#   2) 압축본을 /var/log/monitor/agent-app/archive/ 로 이동
#   3) archive/*.gz 중 아카이브된 지 30일 이상 지난 파일 → 삭제
#
# 실행: agent-admin crontab, 매일 03:10
# 사용법: log_retention.sh [--dry-run]
#   테스트용 환경 변수: COMPRESS_DAYS(기본 7), DELETE_DAYS(기본 30)
#
# 예외 처리: 디렉터리 없음 / 권한 부족 / 대상 0개 / 이름 충돌 / 사용 중인 monitor.log
#            → 경고만 남기고 안전하게 계속하거나 종료 (데이터를 지우는 쪽으로 실패하지 않는다)
# =============================================================
set -u

SRC_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"
COMPRESS_DAYS="${COMPRESS_DAYS:-7}"
DELETE_DAYS="${DELETE_DAYS:-30}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "[$(ts)] [INFO] $*"; }
warn() { echo "[$(ts)] [WARNING] $*"; }
err()  { echo "[$(ts)] [ERROR] $*" >&2; }
do_()  { if [ "$DRY" -eq 1 ]; then echo "    (dry-run) $*"; else "$@"; fi; }

[[ "$COMPRESS_DAYS" =~ ^[0-9]+$ && "$DELETE_DAYS" =~ ^[0-9]+$ ]] || { err "일수는 숫자여야 합니다"; exit 1; }
[ "$DRY" -eq 1 ] && info "dry-run: 실제로 바꾸지 않고 대상만 출력합니다"
info "정책: ${COMPRESS_DAYS}일 경과 *.log 압축·이동, ${DELETE_DAYS}일 경과 아카이브 삭제"

# find -mtime +N 은 "N일을 꽉 채우고 더 지난" 파일이라, "N일 이상"은 +(N-1)
age_arg() { [ "$1" -eq 0 ] && echo "-mmin +0" || echo "-mtime +$(( $1 - 1 ))"; }

# ---------- 1·2) 압축 후 아카이브로 이동 ----------
if [ ! -d "$SRC_DIR" ]; then
    warn "원본 로그 디렉터리가 없습니다: $SRC_DIR (압축 단계 건너뜀)"
elif [ ! -r "$SRC_DIR" ] || [ ! -x "$SRC_DIR" ]; then
    warn "원본 로그 디렉터리를 읽을 권한이 없습니다: $SRC_DIR (user=$(id -un))"
else
    if [ ! -d "$ARCHIVE_DIR" ]; then
        if [ "$DRY" -eq 0 ] && ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
            err "아카이브 디렉터리를 만들 수 없습니다: $ARCHIVE_DIR (권한 확인 필요). 원본은 그대로 둡니다."
            exit 1
        fi
        info "아카이브 디렉터리 생성: $ARCHIVE_DIR"
    fi
    if [ -d "$ARCHIVE_DIR" ] && [ ! -w "$ARCHIVE_DIR" ]; then
        err "아카이브 디렉터리에 쓸 수 없습니다: $ARCHIVE_DIR. 원본은 그대로 둡니다."
        exit 1
    fi

    # shellcheck disable=SC2046
    mapfile -t targets < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.log' ! -name 'monitor.log' $(age_arg "$COMPRESS_DAYS") | sort)
    if [ "${#targets[@]}" -eq 0 ]; then
        info "압축 대상 없음 (${COMPRESS_DAYS}일 이상 지난 *.log 0개)"
    fi
    for f in "${targets[@]}"; do
        if [ ! -r "$f" ] || [ ! -w "$SRC_DIR" ]; then
            warn "권한 부족으로 건너뜀: $f"; continue
        fi
        dest="$ARCHIVE_DIR/$(basename "$f").gz"
        [ -e "$dest" ] && dest="$ARCHIVE_DIR/$(basename "$f" .log).$(date +%Y%m%d%H%M%S).log.gz"
        # 임시 파일에 먼저 압축 → 성공했을 때만 원본 삭제 (중간 실패 시 원본 보존)
        if [ "$DRY" -eq 1 ]; then
            echo "    (dry-run) gzip $f -> $dest"; continue
        fi
        if gzip -9 -c -- "$f" > "$dest.tmp" && mv -- "$dest.tmp" "$dest"; then
            touch -- "$dest"     # 보관 기간(30일)은 "아카이브된 시점"부터 센다
            rm -f -- "$f"
            info "압축·이동: $f -> $dest ($(stat -c %s "$dest") bytes)"
        else
            rm -f -- "$dest.tmp"
            warn "압축 실패, 원본 유지: $f"
        fi
    done
fi

# ---------- 3) 오래된 아카이브 삭제 ----------
if [ ! -d "$ARCHIVE_DIR" ]; then
    info "아카이브 디렉터리가 아직 없습니다: $ARCHIVE_DIR (삭제 단계 건너뜀)"
    exit 0
fi
# shellcheck disable=SC2046
mapfile -t olds < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' $(age_arg "$DELETE_DAYS") | sort)
if [ "${#olds[@]}" -eq 0 ]; then
    info "삭제 대상 없음 (${DELETE_DAYS}일 이상 지난 아카이브 0개)"
fi
for f in "${olds[@]}"; do
    if do_ rm -f -- "$f"; then info "삭제: $f"; else warn "삭제 실패(권한?): $f"; fi
done

info "완료"
exit 0
