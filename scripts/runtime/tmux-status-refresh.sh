#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

client_name=""
session_name=""
window_id=""
pane_id=""
cwd=""
print_line=""
force_refresh=0
refresh_client=0

usage() {
  cat <<'EOF' >&2
Usage: tmux-status-refresh.sh [options]

Options:
  --client NAME         tmux client name
  --session NAME        tmux session name
  --window ID           tmux window id
  --pane ID             tmux pane id
  --cwd PATH            pane working directory
  --print-line INDEX    print cached status line 0, 1, or 2
  --force               bypass staleness checks and recompute now
  --refresh-client      refresh matching tmux client status line after recompute
EOF
}

session_option() {
  local option_name="$1"

  if [[ -n "$session_name" ]]; then
    tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
  else
    tmux show -gv "$option_name" 2>/dev/null || true
  fi
}

set_session_option() {
  local option_name="$1"
  local value="$2"

  if [[ -n "$session_name" ]]; then
    tmux set-option -q -t "$session_name" "$option_name" "$value" 2>/dev/null || true
  else
    tmux set-option -gq "$option_name" "$value" 2>/dev/null || true
  fi
}

refresh_matching_clients() {
  local client

  if [[ -n "$client_name" ]]; then
    tmux refresh-client -S -t "$client_name" 2>/dev/null || true
    return
  fi

  if [[ -z "$session_name" ]]; then
    return
  fi

  while IFS= read -r client; do
    [[ -n "$client" ]] || continue
    tmux refresh-client -S -t "$client" 2>/dev/null || true
  done < <(tmux list-clients -t "$session_name" -F '#{client_name}' 2>/dev/null || true)
}

resolve_context_from_tmux() {
  local metadata=""
  local resolved_session=""
  local resolved_window=""
  local resolved_cwd=""

  if [[ -n "$client_name" ]]; then
    metadata="$(tmux display-message -p -c "$client_name" '#{session_name}	#{window_id}	#{pane_current_path}' 2>/dev/null || true)"
  elif [[ -n "$pane_id" ]]; then
    metadata="$(tmux display-message -p -t "$pane_id" '#{session_name}	#{window_id}	#{pane_current_path}' 2>/dev/null || true)"
  elif [[ -n "$window_id" ]]; then
    metadata="$(tmux display-message -p -t "$window_id" '#{session_name}	#{window_id}	#{pane_current_path}' 2>/dev/null || true)"
  elif [[ -n "$session_name" ]]; then
    metadata="$(tmux display-message -p -t "$session_name" '#{session_name}	#{window_id}	#{pane_current_path}' 2>/dev/null || true)"
  else
    metadata="$(tmux display-message -p '#{session_name}	#{window_id}	#{pane_current_path}' 2>/dev/null || true)"
  fi

  if [[ -z "$metadata" ]]; then
    return
  fi

  IFS=$'\t' read -r resolved_session resolved_window resolved_cwd <<< "$metadata"

  if [[ -z "$session_name" ]]; then
    session_name="$resolved_session"
  fi

  if [[ -z "$window_id" ]]; then
    window_id="$resolved_window"
  fi

  if [[ -z "$cwd" ]]; then
    cwd="$resolved_cwd"
  fi
}

should_refresh() {
  local last_refresh=""
  local poll_interval=""
  local now=""

  if (( force_refresh )); then
    return 0
  fi

  last_refresh="$(session_option '@tmux_status_last_refresh')"
  if [[ -z "$last_refresh" ]]; then
    return 0
  fi

  poll_interval="$(tmux_option_or_env TMUX_STATUS_POLL_INTERVAL @tmux_status_poll_interval '30')"
  if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
    poll_interval="30"
  fi

  now="$(date +%s)"
  if ! [[ "$last_refresh" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  (( now - last_refresh >= poll_interval ))
}

while (( $# > 0 )); do
  case "$1" in
    --client)
      client_name="${2:-}"
      shift 2
      ;;
    --session)
      session_name="${2:-}"
      shift 2
      ;;
    --window)
      window_id="${2:-}"
      shift 2
      ;;
    --pane)
      pane_id="${2:-}"
      shift 2
      ;;
    --cwd)
      cwd="${2:-}"
      shift 2
      ;;
    --print-line)
      print_line="${2:-}"
      shift 2
      ;;
    --force)
      force_refresh=1
      shift
      ;;
    --refresh-client)
      refresh_client=1
      shift
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

resolve_context_from_tmux

if [[ -n "$session_name" ]] && [[ -n "$cwd" ]] && should_refresh; then
  bash "$script_dir/tmux-status-layout.sh" "$session_name" "$window_id" "$cwd" >/dev/null
  set_session_option '@tmux_status_last_refresh' "$(date +%s)"
fi

if (( refresh_client )); then
  refresh_matching_clients
fi

if [[ -n "$print_line" ]]; then
  session_option "@tmux_status_line_${print_line}"
fi
