#!/usr/bin/env bash
# Popup-side picker for the agent-attention overlay (Alt+/).
#
# Performance shape mirrors tmux-worktree-picker:
#   1. Parse args BEFORE sourcing anything so the first paint can run with
#      bash builtins only. On WSL2 with cold disk caches, sourcing the
#      runtime-log + attention-state libs can spike to 30–80ms; doing the
#      prime first bounds time-to-first-paint at "bash startup + one
#      syscall".
#   2. The first action is `printf '\033[?25l'; printf '%s' "$(<frame)"`
#      using bash's `$(<file)` slurp instead of `cat`, removing the only
#      fork+exec on the hot path.
#   3. Re-render only on Up/Down (input loop sets a needs_render flag).
#   4. `read_key` uses `read -t 0` to disambiguate bare Esc from multi-byte
#      escape sequences without paying a fixed timeout — Esc closes the
#      popup instantly because nothing is buffered behind it. The forwarded
#      `\x1b/` from a second Alt+/ press counts as exit, so the same chord
#      that opens the popup also closes it.
#   5. Selections dispatch via `tmux run-shell -b` so the popup tears down
#      before `attention-jump.sh` starts the WezTerm activate-pane round-
#      trip — the user perceives the jump as instant rather than "popup
#      hangs for the duration of the jump".
set -u

prefetch_file="${1:-}"
prefetch_frame_file="${2:-}"
keypress_ts="${3:-0}"
menu_start_ts="${4:-0}"
menu_done_ts="${5:-0}"
[[ "$keypress_ts" =~ ^[0-9]+$ ]] || keypress_ts=0
[[ "$menu_start_ts" =~ ^[0-9]+$ ]] || menu_start_ts=0
[[ "$menu_done_ts" =~ ^[0-9]+$ ]] || menu_done_ts=0

# First-paint fast path: emit the frame menu.sh pre-rendered before doing
# any work. Use bash's `$(<file)` slurp instead of `cat` to skip the
# fork+exec of /bin/cat (5–30ms on WSL2 cold cache). Subsequent re-renders
# (driven by Up/Down) repaint via the shared renderer over the same screen
# with absolute positioning, so this priming write and the live frame are
# byte-identical and there is no visible swap.
printf '\033[?25l'
if [[ -n "$prefetch_frame_file" && -r "$prefetch_frame_file" ]]; then
  printf '%s' "$(<"$prefetch_frame_file")"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/attention-state-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-attention/render.sh"

start_ms="$(runtime_log_now_ms)"
trace_id="$(runtime_log_current_trace_id)"

if [[ -z "$prefetch_file" || ! -r "$prefetch_file" ]]; then
  runtime_log_error attention "popup picker missing prefetch file" \
    "trace=$trace_id" "prefetch_file=$prefetch_file"
  printf '\nMissing prefetch data; press any key to close.'
  IFS= read -rsn1 _ || true
  exit 1
fi

row_status=()
row_body=()
row_age=()
row_ids=()
while IFS=$'\t' read -r s b a id; do
  [[ -n "$s" ]] || continue
  row_status+=("$s")
  row_body+=("$b")
  row_age+=("$a")
  row_ids+=("$id")
done < "$prefetch_file"

total="${#row_ids[@]}"
if (( total == 0 )); then
  printf '\nNo pending agent attention; press any key to close.'
  IFS= read -rsn1 _ || true
  exit 0
fi

selected_index=0

runtime_log_info attention "popup picker invoked" \
  "trace=$trace_id" "item_count=$total"

cleanup() {
  printf '\033[0m\033[?25h'
}
trap cleanup EXIT

terminal_size() {
  local rows cols
  rows=24
  cols=80
  IFS=' ' read -r rows cols < <(stty size 2>/dev/null || printf '24 80')
  printf '%s %s\n' "${rows:-24}" "${cols:-80}"
}

render_picker() {
  local paint_kind="${1:-first}"
  local rows cols visible_rows elapsed_ms lua_ms menu_ms picker_ms now
  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  visible_rows=$((rows - 4))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi
  elapsed_ms=0
  lua_ms=0
  menu_ms=0
  picker_ms=0
  now="$(date +%s%3N)"
  if (( keypress_ts > 0 )); then
    elapsed_ms=$((now - keypress_ts))
    (( elapsed_ms < 0 )) && elapsed_ms=0
  fi
  if (( menu_start_ts > 0 && keypress_ts > 0 )); then
    lua_ms=$((menu_start_ts - keypress_ts))
    (( lua_ms < 0 )) && lua_ms=0
  fi
  if (( menu_done_ts > 0 && menu_start_ts > 0 )); then
    menu_ms=$((menu_done_ts - menu_start_ts))
    (( menu_ms < 0 )) && menu_ms=0
  fi
  if (( menu_done_ts > 0 )); then
    picker_ms=$((now - menu_done_ts))
    (( picker_ms < 0 )) && picker_ms=0
  fi
  attention_picker_emit_frame "$cols" "$visible_rows" "$selected_index" "$total" "$elapsed_ms" "$lua_ms" "$menu_ms" "$picker_ms"
  # Perf event — own category so users can opt-in via
  # WEZTERM_RUNTIME_LOG_CATEGORIES=attention.perf without pulling in the
  # noisier `attention` lifecycle/render logs. Bench harness reads
  # `paint_kind="first"` rows for cold-path stats.
  runtime_log_info attention.perf "popup paint timing" \
    "trace=$trace_id" \
    "paint_kind=$paint_kind" \
    "picker_kind=bash" \
    "total_ms=$elapsed_ms" \
    "lua_ms=$lua_ms" \
    "menu_ms=$menu_ms" \
    "picker_ms=$picker_ms" \
    "item_count=$total" \
    "selected_index=$selected_index"
}

read_key() {
  local key extra
  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\033' ]]; then
    # Disambiguate bare Esc from a multi-byte escape sequence without
    # paying a fixed timeout: `read -t 0` returns success only if more
    # bytes are already buffered. Sequences we care about (`\033[A/B`,
    # `\033OA/B`, the forwarded `\033/`) arrive in one PTY write so the
    # follow-up is buffered the moment we get the leading byte. Bare Esc
    # has nothing behind it, so we return immediately — no timeout wait
    # before the popup tears down on close.
    if read -t 0 2>/dev/null; then
      IFS= read -rsn2 -t 0.001 extra || true
      key+="$extra"
    fi
  fi
  printf '%s' "$key"
}

move_selection() {
  local delta="${1:-0}"
  selected_index=$((selected_index + delta))
  if (( selected_index < 0 )); then
    selected_index=$((total - 1))
  elif (( selected_index >= total )); then
    selected_index=0
  fi
}

dispatch_selection() {
  local id="${row_ids[$selected_index]}"
  local cmd
  if [[ "$id" == "__clear_all__" ]]; then
    runtime_log_info attention "alt-slash clear-all" "trace=$trace_id"
    cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --clear-all"
  else
    runtime_log_info attention "alt-slash jump" "trace=$trace_id" "session_id=$id"
    cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --session $(printf %q "$id")"
  fi
  # `tmux run-shell -b` returns immediately, so the popup tears down before
  # attention-jump.sh starts the wezterm-cli activate-pane round-trip.
  tmux run-shell -b "$cmd" 2>/dev/null || true
}

# menu.sh already painted the first frame so the user sees content
# instantly, but it could not embed the latency badge (popup hadn't
# spawned yet — any number would have been a fictional half-measurement).
# Force one render here so the diagnostic key→paint readout updates with
# the real end-to-end time once libs have loaded. Subsequent iterations
# only repaint on Up/Down — see the input loop below.
render_picker first

while true; do
  needs_render=0
  key="$(read_key)" || exit 0

  case "$key" in
    "")
      dispatch_selection
      runtime_log_info attention "popup picker completed" \
        "trace=$trace_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
      exit 0
      ;;
    $'\033' | $'\003' | $'\033/')
      runtime_log_info attention "popup picker cancelled" \
        "trace=$trace_id" "key=$(printf '%q' "$key")" \
        "duration_ms=$(runtime_log_duration_ms "$start_ms")"
      exit 0
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      needs_render=1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      needs_render=1
      ;;
  esac

  if (( needs_render )); then
    render_picker repaint
  fi
done
