#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-reset/common.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-reset/session-resolution.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-reset/window.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-reset/session.sh"

subcommand="${1:-}"
if [[ -n "$subcommand" ]]; then
  shift
fi

default_session_prefix='wezterm_default_shell_'

case "$subcommand" in
  session-name)
    resolve_session_name "$@"
    ;;
  current-session)
    resolve_current_workspace_session "$@"
    ;;
  refresh-current-window)
    refresh_current_window "$@"
    ;;
  refresh-current-session)
    refresh_current_session "$@"
    ;;
  refresh-current-workspace)
    refresh_current_workspace "$@"
    ;;
  refresh-all)
    refresh_all_sessions "$@"
    ;;
  reset-managed-window)
    reset_managed_window "$@"
    ;;
  reset-current-window)
    reset_current_window "$@"
    ;;
  reset-default)
    reset_default_session "$@"
    ;;
  resolve-default-session)
    resolve_default_session "$@"
    ;;
  list-default-sessions)
    list_default_sessions "$@"
    ;;
  list-sessions)
    list_sessions "$@"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
