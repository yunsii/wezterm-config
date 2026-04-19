#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-command-panel-lib.sh"

session_name="${1:-}"
item_id="${2:-}"
current_window_id="${3:-}"
cwd="${4:-$PWD}"
client_tty="${5:-}"
runtime_mode="$(command_panel_runtime_mode)"
start_ms="$(runtime_log_now_ms)"

if [[ -z "$session_name" || -z "$item_id" ]]; then
  runtime_log_error command_panel "command runner failed: missing required arguments" "session_name=$session_name" "item_id=$item_id" "cwd=$cwd"
  printf 'Command runner failed: missing required arguments.\n'
  exit 1
fi

export COMMAND_PANEL_SESSION_NAME="$session_name"
export COMMAND_PANEL_WINDOW_ID="$current_window_id"
export COMMAND_PANEL_CWD="$cwd"
export COMMAND_PANEL_CLIENT_TTY="$client_tty"

command_panel_load_items || {
  tmux display-message 'Command panel failed while loading items'
  exit 1
}

index="$(command_panel_find_index_by_id "$item_id" "$runtime_mode" || true)"
if [[ -z "$index" ]]; then
  runtime_log_error command_panel "command runner could not resolve item" "item_id=$item_id" "runtime_mode=$runtime_mode" "session_name=$session_name"
  tmux display-message "Command panel item is unavailable: $item_id"
  exit 1
fi

label="${COMMAND_PANEL_LABELS[$index]}"
background="${COMMAND_PANEL_BACKGROUNDS[$index]:-0}"
success_message="${COMMAND_PANEL_SUCCESS_MESSAGES[$index]}"
failure_message="${COMMAND_PANEL_FAILURE_MESSAGES[$index]}"
command_panel_command_for_index "$index" command

if [[ -n "$cwd" && -d "$cwd" ]]; then
  cd "$cwd"
fi

runtime_log_info command_panel "running command panel item" \
  "command=$(printf '%s ' "${command[@]}")" \
  "item_id=$item_id" \
  "label=$label" \
  "runtime_mode=$runtime_mode" \
  "session_name=$session_name" \
  "current_window_id=$current_window_id" \
  "client_tty=$client_tty" \
  "cwd=$cwd"

if [[ "$background" == "1" ]]; then
  "${command[@]}" >/dev/null 2>&1 &
  runtime_log_info command_panel "command panel item launched in background" "item_id=$item_id" "runtime_mode=$runtime_mode" "session_name=$session_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  tmux display-message "${success_message:-Started: $label}"
  exit 0
fi

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

if "${command[@]}" >"$output_file" 2>&1; then
  runtime_log_info command_panel "command panel item completed" "item_id=$item_id" "runtime_mode=$runtime_mode" "session_name=$session_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  tmux display-message "${success_message:-Completed: $label}"
  exit 0
else
  status=$?
fi

output="$(tr -d '\r' < "$output_file" | tail -n 20)"
runtime_log_error command_panel "command panel item failed" "item_id=$item_id" "runtime_mode=$runtime_mode" "session_name=$session_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")" "exit_code=$status" "output=$output"
tmux display-message "${failure_message:-Failed: $label}"

if [[ -t 1 ]]; then
  printf '%s\n' "${failure_message:-Failed: $label}"
  if [[ -n "$output" ]]; then
    printf '\n%s\n' "$output"
  fi
  printf '\nPress any key to close.'
  IFS= read -rsn1 _ || true
fi

exit "$status"
