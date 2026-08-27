#!/usr/bin/env bash
# Summarise WezTerm key / status-tick latency rows from wezterm.log.
#
# Slow events (default-on, threshold-gated):
#   category="latency" message="slow key handler"
#   category="latency" message="slow status tick"
#
# Full samples (opt-in via diagnostics.wezterm.latency.emit_all):
#   category="latency.perf"
#
# Examples:
#   scripts/dev/latency-report.sh                 # last 7 days, daily counts + p50/p95
#   scripts/dev/latency-report.sh --days 14
#   scripts/dev/latency-report.sh --kind hotkey   # only slow key handlers
#   scripts/dev/latency-report.sh --kind status
#   scripts/dev/latency-report.sh --hotkey-id workspace.switch
#   scripts/dev/latency-report.sh --raw today
#   scripts/dev/latency-report.sh --watch
#   scripts/dev/latency-report.sh --perf          # use latency.perf rows instead
#
# Data source is the Windows-side wezterm.log (Lua writer), not runtime.log.
# See docs/diagnostics.md "Key / status latency".
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/windows-runtime-paths-lib.sh"
windows_runtime_detect_paths >/dev/null 2>&1 || true

log_file="${WINDOWS_RUNTIME_STATE_WSL:-}/logs/wezterm.log"
days=7
mode='trend'
kind_filter=''       # hotkey | status | ''
hotkey_id_filter=''
raw_day=''
use_perf=0

resolve_day() {
  case "$1" in
    today)     date '+%Y-%m-%d' ;;
    yesterday) date -d 'yesterday' '+%Y-%m-%d' ;;
    *)         printf '%s' "$1" ;;
  esac
}

while (( $# )); do
  case "$1" in
    --days)       days="${2:?missing days}"; shift 2 ;;
    --kind)       kind_filter="${2:?missing kind}"; shift 2 ;;
    --hotkey-id)  hotkey_id_filter="${2:?missing hotkey id}"; shift 2 ;;
    --raw)        mode='raw'; raw_day="$(resolve_day "${2:?}")"; shift 2 ;;
    --watch)      mode='watch'; shift ;;
    --perf)       use_perf=1; shift ;;
    --log)        log_file="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '3,22p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$kind_filter" in
  ''|hotkey|status) ;;
  *) printf 'latency-report: --kind must be hotkey|status\n' >&2; exit 2 ;;
esac

if [[ -z "$log_file" || ! -f "$log_file" ]]; then
  printf 'latency-report: log file not found: %s\n' "${log_file:-<empty>}" >&2
  exit 1
fi

category_token='category="latency"'
if (( use_perf )); then
  category_token='category="latency.perf"'
fi

# Output TSV: day \t kind \t hotkey_id \t duration_ms \t message
extract_rows() {
  local day_prefix="${1:-}"
  # Match key="value" on the whole line — do NOT split on whitespace.
  # Values such as ts="2026-08-27 13:45:23.135" and
  # message="slow status tick" contain spaces; default FS would smash
  # them and make every day look empty.
  awk -v day="$day_prefix" \
      -v cat_token="$category_token" \
      -v want_kind="$kind_filter" \
      -v want_hotkey="$hotkey_id_filter" \
      -v perf="$use_perf" '
    index($0, cat_token) == 0 { next }
    day != "" && index($0, "ts=\"" day) == 0 { next }

    {
      kind=""; hotkey=""; dur=""; msg=""; ts=""
      if (match($0, /ts="[^"]+"/)) {
        ts = substr($0, RSTART + 4, RLENGTH - 5)
      }
      if (match($0, /message="[^"]+"/)) {
        msg = substr($0, RSTART + 9, RLENGTH - 10)
      }
      if (match($0, /kind="[^"]+"/)) {
        kind = substr($0, RSTART + 6, RLENGTH - 7)
      }
      if (match($0, /hotkey_id="[^"]+"/)) {
        hotkey = substr($0, RSTART + 11, RLENGTH - 12)
      }
      if (match($0, /duration_ms="[^"]+"/)) {
        dur = substr($0, RSTART + 13, RLENGTH - 14)
      }
      if (dur == "") next
      if (perf == 0) {
        if (msg != "slow key handler" && msg != "slow status tick") next
      }
      if (kind == "" ) {
        if (msg ~ /status/) kind = "status"
        else kind = "hotkey"
      }
      if (want_kind != "" && kind != want_kind) next
      if (want_hotkey != "" && hotkey != want_hotkey) next
      day_out = substr(ts, 1, 10)
      if (day_out == "") day_out = "?"
      print day_out "\t" kind "\t" hotkey "\t" dur "\t" msg
    }
  ' "$log_file"
}

percentile_stats() {
  awk '
    {
      v = $1 + 0
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

print_header() {
  printf '%s\n' "day         n   min    p50    p95   mean   (ms)"
  printf '%s\n' "----------  ---  -----  -----  -----  -----"
}

trend_for_day() {
  local day="$1" rows stats n pmin p50 p95 pmean
  rows="$(extract_rows "$day")"
  if [[ -z "$rows" ]]; then
    printf '%s  %3s  %5s  %5s  %5s  %5s\n' "$day" '0' '-' '-' '-' '-'
    return
  fi
  stats="$(printf '%s\n' "$rows" | awk -F'\t' '{print $4}' | percentile_stats)"
  IFS=$'\t' read -r n pmin p50 p95 pmean <<<"$stats"
  printf '%s  %3d  %5sms  %5sms  %5sms  %5sms\n' "$day" "$n" "$pmin" "$p50" "$p95" "$pmean"
}

top_hotkeys() {
  local day="$1"
  printf '\n  top hotkey_id on %s:\n' "$day"
  extract_rows "$day" | awk -F'\t' '$2=="hotkey" && $3!="" { c[$3]++; s[$3]+=$4 }
    END {
      n = 0
      for (k in c) {
        n++
        avg = s[k] / c[k]
        printf "    %4d  avg=%6.0fms  %s\n", c[k], avg, k
      }
      if (n == 0) print "    (none)"
    }' | sort -nr
}

# Compact "mem=60% load=12.3 runnable=2/3000" suffix from a slow-event line.
pressure_suffix() {
  local line="$1"
  local mem load runnable swap
  mem="$(printf '%s' "$line" | sed -n 's/.*mem_used_pct="\([^"]*\)".*/\1/p')"
  load="$(printf '%s' "$line" | sed -n 's/.*loadavg_1="\([^"]*\)".*/\1/p')"
  runnable="$(printf '%s' "$line" | sed -n 's/.*proc_runnable="\([^"]*\)".*/\1/p')"
  local total
  total="$(printf '%s' "$line" | sed -n 's/.*proc_total="\([^"]*\)".*/\1/p')"
  swap="$(printf '%s' "$line" | sed -n 's/.*swap_used_pct="\([^"]*\)".*/\1/p')"
  if [[ -z "$mem$load$runnable$swap" ]]; then
    return 0
  fi
  printf '  ['
  local first=1
  if [[ -n "$mem" ]]; then
    printf 'mem=%s%%' "$mem"
    first=0
  fi
  if [[ -n "$swap" ]]; then
    (( first )) || printf ' '
    printf 'swap=%s%%' "$swap"
    first=0
  fi
  if [[ -n "$load" ]]; then
    (( first )) || printf ' '
    printf 'load1=%s' "$load"
    first=0
  fi
  if [[ -n "$runnable" && -n "$total" ]]; then
    (( first )) || printf ' '
    printf 'run=%s/%s' "$runnable" "$total"
  fi
  printf ']'
}

case "$mode" in
  raw)
    # Prefer a direct scan so pressure columns survive (extract_rows drops them).
    awk -v day="$raw_day" \
        -v cat_token="$category_token" \
        -v want_kind="$kind_filter" \
        -v want_hotkey="$hotkey_id_filter" \
        -v perf="$use_perf" '
      index($0, cat_token) == 0 { next }
      day != "" && index($0, "ts=\"" day) == 0 { next }
      {
        kind=""; hotkey=""; dur=""; msg=""; ts=""
        mem=""; load=""; runnable=""; total=""; swap=""
        for (i = 1; i <= NF; i++) {
          if (match($i, /^ts="[^"]+"/)) ts = substr($i, 5, length($i) - 5)
          else if (match($i, /^message="[^"]+"/)) msg = substr($i, 10, length($i) - 10)
          else if (match($i, /^kind="[^"]+"/)) kind = substr($i, 7, length($i) - 7)
          else if (match($i, /^hotkey_id="[^"]+"/)) hotkey = substr($i, 12, length($i) - 12)
          else if (match($i, /^duration_ms="[^"]+"/)) dur = substr($i, 14, length($i) - 14)
          else if (match($i, /^mem_used_pct="[^"]+"/)) mem = substr($i, 15, length($i) - 15)
          else if (match($i, /^loadavg_1="[^"]+"/)) load = substr($i, 12, length($i) - 12)
          else if (match($i, /^proc_runnable="[^"]+"/)) runnable = substr($i, 16, length($i) - 16)
          else if (match($i, /^proc_total="[^"]+"/)) total = substr($i, 13, length($i) - 13)
          else if (match($i, /^swap_used_pct="[^"]+"/)) swap = substr($i, 16, length($i) - 16)
        }
        if (dur == "") next
        if (perf == 0) {
          if (msg != "slow key handler" && msg != "slow status tick") next
        }
        if (kind == "") {
          if (msg ~ /status/) kind = "status"
          else kind = "hotkey"
        }
        if (want_kind != "" && kind != want_kind) next
        if (want_hotkey != "" && hotkey != want_hotkey) next
        hk = (hotkey == "" ? "-" : hotkey)
        printf "%s  %-6s  %6sms  %s", substr(ts, 1, 10), kind, dur, hk
        if (mem != "" || load != "" || runnable != "" || swap != "") {
          printf "  ["
          sep = ""
          if (mem != "") { printf "mem=%s%%", mem; sep = " " }
          if (swap != "") { printf "%sswap=%s%%", sep, swap; sep = " " }
          if (load != "") { printf "%sload1=%s", sep, load; sep = " " }
          if (runnable != "" && total != "") printf "%srun=%s/%s", sep, runnable, total
          printf "]"
        }
        printf "\n"
      }
    ' "$log_file"
    ;;
  watch)
    printf 'watching %s for %s rows…\n' "$log_file" "$category_token"
    # shellcheck disable=SC2034
    tail -n0 -F "$log_file" 2>/dev/null | while IFS= read -r line; do
      if [[ "$line" != *"$category_token"* ]]; then
        continue
      fi
      if (( ! use_perf )); then
        if [[ "$line" != *'message="slow key handler"'* && "$line" != *'message="slow status tick"'* ]]; then
          continue
        fi
      fi
      printf '%s' "$line"
      pressure_suffix "$line"
      printf '\n'
    done
    ;;
  trend)
    label='slow latency events'
    if (( use_perf )); then
      label='latency.perf samples'
    fi
    printf 'source=%s\n' "$log_file"
    printf 'filter=%s' "$label"
    if [[ -n "$kind_filter" ]]; then printf ' kind=%s' "$kind_filter"; fi
    if [[ -n "$hotkey_id_filter" ]]; then printf ' hotkey_id=%s' "$hotkey_id_filter"; fi
    printf '\n\n'
    print_header
    today="$(date '+%Y-%m-%d')"
    for (( i = days - 1; i >= 0; i-- )); do
      day="$(date -d "$today -$i days" '+%Y-%m-%d')"
      trend_for_day "$day"
    done
    top_hotkeys "$today"
    ;;
esac
