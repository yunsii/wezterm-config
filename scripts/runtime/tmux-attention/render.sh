#!/usr/bin/env bash
# Shared frame renderer for the agent-attention popup picker.
#
# Both `tmux-attention-menu.sh` (pre-renders the very first frame to a tmp
# file so the popup body can write it before bash sourcing finishes inside
# the popup pty) and `tmux-attention-picker.sh` (live re-renders on key
# input) use this so the pre-paint and the interactive paint are byte-
# identical and there is no visible swap when the picker takes over.
#
# Caller contract: populate these arrays in the calling shell scope BEFORE
# invoking `attention_picker_emit_frame`:
#   row_status row_body row_age
# All three arrays must have the same length (sentinel goes last).
#
# Performance notes:
# - Frame is built as one bash string; the caller flushes it via a single
#   `printf '%s'` so the entire repaint hits the PTY in one write instead of
#   getting smeared over per-row tty line-buffering.
# - No `$(printf ...)` subshells: width is handled by `\033[K` (clear to
#   end of line) which paints the cell-default bg from the cursor onwards.
#   When `\033[7m` is active for the selected row, the cell-default bg IS
#   the inverted color, so `\033[K` fills the row with the highlight color
#   without us computing any padding.
# - Absolute `\033[<row>;1H` cursor positioning, no embedded newlines, so
#   the terminal does not get a chance to scroll the viewport mid-frame.

attention_picker_emit_frame() {
  local cols="$1"
  local visible_rows="$2"
  local selected_index="$3"
  local item_count="$4"
  # Optional diagnostic timing args (all in ms; 0 disables that segment):
  #   $5 = total elapsed   (T_render - T_keypress)
  #   $6 = bucket L        (T_menu_start - T_keypress)
  #   $7 = bucket M        (T_menu_done  - T_menu_start)
  #   $8 = bucket P        (T_render     - T_menu_done)
  local elapsed_ms="${5:-0}"
  local lua_ms="${6:-0}"
  local menu_ms="${7:-0}"
  local picker_ms="${8:-0}"

  local start_index end_index row top_index status body age frame
  local reset=$'\033[0m'
  local clear_eol=$'\033[K'

  start_index=0
  if (( selected_index >= visible_rows )); then
    start_index=$((selected_index - visible_rows + 1))
  fi
  end_index=$((start_index + visible_rows - 1))
  if (( end_index >= item_count )); then
    end_index=$((item_count - 1))
    start_index=$((end_index - visible_rows + 1))
    (( start_index < 0 )) && start_index=0
  fi

  # Title row.
  frame=$'\033[1;1H'
  frame+=$'\033[1m'"Agent attention — $((selected_index + 1))/$item_count  ·  order matches status bar (⟳ → ⚠ → ✓)"$reset
  frame+="$clear_eol"

  # Item rows start at row 3, leaving row 2 blank as a visual divider.
  row=3
  for (( top_index = start_index; top_index <= end_index; top_index += 1 )); do
    status="${row_status[$top_index]}"
    body="${row_body[$top_index]}"
    age="${row_age[$top_index]}"

    frame+=$'\033['"${row};1H"

    if (( top_index == selected_index )); then
      # Selected row: bold + inverse over plain (uncolored) badge so the
      # highlight reads as one solid bar. \033[K with \033[7m active fills
      # the rest of the line with the inverted bg color.
      frame+=$'\033[1;7m'
      case "$status" in
        running)      frame+='⟳ RUN ' ;;
        waiting)      frame+='⚠ WAIT' ;;
        done)         frame+='✓ DONE' ;;
        __sentinel__) frame+='✗ CLR ' ;;
        *)            frame+='· ----' ;;
      esac
      frame+="  $body"
      [[ -n "$age" ]] && frame+="  ($age)"
      frame+="$reset$clear_eol"
    else
      # Unselected: colored status badge + default body + dim (age).
      case "$status" in
        running)      frame+=$'\033[1;38;5;39m⟳ RUN \033[0m' ;;
        waiting)      frame+=$'\033[1;38;5;208m⚠ WAIT\033[0m' ;;
        done)         frame+=$'\033[38;5;108m✓ DONE\033[0m' ;;
        __sentinel__) frame+=$'\033[1;38;5;160m✗ CLR \033[0m' ;;
        *)            frame+='· ----' ;;
      esac
      frame+="  $body"
      [[ -n "$age" ]] && frame+="  "$'\033[2m'"($age)"$reset
      frame+="$clear_eol"
    fi

    row=$((row + 1))
  done

  # Footer: blank divider row, then dim hint + powered-by badge + (when
  # supplied) end-to-end key→paint latency. The powered-by badge makes
  # which code path is live legible at a glance during the parallel-
  # implementation phase (Go binary vs this bash fallback); same orange
  # family as `⚠ WAIT` (palette 208) signals "fallback active, perf not
  # at full speed". The latency badge is the diagnostic readout the user
  # is actively comparing across runs — drop both once the Go picker is
  # confirmed and this script is removed.
  row=$((row + 1))
  frame+=$'\033['"${row};1H"$'\033[2m'"Enter jump | Up/Down move | Esc / Alt+/ close  ·  powered by "$'\033[22;1;38;5;208m'"bash"$reset
  if [[ "$elapsed_ms" =~ ^[0-9]+$ ]] && (( elapsed_ms > 0 )); then
    frame+=$'\033[2m'"  ·  ${elapsed_ms}ms"
    if (( lua_ms > 0 || menu_ms > 0 || picker_ms > 0 )); then
      frame+=" = ${lua_ms}+${menu_ms}+${picker_ms} (lua+menu+picker)"
    else
      frame+=" key→paint"
    fi
    frame+="$reset"
  fi
  frame+="$clear_eol"

  # Wipe anything still drawn below the footer (e.g. stale content from a
  # taller previous frame inside the same popup session).
  frame+=$'\033[J'

  printf '%s' "$frame"
}
