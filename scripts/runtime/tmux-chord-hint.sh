#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"

action="${1:-}"
message="${2:-}"
session_name="${3:-}"
start_ms="$(runtime_log_now_ms)"

usage() {
  cat <<'EOF' >&2
usage:
  tmux-chord-hint.sh start <message> [session]
  tmux-chord-hint.sh clear [session]
EOF
}

session_option() {
  local option_name="$1"
  tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
}

set_session_option() {
  local option_name="$1"
  local value="$2"
  tmux set-option -q -t "$session_name" "$option_name" "$value" 2>/dev/null || true
}

unset_session_option() {
  local option_name="$1"
  tmux set-option -qu -t "$session_name" "$option_name" 2>/dev/null || true
}

resolve_session_name() {
  if [[ -n "$session_name" ]]; then
    return 0
  fi

  session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  [[ -n "$session_name" ]]
}

refresh_clients() {
  local client
  while IFS= read -r client; do
    [[ -n "$client" ]] || continue
    tmux refresh-client -S -t "$client" 2>/dev/null || true
  done < <(tmux list-clients -t "$session_name" -F '#{client_name}' 2>/dev/null || true)
}

start_hint() {
  local current_status=""
  local line_index="2"

  current_status="$(session_option 'status')"
  if [[ -z "$current_status" ]]; then
    current_status="3"
  fi

  set_session_option '@wezterm_chord_prev_status' "$current_status"

  if [[ "$current_status" == "off" || "$current_status" == "0" ]]; then
    line_index="0"
    set_session_option 'status' '1'
  fi

  set_session_option '@wezterm_chord_hint_line' "$line_index"
  set_session_option "@tmux_status_override_line_${line_index}" "$message"
  refresh_clients

  runtime_log_info command_panel "activated tmux chord hint" \
    "session_name=$session_name" \
    "line_index=$line_index" \
    "status_before=$current_status" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
}

clear_hint() {
  local line_index=""
  local previous_status=""

  line_index="$(session_option '@wezterm_chord_hint_line')"
  previous_status="$(session_option '@wezterm_chord_prev_status')"

  if [[ -n "$line_index" ]]; then
    unset_session_option "@tmux_status_override_line_${line_index}"
  fi

  if [[ -n "$previous_status" ]]; then
    set_session_option 'status' "$previous_status"
  fi

  unset_session_option '@wezterm_chord_hint_line'
  unset_session_option '@wezterm_chord_prev_status'
  refresh_clients

  runtime_log_info command_panel "cleared tmux chord hint" \
    "session_name=$session_name" \
    "line_index=${line_index:-unknown}" \
    "restored_status=${previous_status:-unknown}" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
}

resolve_session_name || {
  usage
  exit 1
}

case "$action" in
  start)
    [[ -n "$message" ]] || {
      usage
      exit 1
    }
    start_hint
    ;;
  clear)
    clear_hint
    ;;
  *)
    usage
    exit 1
    ;;
esac
