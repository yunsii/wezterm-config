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
  runtime_log_error command_panel "command panel failed: missing tmux session" "current_window_id=$current_window_id" "cwd=$cwd"
  tmux display-message 'Command panel failed: missing tmux session'
  exit 1
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  runtime_log_error command_panel "command panel failed: missing tmux session target" "session_name=$session_name" "current_window_id=$current_window_id" "cwd=$cwd"
  tmux display-message "Command panel failed: missing session $session_name"
  exit 1
fi

command_panel_load_items || {
  tmux display-message 'Command panel failed while loading items'
  exit 1
}

mapfile -t visible_indexes < <(command_panel_visible_indexes "$runtime_mode")
if (( ${#visible_indexes[@]} == 0 )); then
  runtime_log_warn command_panel "command panel has no visible items" "runtime_mode=$runtime_mode" "session_name=$session_name"
  tmux display-message "No command panel items are available for $runtime_mode"
  exit 0
fi

runtime_log_info command_panel "opening tmux command panel" "runtime_mode=$runtime_mode" "session_name=$session_name" "item_count=${#visible_indexes[@]}"

picker_command="bash $(command_panel_shell_quote "$script_dir/tmux-command-picker.sh") $(command_panel_shell_quote "$session_name") $(command_panel_shell_quote "$current_window_id") $(command_panel_shell_quote "$cwd")"

if tmux display-popup -x C -y C -w 70% -h 75% -T "Commands" -E "$picker_command"; then
  exit 0
fi

runtime_log_warn command_panel "popup picker unavailable, falling back to display-menu" "runtime_mode=$runtime_mode" "session_name=$session_name"

menu_args=(display-menu -T 'Commands' -x C -y C)
accelerators=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i j l m n o p q r s t u v w x y z)
menu_index=0

for index in "${visible_indexes[@]}"; do
  label="${COMMAND_PANEL_LABELS[$index]}"
  description="${COMMAND_PANEL_DESCRIPTIONS[$index]}"
  confirm_message="${COMMAND_PANEL_CONFIRM_MESSAGES[$index]}"
  item_id="${COMMAND_PANEL_IDS[$index]}"

  if [[ -n "$description" ]]; then
    label="$label - $description"
  fi

  accelerator=''
  if (( menu_index < ${#accelerators[@]} )); then
    accelerator="${accelerators[$menu_index]}"
  fi

  command_string="run-shell -b 'bash $(command_panel_shell_quote "$script_dir/tmux-command-run.sh") $(command_panel_shell_quote "$session_name") $(command_panel_shell_quote "$item_id") $(command_panel_shell_quote "$current_window_id") $(command_panel_shell_quote "$cwd")'"
  if [[ -n "$confirm_message" ]]; then
    command_string="confirm-before -p $(command_panel_shell_quote "$confirm_message") \"$command_string\""
  fi

  menu_args+=("$label" "$accelerator" "$command_string")
  ((menu_index += 1))
done

tmux "${menu_args[@]}"
