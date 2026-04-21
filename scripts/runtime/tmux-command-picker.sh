#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-command-panel-lib.sh"

session_name="${1:-}"
current_window_id="${2:-}"
cwd="${3:-$PWD}"
client_tty="${4:-}"
runtime_mode="$(command_panel_runtime_mode)"
start_ms="$(runtime_log_now_ms)"
trace_id="$(runtime_log_current_trace_id)"

if [[ -z "$session_name" ]]; then
  runtime_log_error command_panel "command picker failed: missing tmux session" "current_window_id=$current_window_id" "cwd=$cwd"
  printf 'Command picker failed: missing tmux session.\n'
  exit 1
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  runtime_log_error command_panel "command picker failed: missing tmux session target" "session_name=$session_name" "current_window_id=$current_window_id" "cwd=$cwd"
  printf 'Command picker failed: missing session %s.\n' "$session_name"
  exit 1
fi

command_panel_load_items || {
  printf 'Command picker failed while loading items.\n'
  exit 1
}

mapfile -t visible_indexes < <(command_panel_visible_indexes "$runtime_mode")
if (( ${#visible_indexes[@]} == 0 )); then
  printf 'No command palette items are available for %s.\n' "$runtime_mode"
  printf 'Press any key to close.'
  IFS= read -rsn1 _ || true
  exit 0
fi

item_ids=()
item_labels=()
item_descriptions=()
item_confirm_messages=()
item_accelerators=()
item_hotkeys=()

for list_index in "${!visible_indexes[@]}"; do
  index="${visible_indexes[$list_index]}"
  item_ids+=("${COMMAND_PANEL_IDS[$index]}")
  item_labels+=("${COMMAND_PANEL_LABELS[$index]}")
  item_descriptions+=("${COMMAND_PANEL_DESCRIPTIONS[$index]}")
  item_confirm_messages+=("${COMMAND_PANEL_CONFIRM_MESSAGES[$index]}")
  item_accelerators+=("${COMMAND_PANEL_ACCELERATORS[$index],,}")
  item_hotkeys+=("${COMMAND_PANEL_HOTKEYS[$index]}")
done

item_count="${#item_ids[@]}"
query=""
selected_index=0
filtered_indexes=()

runtime_log_info command_panel "running command palette popup" "runtime_mode=$runtime_mode" "session_name=$session_name" "item_count=$item_count"

cleanup() {
  printf '\033[0m\033[?25h'
}

terminal_size() {
  local rows cols

  rows=24
  cols=80
  if IFS=' ' read -r rows cols < <(stty size 2>/dev/null || printf '24 80'); then
    :
  fi
  printf '%s %s\n' "${rows:-24}" "${cols:-80}"
}

update_filtered_indexes() {
  local lowered_query="${query,,}"
  local index
  local haystack=""

  filtered_indexes=()

  for index in "${!item_ids[@]}"; do
    if [[ -z "$lowered_query" ]]; then
      filtered_indexes+=("$index")
      continue
    fi

    haystack="${item_labels[$index]} ${item_descriptions[$index]} ${item_ids[$index]} ${item_accelerators[$index]} ${item_hotkeys[$index]}"
    if [[ "${haystack,,}" == *"$lowered_query"* ]]; then
      filtered_indexes+=("$index")
    fi
  done

  if (( ${#filtered_indexes[@]} == 0 )); then
    selected_index=0
    return
  fi

  if (( selected_index >= ${#filtered_indexes[@]} )); then
    selected_index=$((${#filtered_indexes[@]} - 1))
  fi
}

render_picker() {
  local rows cols visible_rows filtered_count start_index end_index top_index actual_index hotkey
  local main_part hotkey_part main_width available

  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  visible_rows=$((rows - 8))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi

  filtered_count="${#filtered_indexes[@]}"
  start_index=0
  if (( selected_index >= visible_rows )); then
    start_index=$((selected_index - visible_rows + 1))
  fi
  end_index=$((start_index + visible_rows - 1))
  if (( end_index >= filtered_count )); then
    end_index=$((filtered_count - 1))
    start_index=$((end_index - visible_rows + 1))
    if (( start_index < 0 )); then
      start_index=0
    fi
  fi

  printf '\033[H\033[2J'
  printf '%-*.*s\n' "$cols" "$cols" 'Command Palette'
  printf '%-*.*s\n' "$cols" "$cols" "Runtime mode: $runtime_mode"
  printf '%-*.*s\n' "$cols" "$cols" "Search: $query"
  printf '\n'

  if (( filtered_count == 0 )); then
    printf '%-*.*s\n' "$cols" "$cols" 'No matching commands.'
  fi

  for (( top_index = start_index; top_index <= end_index; top_index += 1 )); do
    actual_index="${filtered_indexes[$top_index]}"
    main_part="${item_labels[$actual_index]}"

    hotkey="${item_hotkeys[$actual_index]:-}"
    hotkey_part=""
    if [[ -n "$hotkey" ]]; then
      hotkey_part="[$hotkey]"
    fi

    if [[ -z "$hotkey_part" ]]; then
      if (( top_index == selected_index )); then
        printf '\033[7m%-*.*s\033[0m\n' "$cols" "$cols" "$main_part"
      else
        printf '%-*.*s\n' "$cols" "$cols" "$main_part"
      fi
      continue
    fi

    available=$((cols - ${#hotkey_part} - 1))
    if (( available < 1 )); then
      available=1
    fi
    main_width="$available"

    if (( top_index == selected_index )); then
      printf '\033[7m%-*.*s %s\033[0m\n' "$main_width" "$main_width" "$main_part" "$hotkey_part"
    else
      printf '%-*.*s %s\n' "$main_width" "$main_width" "$main_part" "$hotkey_part"
    fi
  done

  printf '\n'
  printf '%-*.*s' "$cols" "$cols" 'Type to search | Enter run | Up/Down move | Backspace delete | Esc clear/close'
}

current_key=""
read_key() {
  # Writes into $current_key instead of printing so the main loop can read the
  # result without a `$(...)` subshell fork per keypress. Matters most on the
  # bare-Esc path: no subshell teardown before `exit 0`.
  local key extra

  current_key=""
  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\033' ]]; then
    # The terminal writes an entire escape sequence in one syscall, so the
    # trailing bytes of a real sequence are already queued when Esc arrives.
    # Use a near-zero timeout instead of 10 ms so a bare Esc exits the picker
    # without a perceivable wait.
    if IFS= read -rsn2 -t 0.001 extra; then
      key+="$extra"
    fi
  fi
  current_key="$key"
}

move_selection() {
  local delta="${1:-0}"
  local filtered_count="${#filtered_indexes[@]}"

  if (( filtered_count == 0 )); then
    selected_index=0
    return
  fi

  selected_index=$((selected_index + delta))
  if (( selected_index < 0 )); then
    selected_index=$((filtered_count - 1))
  elif (( selected_index >= filtered_count )); then
    selected_index=0
  fi
}

confirm_selection() {
  local actual_index="${filtered_indexes[$selected_index]:-}"
  local message="${item_confirm_messages[$actual_index]:-}"
  local answer=""

  [[ -n "$message" ]] || return 0

  printf '\033[H\033[2J'
  printf '%s\n\n' "$message"
  printf 'Press y to continue, any other key to cancel.'
  IFS= read -rsn1 answer || return 1
  [[ "${answer,,}" == 'y' ]]
}

run_selection() {
  local actual_index="${filtered_indexes[$selected_index]:-}"
  local item_id="${item_ids[$actual_index]:-}"

  if [[ -z "$item_id" ]]; then
    return 2
  fi

  if ! confirm_selection; then
    return 2
  fi

  runtime_log_info command_panel "command palette running selection" \
    "runtime_mode=$runtime_mode" \
    "session_name=$session_name" \
    "current_window_id=$current_window_id" \
    "client_tty=$client_tty" \
    "selected_index=$selected_index" \
    "query=$query" \
    "item_id=$item_id" \
    "cwd=$cwd"

  WEZTERM_RUNTIME_TRACE_ID="$trace_id" bash "$script_dir/tmux-command-run.sh" "$session_name" "$item_id" "$current_window_id" "$cwd" "$client_tty"
}

append_query_char() {
  local key="${1:-}"
  query+="$key"
  update_filtered_indexes
}

trap cleanup EXIT
printf '\033[?25l'
update_filtered_indexes

while true; do
  key=""
  status=0

  render_picker
  read_key || exit 0
  key="$current_key"

  case "$key" in
    "")
      if run_selection; then
        status=0
      else
        status="$?"
      fi
      if [[ "$status" == "0" ]]; then
        runtime_log_info command_panel "command palette popup completed" "runtime_mode=$runtime_mode" "session_name=$session_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
        exit 0
      fi
      if [[ "$status" == "2" ]]; then
        continue
      fi
      exit "$status"
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      ;;
    $'\177' | $'\010')
      if [[ -n "$query" ]]; then
        query="${query%?}"
        update_filtered_indexes
      fi
      ;;
    $'\025')
      query=""
      update_filtered_indexes
      ;;
    $'\033' | $'\003')
      if [[ -n "$query" ]]; then
        query=""
        update_filtered_indexes
      else
        exit 0
      fi
      ;;
    *)
      if [[ "$key" =~ [[:print:]] ]]; then
        append_query_char "$key"
      fi
      ;;
  esac
done
