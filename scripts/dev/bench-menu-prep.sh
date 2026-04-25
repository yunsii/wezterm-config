#!/usr/bin/env bash
# Microbenchmark for the attention popup's PREPARATION work — everything
# tmux-attention-menu.sh does up to (but not including) `tmux display-
# popup`. Runs the menu script with WEZTERM_BENCH_NO_POPUP=1, which makes
# it dump a `__BENCH__` line and exit instead of opening the popup, so
# this harness can sample N times **without disrupting the user's tmux**.
#
# Use this for tight optimization loops (changing menu.sh internals,
# swapping jq for awk, merging subprocess calls, etc.). Use the sister
# script `bench-attention-popup.sh` for end-to-end validation including
# tmux dispatch + popup pty creation + Go picker startup, when the
# changes need to be verified against the real popup pipeline.
#
# Usage:
#   scripts/dev/bench-menu-prep.sh                          # 30 timed + 5 warmup
#   scripts/dev/bench-menu-prep.sh --runs 100 --warmup 10
#   scripts/dev/bench-menu-prep.sh --label after-jq-merge   # tag for cross-run diff
#   scripts/dev/bench-menu-prep.sh --raw                    # dump per-run TSV (no stats)
#
# Output stages (cumulative µs since bench_t0, captured in menu.sh):
#   sourced       — bench_t0 set right after the 3 lib sources finish
#   state_read    — attention.json read + attention_state_init
#   jq_count      — first jq invocation (entries length)
#   live_map      — live-panes.json freshness check + .panes extract (jq×2)
#   jq_rows       — main row-building jq pipeline
#   tsv_write     — bash while-read into arrays + TSV file write
#   picker_branch — go-vs-bash dispatch decision
#   prep_done     — display-message + (bash path) frame pre-render
#
# Stats reported: min · p50 · p95 · max · mean (in milliseconds).
set -euo pipefail

runs=30
warmup=5
label="$(date +%H%M%S)"
raw=0

while (( $# )); do
  case "$1" in
    --runs)   runs="${2:?missing runs}";   shift 2 ;;
    --warmup) warmup="${2:?missing warmup}"; shift 2 ;;
    --label)  label="${2:?missing label}";   shift 2 ;;
    --raw)    raw=1;                         shift ;;
    -h|--help) sed -n '3,29p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
menu_script="$repo_root/runtime/tmux-attention-menu.sh"

if [[ ! -x "$menu_script" ]]; then
  printf 'bench: menu script not found / not executable: %s\n' "$menu_script" >&2
  exit 1
fi

# All output channels off so they don't pollute the harness or fork extra
# processes during the timed window. The menu script's regular logging
# goes to runtime.log; we don't need it for this measurement.
export WEZTERM_BENCH_NO_POPUP=1
export WEZTERM_RUNTIME_LOG_ENABLED=0

run_once() {
  bash "$menu_script" 2>/dev/null | awk '/^__BENCH__/'
}

# Warmup: eat cold-cache cost (first WSL→Windows file reads, jq cold
# binary load, bash exec from disk). Discarded from the sample window.
if (( warmup > 0 )); then
  printf 'bench-menu-prep: warmup ' >&2
  for ((i = 1; i <= warmup; i++)); do
    run_once >/dev/null
    printf '.' >&2
  done
  printf ' done\n' >&2
fi

samples_file="$(mktemp -t wezterm-bench-menu.XXXXXX)"
trap 'rm -f "$samples_file"' EXIT

printf 'bench-menu-prep: timing %d runs ' "$runs" >&2
for ((i = 1; i <= runs; i++)); do
  run_once >> "$samples_file"
  if (( i % 10 == 0 )); then
    printf '%d' "$i" >&2
  else
    printf '.' >&2
  fi
done
printf ' done\n' >&2

if (( raw )); then
  printf '\n--- raw __BENCH__ lines (label=%s) ---\n' "$label"
  cat "$samples_file"
  exit 0
fi

# Collect every stage name that appeared, preserving first-seen order so
# the report rows match the order they fire in menu.sh.
mapfile -t stages < <(awk '
  {
    for (i = 2; i <= NF; i++) {
      n = split($i, kv, "=")
      if (n != 2) continue
      k = kv[1]
      v = kv[2]
      # Skip non-numeric keys (e.g. picker_kind=go).
      if (v !~ /^[0-9]+$/) continue
      if (!(k in seen)) { seen[k]=1; order[++idx]=k }
    }
  }
  END { for (i = 1; i <= idx; i++) print order[i] }
' "$samples_file")

if (( ${#stages[@]} == 0 )); then
  printf 'bench-menu-prep: no __BENCH__ rows captured\n' >&2
  printf 'bench-menu-prep: hint — try running once manually to see the error:\n' >&2
  printf '  WEZTERM_BENCH_NO_POPUP=1 bash %s\n' "$menu_script" >&2
  exit 1
fi

# Compute stats per stage. Stages are CUMULATIVE µs from bench_t0.
# Report each stage's wall time in ms (cumulative) AND its delta from
# the previous stage so it's clear what each step contributes.
printf '\n=== bench-menu-prep · n=%d · label=%s ===\n' "$runs" "$label"
printf '%-14s %8s %8s %8s %8s %8s    %8s %8s %8s\n' \
  'stage' 'min(ms)' 'p50' 'p95' 'max' 'mean' 'Δp50' 'Δp95' 'Δmean'

prev_p50=0
prev_p95=0
prev_mean=0
for stage in "${stages[@]}"; do
  # Extract this stage's µs values across all runs.
  values_us="$(awk -v stage="$stage" '
    {
      for (i = 2; i <= NF; i++) {
        n = split($i, kv, "=")
        if (n != 2) continue
        if (kv[1] != stage) continue
        if (kv[2] !~ /^[0-9]+$/) continue
        print kv[2]
      }
    }
  ' "$samples_file" | sort -n)"

  count="$(wc -l <<<"$values_us")"
  (( count > 0 )) || continue

  i50=$(awk "BEGIN{ x = int(($count - 1) * 0.50) + 1; if (x < 1) x = 1; if (x > $count) x = $count; print x }")
  i95=$(awk "BEGIN{ x = int(($count - 1) * 0.95) + 1; if (x < 1) x = 1; if (x > $count) x = $count; print x }")

  pmin_us="$(head -n1 <<<"$values_us")"
  pmax_us="$(tail -n1 <<<"$values_us")"
  p50_us="$(sed -n "${i50}p" <<<"$values_us")"
  p95_us="$(sed -n "${i95}p" <<<"$values_us")"
  mean_us="$(awk '{ s += $1 } END { if (NR > 0) printf "%.0f", s/NR; else print "0" }' <<<"$values_us")"

  to_ms() {
    awk "BEGIN{ printf \"%.1f\", $1 / 1000 }"
  }
  pmin_ms="$(to_ms "$pmin_us")"
  pmax_ms="$(to_ms "$pmax_us")"
  p50_ms="$(to_ms "$p50_us")"
  p95_ms="$(to_ms "$p95_us")"
  mean_ms="$(to_ms "$mean_us")"

  d_p50_ms="$(awk "BEGIN{ printf \"%+.1f\", ($p50_us - $prev_p50) / 1000 }")"
  d_p95_ms="$(awk "BEGIN{ printf \"%+.1f\", ($p95_us - $prev_p95) / 1000 }")"
  d_mean_ms="$(awk "BEGIN{ printf \"%+.1f\", ($mean_us - $prev_mean) / 1000 }")"

  printf '%-14s %8s %8s %8s %8s %8s    %8s %8s %8s\n' \
    "$stage" "$pmin_ms" "$p50_ms" "$p95_ms" "$pmax_ms" "$mean_ms" \
    "$d_p50_ms" "$d_p95_ms" "$d_mean_ms"

  prev_p50="$p50_us"
  prev_p95="$p95_us"
  prev_mean="$mean_us"
done

printf '\n(Δ = elapsed since previous stage at that percentile, i.e. that stage'\''s own cost)\n'
