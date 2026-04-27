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
#   3. Re-render only when state changes (input loop sets a needs_render
#      flag on Up/Down/filter edits/Tab cycles).
#   4. `read_key` uses `read -t 0` to disambiguate bare Esc from multi-byte
#      escape sequences without paying a fixed timeout — Esc closes the
#      popup instantly because nothing is buffered behind it. The forwarded
#      `\x1b/` from a second Alt+/ press counts as exit, so the same chord
#      that opens the popup also closes it.
#   5. Selections dispatch via `tmux run-shell -b` so the popup tears down
#      before `attention-jump.sh` starts the WezTerm activate-pane round-
#      trip — the user perceives the jump as instant rather than "popup
#      hangs for the duration of the jump".
#
# Type-to-filter input (mirrors the command palette UX):
#   - Printable ASCII edits the substring filter (no `/` to enter a mode);
#     a `Search:` row at line 2 is always visible and shows the live
#     query / dim placeholder.
#   - Backspace edits filter; Ctrl+U clears it in one keystroke.
#   - Up/Down navigate the filtered list; Enter dispatches the selection.
#   - Tab cycles the orthogonal status filter (all/waiting/running/done).
#   - Esc clears filter when non-empty, otherwise closes (matches command
#     palette). Ctrl+C and forwarded `\x1b/` (second Alt+/) close from
#     any state, preserving the open-shortcut-as-toggle behaviour.
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
# (driven by Up/Down/filter edits) repaint via the shared renderer over
# the same screen with absolute positioning, so this priming write and
# the live frame are byte-identical and there is no visible swap.
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

# Backing arrays — loaded once from the prefetch TSV, never mutated.
# The visible row arrays (`row_*`, consumed by render.sh) are recomputed
# from these whenever filter state changes.
all_status=()
all_body=()
all_age=()
all_ids=()
all_last_status=()
while IFS=$'\t' read -r s b a id ls; do
  [[ -n "$s" ]] || continue
  all_status+=("$s")
  all_body+=("$b")
  all_age+=("$a")
  all_ids+=("$id")
  all_last_status+=("${ls:-}")
done < "$prefetch_file"

backing_total="${#all_ids[@]}"
if (( backing_total == 0 )); then
  printf '\nNo pending agent attention; press any key to close.'
  IFS= read -rsn1 _ || true
  exit 0
fi

# Filter state. Type-to-filter is always-on (mirrors the command palette);
# there is no separate "filter mode" to enter — every printable keystroke
# edits the substring filter directly.
filter_text=""
status_filter="all"  # all | running | waiting | done

# Visible (filtered) arrays — what render.sh iterates.
row_status=()
row_body=()
row_age=()
row_ids=()
row_last_status=()
selected_index=0

apply_filter() {
  row_status=()
  row_body=()
  row_age=()
  row_ids=()
  row_last_status=()
  local i s b lower_b lower_f
  local filter_active=0
  [[ -n "$filter_text" || "$status_filter" != "all" ]] && filter_active=1
  if [[ -n "$filter_text" ]]; then
    lower_f="${filter_text,,}"
  fi
  for (( i = 0; i < backing_total; i += 1 )); do
    s="${all_status[$i]}"
    b="${all_body[$i]}"
    if [[ "$s" == "__sentinel__" ]]; then
      # Sentinel (clear-all) is hidden whenever any filter is active —
      # filtering text against "clear all · N entries" is meaningless,
      # and a status filter clearly excludes a meta row.
      (( filter_active )) && continue
      row_status+=("$s")
      row_body+=("$b")
      row_age+=("${all_age[$i]}")
      row_ids+=("${all_ids[$i]}")
      row_last_status+=("${all_last_status[$i]}")
      continue
    fi
    if [[ "$status_filter" != "all" && "$status_filter" != "$s" ]]; then
      continue
    fi
    if [[ -n "$filter_text" ]]; then
      lower_b="${b,,}"
      [[ "$lower_b" == *"$lower_f"* ]] || continue
    fi
    row_status+=("$s")
    row_body+=("$b")
    row_age+=("${all_age[$i]}")
    row_ids+=("${all_ids[$i]}")
    row_last_status+=("${all_last_status[$i]}")
  done
  # Clamp selection inside the filtered range.
  local visible="${#row_ids[@]}"
  if (( visible == 0 )); then
    selected_index=0
  elif (( selected_index >= visible )); then
    selected_index=$((visible - 1))
  elif (( selected_index < 0 )); then
    selected_index=0
  fi
}

apply_filter

runtime_log_info attention "popup picker invoked" \
  "trace=$trace_id" "item_count=$backing_total"

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
  local rows cols visible_rows elapsed_ms lua_ms menu_ms picker_ms now total
  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  # 5 non-row lines: title, search input, blank divider, blank-before-
  # footer, footer.
  visible_rows=$((rows - 5))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi
  elapsed_ms=0
  lua_ms=0
  menu_ms=0
  picker_ms=0
  now=$(( ${EPOCHREALTIME//./} / 1000 ))
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
  total="${#row_ids[@]}"
  attention_picker_emit_frame "$cols" "$visible_rows" "$selected_index" "$total" "$elapsed_ms" "$lua_ms" "$menu_ms" "$picker_ms" "$filter_text" "$status_filter"
}

# Once-per-popup perf emit, dispatched AFTER the first render call from
# the script's top-level (never from inside render_picker, per
# docs/logging-conventions.md "Render-path discipline"). Reads the same
# timing math render_picker just computed by re-reading the timestamps.
emit_first_paint_perf() {
  local now elapsed_ms=0 lua_ms=0 menu_ms=0 picker_ms=0
  now=$(( ${EPOCHREALTIME//./} / 1000 ))
  (( keypress_ts > 0 )) && { elapsed_ms=$((now - keypress_ts)); (( elapsed_ms < 0 )) && elapsed_ms=0; }
  (( menu_start_ts > 0 && keypress_ts > 0 )) && { lua_ms=$((menu_start_ts - keypress_ts)); (( lua_ms < 0 )) && lua_ms=0; }
  (( menu_done_ts > 0 && menu_start_ts > 0 )) && { menu_ms=$((menu_done_ts - menu_start_ts)); (( menu_ms < 0 )) && menu_ms=0; }
  (( menu_done_ts > 0 )) && { picker_ms=$((now - menu_done_ts)); (( picker_ms < 0 )) && picker_ms=0; }
  runtime_log_info attention.perf "popup paint timing" \
    "trace=$trace_id" \
    "paint_kind=first" \
    "picker_kind=bash" \
    "total_ms=$elapsed_ms" \
    "lua_ms=$lua_ms" \
    "menu_ms=$menu_ms" \
    "picker_ms=$picker_ms" \
    "item_count=${#row_ids[@]}" \
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
  local total="${#row_ids[@]}"
  (( total == 0 )) && return
  selected_index=$((selected_index + delta))
  if (( selected_index < 0 )); then
    selected_index=$((total - 1))
  elif (( selected_index >= total )); then
    selected_index=0
  fi
}

cycle_status_filter() {
  case "$status_filter" in
    all)     status_filter="waiting" ;;
    waiting) status_filter="done" ;;
    done)    status_filter="running" ;;
    running) status_filter="all" ;;
    *)       status_filter="all" ;;
  esac
  selected_index=0
  apply_filter
}

dispatch_selection() {
  local total="${#row_ids[@]}"
  (( total == 0 )) && return 1
  local id="${row_ids[$selected_index]}"
  local cmd
  if [[ "$id" == "__clear_all__" ]]; then
    runtime_log_info attention "alt-slash clear-all" "trace=$trace_id"
    cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --clear-all"
  elif [[ "$id" == recent::* ]]; then
    # Encoded by tmux-attention-menu.sh as "recent::<sid>::<archived_ts>".
    # Split into the two pieces so the jump script can disambiguate
    # multiple recent rows that share a session_id.
    local rest sid archived
    rest="${id#recent::}"
    sid="${rest%%::*}"
    archived="${rest#*::}"
    [[ "$archived" == "$rest" ]] && archived=""
    runtime_log_info attention "alt-slash recent jump" "trace=$trace_id" "session_id=$sid" "archived_ts=$archived"
    if [[ -n "$archived" ]]; then
      cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --recent --session $(printf %q "$sid") --archived-ts $(printf %q "$archived")"
    else
      cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --recent --session $(printf %q "$sid")"
    fi
  else
    runtime_log_info attention "alt-slash jump" "trace=$trace_id" "session_id=$id"
    cmd="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/attention-jump.sh") --session $(printf %q "$id")"
  fi
  # `tmux run-shell -b` returns immediately, so the popup tears down before
  # attention-jump.sh starts the wezterm-cli activate-pane round-trip.
  tmux run-shell -b "$cmd" 2>/dev/null || true
  return 0
}

# menu.sh already painted the first frame so the user sees content
# instantly, but it could not embed the latency badge (popup hadn't
# spawned yet — any number would have been a fictional half-measurement).
# Force one render here so the diagnostic key→paint readout updates with
# the real end-to-end time once libs have loaded. Subsequent iterations
# only repaint when state changes — see the input loop below.
render_picker
emit_first_paint_perf

while true; do
  needs_render=0
  key="$(read_key)" || exit 0

  case "$key" in
    "")
      # Enter — dispatch the currently-selected row.
      if dispatch_selection; then
        runtime_log_info attention "popup picker completed" \
          "trace=$trace_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
        exit 0
      fi
      ;;
    $'\033/' | $'\003')
      # `\x1b/` (forwarded second Alt+/) and Ctrl+C are unconditional
      # close — preserves the toggle behaviour and gives the user one
      # always-on escape hatch even when the filter is non-empty.
      runtime_log_info attention "popup picker cancelled" \
        "trace=$trace_id" "key=$(printf '%q' "$key")" \
        "duration_ms=$(runtime_log_duration_ms "$start_ms")"
      exit 0
      ;;
    $'\033')
      # Bare Esc: clear filter first if non-empty, then close on the
      # next press. Mirrors the command palette's Esc semantics so the
      # user can back out of a search without losing the popup.
      if [[ -n "$filter_text" ]]; then
        filter_text=""
        selected_index=0
        apply_filter
        needs_render=1
      else
        runtime_log_info attention "popup picker cancelled" \
          "trace=$trace_id" "key=esc" \
          "duration_ms=$(runtime_log_duration_ms "$start_ms")"
        exit 0
      fi
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      needs_render=1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      needs_render=1
      ;;
    $'\t')
      cycle_status_filter
      needs_render=1
      ;;
    $'\b' | $'\x7f')
      if [[ -n "$filter_text" ]]; then
        filter_text="${filter_text:0:${#filter_text}-1}"
        selected_index=0
        apply_filter
        needs_render=1
      fi
      ;;
    $'\025')
      # Ctrl+U — clear filter in one keystroke (matches the command
      # palette's bulk-erase shortcut).
      if [[ -n "$filter_text" ]]; then
        filter_text=""
        selected_index=0
        apply_filter
        needs_render=1
      fi
      ;;
    *)
      # Append printable ASCII (single-byte, 0x20–0x7E). Multi-byte
      # sequences and stray escape codes land here too but get filtered
      # out by the range check, so they cannot pollute the filter string.
      if [[ "${#key}" == 1 ]]; then
        local_byte=$(printf '%d' "'$key" 2>/dev/null || printf '0')
        if (( local_byte >= 32 && local_byte <= 126 )); then
          filter_text+="$key"
          selected_index=0
          apply_filter
          needs_render=1
        fi
      fi
      ;;
  esac

  if (( needs_render )); then
    render_picker
  fi
done
