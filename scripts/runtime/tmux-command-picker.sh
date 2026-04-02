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
runtime_mode="$(command_panel_runtime_mode)"

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
  printf 'No command panel items are available for %s.\n' "$runtime_mode"
  printf 'Press any key to close.'
  IFS= read -rsn1 _ || true
  exit 0
fi

accelerators=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i j l m n o p q r s t u v w x y z)
item_ids=()
item_labels=()
item_descriptions=()
item_confirm_messages=()
item_accelerators=()

for list_index in "${!visible_indexes[@]}"; do
  index="${visible_indexes[$list_index]}"
  item_ids+=("${COMMAND_PANEL_IDS[$index]}")
  item_labels+=("${COMMAND_PANEL_LABELS[$index]}")
  item_descriptions+=("${COMMAND_PANEL_DESCRIPTIONS[$index]}")
  item_confirm_messages+=("${COMMAND_PANEL_CONFIRM_MESSAGES[$index]}")
  if (( list_index < ${#accelerators[@]} )); then
    item_accelerators+=("${accelerators[$list_index]}")
  else
    item_accelerators+=("")
  fi
done

item_count="${#item_ids[@]}"
selected_index=0

runtime_log_info command_panel "running command popup picker" "runtime_mode=$runtime_mode" "session_name=$session_name" "item_count=$item_count"

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

render_picker() {
  local rows cols visible_rows start_index end_index accelerator line top_index description

  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  visible_rows=$((rows - 6))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi

  start_index=0
  if (( selected_index >= visible_rows )); then
    start_index=$((selected_index - visible_rows + 1))
  fi
  end_index=$((start_index + visible_rows - 1))
  if (( end_index >= item_count )); then
    end_index=$((item_count - 1))
    start_index=$((end_index - visible_rows + 1))
    if (( start_index < 0 )); then
      start_index=0
    fi
  fi

  printf '\033[H\033[2J'
  printf '%-*.*s\n' "$cols" "$cols" 'Commands'
  printf '%-*.*s\n' "$cols" "$cols" "Runtime mode: $runtime_mode"
  printf '\n'

  for (( top_index = start_index; top_index <= end_index; top_index += 1 )); do
    accelerator="${item_accelerators[$top_index]}"
    if [[ -n "$accelerator" ]]; then
      accelerator="[$accelerator]"
    else
      accelerator="   "
    fi

    line="$accelerator ${item_labels[$top_index]}"
    description="${item_descriptions[$top_index]}"
    if [[ -n "$description" ]]; then
      line="$line - $description"
    fi

    if (( top_index == selected_index )); then
      printf '\033[7m%-*.*s\033[0m\n' "$cols" "$cols" "$line"
    else
      printf '%-*.*s\n' "$cols" "$cols" "$line"
    fi
  done

  printf '\n'
  printf '%-*.*s' "$cols" "$cols" 'Enter run | Up/Down move | 1-9,0,a-z run | Esc close'
}

read_key() {
  local key extra

  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\033' ]]; then
    if IFS= read -rsn2 -t 0.01 extra; then
      key+="$extra"
    fi
  fi
  printf '%s' "$key"
}

move_selection() {
  local delta="${1:-0}"
  selected_index=$((selected_index + delta))
  if (( selected_index < 0 )); then
    selected_index=$((item_count - 1))
  elif (( selected_index >= item_count )); then
    selected_index=0
  fi
}

confirm_selection() {
  local message="${item_confirm_messages[$selected_index]:-}"
  local answer=""

  [[ -n "$message" ]] || return 0

  printf '\033[H\033[2J'
  printf '%s\n\n' "$message"
  printf 'Press y to continue, any other key to cancel.'
  IFS= read -rsn1 answer || return 1
  [[ "${answer,,}" == 'y' ]]
}

run_selection() {
  local item_id="${item_ids[$selected_index]}"

  if ! confirm_selection; then
    return 2
  fi

  runtime_log_info command_panel "command picker running selection" \
    "runtime_mode=$runtime_mode" \
    "session_name=$session_name" \
    "current_window_id=$current_window_id" \
    "selected_index=$selected_index" \
    "item_id=$item_id" \
    "cwd=$cwd"

  bash "$script_dir/tmux-command-run.sh" "$session_name" "$item_id" "$current_window_id" "$cwd"
}

find_accelerator_index() {
  local key="${1:-}"
  local index

  for index in "${!item_accelerators[@]}"; do
    if [[ "${item_accelerators[$index]}" == "$key" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done

  return 1
}

trap cleanup EXIT
printf '\033[?25l'

while true; do
  key=""
  accel_index=""
  status=0

  render_picker
  key="$(read_key)" || exit 0

  case "$key" in
    "")
      if run_selection; then
        status=0
      else
        status="$?"
      fi
      if [[ "$status" == "0" ]]; then
        exit 0
      fi
      if [[ "$status" == "2" ]]; then
        continue
      fi
      exit "$status"
      ;;
    $'\033' | $'\003')
      exit 0
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      ;;
    *)
      accel_index="$(find_accelerator_index "${key,,}" || true)"
      if [[ -n "$accel_index" ]]; then
        selected_index="$accel_index"
        if run_selection; then
          status=0
        else
          status="$?"
        fi
        if [[ "$status" == "0" ]]; then
          exit 0
        fi
        if [[ "$status" == "2" ]]; then
          continue
        fi
        exit "$status"
      fi
      ;;
  esac
done
