#!/usr/bin/env bash
# =============================================================
# report.sh — monitor.log 통계 리포트 (보너스 1)
#
# CPU / MEM / DISK 의 평균·최대·최소(발생 시각 포함)와 샘플 수를 출력한다.
#
# 사용법
#   report.sh                                   # monitor.log 전체
#   report.sh --last 10                         # 최근 10개 샘플
#   report.sh --from "2026-11-05 21:00:00" --to "2026-11-05 21:30:00"
#   report.sh --ask                             # 시작/종료 시각을 물어봄
#   report.sh --all                             # 회전된 이전 로그(monitor.*.log)까지 포함
#   report.sh --file /path/to/monitor.log
# =============================================================
set -u

LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
FILE="$LOG_DIR/monitor.log"
LAST=0; FROM=""; TO=""; ALL=0

usage() { sed -n '2,15p' "$0"; exit "${1:-0}"; }
valid_ts() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; }

while [ $# -gt 0 ]; do
    case "$1" in
        --last) LAST="${2:-}"; shift 2 ;;
        --from) FROM="${2:-}"; shift 2 ;;
        --to)   TO="${2:-}";   shift 2 ;;
        --file) FILE="${2:-}"; shift 2 ;;
        --all)  ALL=1; shift ;;
        --ask)
            read -r -p "시작 시각 (YYYY-MM-DD HH:MM:SS, 비우면 처음부터): " FROM
            read -r -p "종료 시각 (YYYY-MM-DD HH:MM:SS, 비우면 끝까지):  " TO
            shift ;;
        -h|--help) usage 0 ;;
        *) echo "알 수 없는 옵션: $1" >&2; usage 1 ;;
    esac
done

[[ "$LAST" =~ ^[0-9]+$ ]]          || { echo "[ERROR] --last 는 숫자여야 합니다: $LAST" >&2; exit 1; }
[ -z "$FROM" ] || valid_ts "$FROM" || { echo "[ERROR] 시각 형식 오류: $FROM" >&2; exit 1; }
[ -z "$TO" ]   || valid_ts "$TO"   || { echo "[ERROR] 시각 형식 오류: $TO" >&2; exit 1; }
[ -r "$FILE" ]                     || { echo "[ERROR] 로그를 읽을 수 없습니다: $FILE" >&2; exit 1; }

# 읽을 파일 목록: --all 이면 회전된 로그를 오래된 순으로 먼저
files=()
if [ "$ALL" -eq 1 ]; then
    while read -r f; do files+=("$f"); done < <(ls -1tr "$(dirname "$FILE")"/monitor.*.log 2>/dev/null)
fi
files+=("$FILE")

# 1) 형식에 맞는 줄만 골라 "시각|CPU|MEM|DISK" 로 정리 (ERROR 줄 등은 제외)
# 2) 기간 필터 (ISO 형식이라 문자열 비교로 시간 비교가 된다)
# 3) --last N
data="$(cat "${files[@]}" \
    | sed -nE 's/^\[([0-9-]{10} [0-9:]{8})\] PID:[^ ]+ CPU:([0-9.]+)% MEM:([0-9.]+)% DISK_USED:([0-9.]+)%.*$/\1|\2|\3|\4/p' \
    | awk -F'|' -v from="$FROM" -v to="$TO" '(from == "" || $1 >= from) && (to == "" || $1 <= to)')"
[ "$LAST" -gt 0 ] && data="$(tail -n "$LAST" <<< "$data")"

if [ -z "$data" ]; then
    echo "====== STATISTICS REPORT ======"
    echo "  분석할 샘플이 없습니다. (file=$FILE${FROM:+, from=$FROM}${TO:+, to=$TO})"
    exit 0
fi

awk -F'|' -v from="$FROM" -v to="$TO" '
function upd(k, v, t) {
    sum[k] += v
    if (!(k in max) || v > max[k]) { max[k] = v; tmax[k] = t }
    if (!(k in min) || v < min[k]) { min[k] = v; tmin[k] = t }
}
function show(title, k) {
    printf "  [%s]\n", title
    printf "    Average : %.1f%%\n", sum[k] / n
    printf "    Maximum : %.1f%% at %s\n", max[k], tmax[k]
    printf "    Minimum : %.1f%% at %s\n", min[k], tmin[k]
}
{ n++; upd("cpu", $2, $1); upd("mem", $3, $1); upd("disk", $4, $1)
  if (n == 1) first = $1; last = $1 }
END {
    print "====== STATISTICS REPORT ======"
    printf "  Range   : %s ~ %s\n", first, last
    show("CPU", "cpu"); show("Memory", "mem"); show("Disk", "disk")
    print  "  [Samples]"
    printf "    Data Points: %d samples\n", n
}' <<< "$data"
