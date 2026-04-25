#!/usr/bin/env bash
# Time-series view of attention.perf events from runtime.log.
#
# The bench harnesses (bench-menu-prep / bench-attention-popup) answer
# "is this change faster RIGHT NOW?" against a freshly-driven sample.
# This script answers the long-term version: "did the popup get
# slower over the last week?" — by reading the attention.perf rows
# every Alt+/ press already writes to runtime.log, with no extra
# instrumentation.
#
# Examples:
#   scripts/dev/perf-trend.sh                          # last 7 days, daily p50/p95/n
#   scripts/dev/perf-trend.sh --days 14
#   scripts/dev/perf-trend.sh --diff today yesterday   # two-day side-by-side
#   scripts/dev/perf-trend.sh --diff 2026-04-25 2026-04-18
#   scripts/dev/perf-trend.sh --raw 2026-04-25         # dump per-event ms for one day
#   scripts/dev/perf-trend.sh --picker-kind go         # filter by picker kind
#   scripts/dev/perf-trend.sh --watch                  # live tail of incoming presses
#
# Reads paint_kind="first" rows only (the first-frame timing per Alt+/
# press). Repaint events from Up/Down navigation are excluded — they
# muddy the per-press distribution.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$repo_root/runtime/wsl-runtime-paths-lib.sh"

log_file="${WEZTERM_RUNTIME_LOG_FILE:-$WSL_RUNTIME_LOG_FILE}"
days=7
mode='trend'
filter_kind=''     # 'go' / 'bash' / '' (any)
diff_a=''
diff_b=''
raw_day=''

resolve_day() {
  case "$1" in
    today)     date '+%Y-%m-%d' ;;
    yesterday) date -d 'yesterday' '+%Y-%m-%d' ;;
    *)         printf '%s' "$1" ;;
  esac
}

while (( $# )); do
  case "$1" in
    --days)        days="${2:?missing days}"; shift 2 ;;
    --picker-kind) filter_kind="${2:?missing picker kind}"; shift 2 ;;
    --diff)        mode='diff'; diff_a="$(resolve_day "${2:?}")"; diff_b="$(resolve_day "${3:?}")"; shift 3 ;;
    --raw)         mode='raw'; raw_day="$(resolve_day "${2:?}")"; shift 2 ;;
    --watch)       mode='watch'; shift ;;
    --log)         log_file="${2:?}"; shift 2 ;;
    -h|--help)     sed -n '3,21p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$log_file" ]]; then
  printf 'perf-trend: log file not found: %s\n' "$log_file" >&2
  exit 1
fi

# Extract attention.perf paint_kind=first rows for one day. Output: TSV
# of `picker_kind \t total_ms \t lua_ms \t menu_ms \t picker_ms`.
extract_for_day() {
  local day="$1"
  awk -v day="$day" -v want_kind="$filter_kind" '
    index($0, "category=\"attention.perf\"") &&
    index($0, "paint_kind=\"first\"") &&
    index($0, "ts=\"" day) {
      kind=""; tot=""; lua=""; menu=""; pic=""
      for (i = 1; i <= NF; i++) {
        if (match($i, /^picker_kind="[^"]+"/))  { kind = substr($i, 14, length($i) - 14) }
        else if (match($i, /^total_ms="[^"]+"/))   { tot  = substr($i, 11, length($i) - 11) }
        else if (match($i, /^lua_ms="[^"]+"/))     { lua  = substr($i,  9, length($i) -  9) }
        else if (match($i, /^menu_ms="[^"]+"/))    { menu = substr($i, 10, length($i) - 10) }
        else if (match($i, /^picker_ms="[^"]+"/))  { pic  = substr($i, 12, length($i) - 12) }
      }
      if (kind == "") next
      if (want_kind != "" && want_kind != kind) next
      if (tot == "") next
      print kind "\t" tot "\t" lua "\t" menu "\t" pic
    }
  ' "$log_file"
}

# p50 / p95 / mean of a column (1-based) of TSV input on stdin.
percentile_stats() {
  local col="$1"
  awk -v col="$col" '
    {
      v = $col + 0
      a[++n] = v
      sum += v
    }
    END {
      if (n == 0) { print "0\t-\t-\t-\t-"; exit }
      asort(a)
      p50 = a[int((n - 1) * 0.50) + 1]
      p95 = a[int((n - 1) * 0.95) + 1]
      printf "%d\t%d\t%d\t%d\t%.0f\n", n, a[1], p50, p95, sum / n
    }
  '
}

trend_row() {
  local day="$1" rows
  rows="$(extract_for_day "$day")"
  if [[ -z "$rows" ]]; then
    printf '%s  %5s  %5s  %5s  %5s  %5s\n' "$day" '0' '-' '-' '-' '-'
    return
  fi
  local stats
  stats="$(printf '%s\n' "$rows" | awk -F'\t' '{print $2}' | percentile_stats 1)"
  IFS=$'\t' read -r n pmin p50 p95 pmean <<<"$stats"
  printf '%s  %5d  %5sms  %5sms  %5sms  %5sms\n' "$day" "$n" "$pmin" "$p50" "$p95" "$pmean"
}

stage_breakdown() {
  local day="$1" rows
  rows="$(extract_for_day "$day")"
  if [[ -z "$rows" ]]; then
    printf '  (no events on %s)\n' "$day"
    return
  fi
  local n
  n="$(printf '%s\n' "$rows" | wc -l)"
  printf '  n=%d  picker_kind=%s\n' "$n" "${filter_kind:-any}"
  local col label
  for tuple in 'total_ms:2' 'lua_ms:3' 'menu_ms:4' 'picker_ms:5'; do
    label="${tuple%:*}"
    col="${tuple#*:}"
    local stats n_ pmin p50 p95 pmean
    stats="$(printf '%s\n' "$rows" | awk -F'\t' -v c="$col" '{print $c}' | percentile_stats 1)"
    IFS=$'\t' read -r n_ pmin p50 p95 pmean <<<"$stats"
    printf '  %-12s  min=%5sms  p50=%5sms  p95=%5sms  mean=%5sms\n' \
      "$label" "$pmin" "$p50" "$p95" "$pmean"
  done
}

case "$mode" in
  trend)
    printf '\n=== attention.perf — last %d days · log=%s · picker_kind=%s ===\n\n' \
      "$days" "$log_file" "${filter_kind:-any}"
    printf '%-10s  %5s  %7s  %7s  %7s  %7s\n' \
      'day' 'n' 'min' 'p50' 'p95' 'mean'
    printf '%s\n' '-----------  -----  -------  -------  -------  -------'
    for ((i = days - 1; i >= 0; i--)); do
      day="$(date -d "$i days ago" '+%Y-%m-%d')"
      trend_row "$day"
    done
    printf '\nuse --diff <day-a> <day-b> for stage-by-stage comparison\n'
    printf 'use --raw <day> to dump per-press total_ms\n'
    ;;
  diff)
    printf '\n=== attention.perf — %s vs %s · picker_kind=%s ===\n\n' \
      "$diff_a" "$diff_b" "${filter_kind:-any}"
    printf 'A: %s\n' "$diff_a"
    stage_breakdown "$diff_a"
    printf '\nB: %s\n' "$diff_b"
    stage_breakdown "$diff_b"
    ;;
  raw)
    printf '\n=== attention.perf raw rows · %s · picker_kind=%s ===\n' \
      "$raw_day" "${filter_kind:-any}"
    printf '%-12s  %5s  %5s  %5s  %5s\n' \
      'picker_kind' 'total' 'lua' 'menu' 'picker'
    extract_for_day "$raw_day" | sort -k2 -n -t$'\t'
    ;;
  watch)
    # Live tail of paint_kind=first events as they land. Useful when
    # you press Alt+/ a few times after a code change to see the new
    # latency without re-running the full bench harness.
    printf '\n=== attention.perf live · log=%s · picker_kind=%s ===\n' \
      "$log_file" "${filter_kind:-any}"
    printf '%-12s  %-23s  %5s  %5s  %5s  %5s  %s\n' \
      'picker_kind' 'ts' 'total' 'lua' 'menu' 'picker' 'trace_id'
    tail -n0 -F "$log_file" 2>/dev/null | awk -v want_kind="$filter_kind" '
      index($0, "category=\"attention.perf\"") &&
      index($0, "paint_kind=\"first\"") {
        ts=""; trace=""; kind=""; tot=""; lua=""; menu=""; pic=""
        for (i = 1; i <= NF; i++) {
          if      (match($i, /^ts="[^"]+/))           { ts    = substr($i, 5, RLENGTH - 5) }
          else if (match($i, /^trace_id="[^"]+"/))    { trace = substr($i, 11, length($i) - 11) }
          else if (match($i, /^picker_kind="[^"]+"/)) { kind  = substr($i, 14, length($i) - 14) }
          else if (match($i, /^total_ms="[^"]+"/))    { tot   = substr($i, 11, length($i) - 11) }
          else if (match($i, /^lua_ms="[^"]+"/))      { lua   = substr($i,  9, length($i) -  9) }
          else if (match($i, /^menu_ms="[^"]+"/))     { menu  = substr($i, 10, length($i) - 10) }
          else if (match($i, /^picker_ms="[^"]+"/))   { pic   = substr($i, 12, length($i) - 12) }
        }
        # Find the closing quote of ts that may include space (was truncated above)
        if (match($0, /ts="[^"]+"/)) ts = substr($0, RSTART+4, RLENGTH-5)
        if (kind == "") next
        if (want_kind != "" && want_kind != kind) next
        printf "%-12s  %-23s  %5sms %5sms %5sms %5sms  %s\n", kind, ts, tot, lua, menu, pic, trace
        fflush()
      }
    '
    ;;
esac
