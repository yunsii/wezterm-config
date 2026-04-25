#!/usr/bin/env bash
# Benchmark harness for the Alt+/ attention popup pipeline.
#
# Triggers N open/close cycles via `tmux send-keys M-/`, then reads the
# `category="attention.perf"` entries the picker emits to runtime.log,
# extracts the per-bucket timings, and prints min/p50/p95/max stats. Used
# to drive the optimization loop: change one thing → rerun → compare.
#
# Usage:
#   scripts/dev/bench-attention-popup.sh                     # 50 timed + 3 warmup, current attached tmux client
#   scripts/dev/bench-attention-popup.sh --runs 100          # more samples
#   scripts/dev/bench-attention-popup.sh --target sess:0.0   # explicit target pane
#   scripts/dev/bench-attention-popup.sh --warmup 0          # no warmup discard
#   scripts/dev/bench-attention-popup.sh --label baseline    # tagged into output for diffing across runs
#
# Disruption: each timed run pops the attention overlay on your screen
# briefly. Don't run during a live demo. The script settles ~600ms per
# cycle to let the popup render + tear down cleanly.
set -euo pipefail

runs=50
warmup=3
target=''
label="$(date +%H%M%S)"

while (( $# )); do
  case "$1" in
    --runs)   runs="${2:?missing runs}";   shift 2 ;;
    --warmup) warmup="${2:?missing warmup}"; shift 2 ;;
    --target) target="${2:?missing target}"; shift 2 ;;
    --label)  label="${2:?missing label}";   shift 2 ;;
    -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if ! command -v tmux >/dev/null 2>&1; then
  printf 'bench: tmux not in PATH\n' >&2; exit 1
fi

if [[ -z "$target" ]]; then
  # Resolve the attached client's currently-active pane. Works when this
  # script is invoked from outside any tmux pane (e.g. via Claude's bash
  # tool) — there's a single attached client to send to.
  target="$(tmux display-message -p '#{client_session}:#{client_window}.#{pane_index}' 2>/dev/null || true)"
fi
if [[ -z "$target" ]]; then
  printf 'bench: could not resolve target tmux pane (no attached client?). Pass --target sess:win.pane explicitly.\n' >&2
  exit 1
fi
printf 'bench: target=%s runs=%d warmup=%d label=%s\n' "$target" "$runs" "$warmup" "$label" >&2

log_file="${WEZTERM_RUNTIME_LOG_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime/logs/runtime.log}"
if [[ ! -f "$log_file" ]]; then
  mkdir -p "$(dirname "$log_file")"
  : > "$log_file"
fi

trigger_cycle() {
  # Open the popup, wait for first paint + perf-log emit, then close it
  # via the same chord (the picker's input loop matches \x1b/ as exit).
  tmux send-keys -t "$target" M-/
  sleep 0.4
  tmux send-keys -t "$target" M-/
  sleep 0.2
}

# Warmup: prime tmux popup pty caches, prime go/bash binary in OS page
# cache, prime the live-panes.json write path. Discarded from stats.
if (( warmup > 0 )); then
  printf 'bench: warmup ' >&2
  for ((i = 1; i <= warmup; i++)); do
    trigger_cycle
    printf '.' >&2
  done
  printf ' done\n' >&2
fi

# Capture log offset AFTER warmup so warmup events are excluded.
start_offset="$(wc -c < "$log_file")"
start_wall_ms="$(date +%s%3N)"

printf 'bench: timing ' >&2
for ((i = 1; i <= runs; i++)); do
  trigger_cycle
  if (( i % 10 == 0 )); then
    printf '%d' "$i" >&2
  else
    printf '.' >&2
  fi
done
printf ' done\n' >&2

end_wall_ms="$(date +%s%3N)"
printf 'bench: %d cycles in %.1fs\n' "$runs" "$(awk "BEGIN{printf \"%.1f\", ($end_wall_ms - $start_wall_ms) / 1000}")" >&2

# Extract one-row-per-cycle perf data from log entries written after
# start_offset. paint_kind="first" filters out the up/down repaints.
tsv="$(tail -c +"$((start_offset + 1))" "$log_file" |
  awk '
    /category="attention\.perf"/ && /paint_kind="first"/ {
      kind=""; tot=""; lua=""; menu=""; pic=""
      for (i=1; i<=NF; i++) {
        if (match($i, /^picker_kind="[^"]+"/))  { kind = substr($i, 14, length($i) - 14) }
        else if (match($i, /^total_ms="[^"]+"/))   { tot  = substr($i, 11, length($i) - 11) }
        else if (match($i, /^lua_ms="[^"]+"/))     { lua  = substr($i,  9, length($i) -  9) }
        else if (match($i, /^menu_ms="[^"]+"/))    { menu = substr($i, 10, length($i) - 10) }
        else if (match($i, /^picker_ms="[^"]+"/))  { pic  = substr($i, 12, length($i) - 12) }
      }
      if (kind != "" && tot != "") print kind "\t" tot "\t" lua "\t" menu "\t" pic
    }
  ')"

if [[ -z "$tsv" ]]; then
  printf 'bench: no perf rows captured\n' >&2
  printf 'bench: hint — make sure WEZTERM_RUNTIME_LOG_CATEGORIES does not exclude attention.perf\n' >&2
  printf 'bench:        current value: %q\n' "${WEZTERM_RUNTIME_LOG_CATEGORIES:-<unset, all categories enabled>}" >&2
  exit 1
fi

stat_for_kind() {
  local kind="$1"
  local rows
  rows="$(awk -F'\t' -v k="$kind" '$1 == k' <<<"$tsv")"
  [[ -n "$rows" ]] || return 0

  local n
  n="$(wc -l <<<"$rows")"
  printf '\n=== %s · n=%d · label=%s ===\n' "$kind" "$n" "$label"
  printf '%-12s %6s %6s %6s %6s %6s\n' 'metric' 'min' 'p50' 'p95' 'max' 'mean'

  local cols=(total_ms lua_ms menu_ms picker_ms)
  local idxs=(2 3 4 5)
  local i
  for i in "${!cols[@]}"; do
    local col="${idxs[$i]}"
    local sorted
    sorted="$(awk -F'\t' -v c="$col" '{print $c}' <<<"$rows" | sort -n)"
    local pmin pmax p50 p95 mean
    pmin="$(head -n1 <<<"$sorted")"
    pmax="$(tail -n1 <<<"$sorted")"
    # 1-indexed line for the percentile (truncate, clamp).
    local i50 i95
    i50=$(awk "BEGIN{ x = int(($n - 1) * 0.50) + 1; if (x < 1) x = 1; if (x > $n) x = $n; print x }")
    i95=$(awk "BEGIN{ x = int(($n - 1) * 0.95) + 1; if (x < 1) x = 1; if (x > $n) x = $n; print x }")
    p50="$(sed -n "${i50}p" <<<"$sorted")"
    p95="$(sed -n "${i95}p" <<<"$sorted")"
    mean="$(awk '{ s += $1 } END { if (NR > 0) printf "%.0f", s/NR; else print "-" }' <<<"$sorted")"
    printf '%-12s %6s %6s %6s %6s %6s\n' "${cols[$i]}" "$pmin" "$p50" "$p95" "$pmax" "$mean"
  done
}

printf '\n--- benchmark results ---\n'
stat_for_kind go
stat_for_kind bash

printf '\n--- raw rows (kind\\ttotal\\tlua\\tmenu\\tpicker) ---\n'
printf '%s\n' "$tsv"
