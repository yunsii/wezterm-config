#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="$SCRIPT_DIR/../../tmux.conf"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-version-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

start_ms="$(runtime_log_now_ms)"
cwd="${1:-}"
if [[ -z "$cwd" || "$cwd" =~ ^/mnt/[a-z]/Users/[^/]+$ ]]; then
  cwd="${HOME:-$PWD}"
fi
cwd="$(tmux_worktree_abs_path "$cwd")"

resolve_login_shell() {
  if [[ -n "${WEZTERM_MANAGED_SHELL:-}" && -x "${WEZTERM_MANAGED_SHELL:-}" ]]; then
    printf '%s\n' "$WEZTERM_MANAGED_SHELL"
    return 0
  fi

  if [[ -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
    printf '%s\n' "$SHELL"
    return 0
  fi

  local candidate
  for candidate in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '/bin/sh\n'
}

build_primary_shell_command() {
  local login_shell quoted_shell
  login_shell="$(resolve_login_shell)"
  quoted_shell="$(printf '%q' "$login_shell")"
  printf '%s -il' "$quoted_shell"
}

repo_root_path() {
  local repo_root=""
  local common_dir=""
  local main_root=""

  repo_root="$(
    cd "$SCRIPT_DIR/../.."
    pwd -P
  )"

  if tmux_worktree_in_git_repo "$repo_root"; then
    common_dir="$(tmux_worktree_common_dir "$repo_root" || true)"
    if [[ -n "$common_dir" ]]; then
      main_root="$(tmux_worktree_main_root "$common_dir" || true)"
      if [[ -n "$main_root" && -d "$main_root" ]]; then
        printf '%s\n' "$main_root"
        return 0
      fi
    fi
  fi

  printf '%s\n' "$repo_root"
}

tmux_version_ensure_supported

primary_shell_command="$(build_primary_shell_command)"
session_name="wezterm_default_shell_$(date +%Y%m%dT%H%M%S)-$$"
window_label="$(basename "$cwd")"
if [[ -z "$window_label" || "$window_label" == "/" ]]; then
  window_label="shell"
fi

runtime_log_info workspace "opening default WSL tmux session" \
  "cwd=$cwd" \
  "session_name=$session_name" \
  "window_label=$window_label" \
  "primary_shell_command=$primary_shell_command"

session_env_args=()
if [[ -n "${WEZTERM_PANE:-}" ]]; then
  session_env_args+=("-e" "WEZTERM_PANE=$WEZTERM_PANE")
fi
window_id="$(tmux new-session -d -P -F '#{window_id}' \
  "${session_env_args[@]}" \
  -s "$session_name" \
  -n "$window_label" \
  -c "$cwd" \
  "$primary_shell_command")"

tmux source-file "$TMUX_CONF"
# Enable destroy-unattached only after a client really attaches. Setting it on
# a freshly detached session can reap the session before attach-session runs.
tmux set-hook -t "$session_name" client-attached "set-option -t '$session_name' destroy-unattached on"
tmux_worktree_set_session_metadata "$session_name" default default
tmux_worktree_set_window_metadata "$window_id" shell "$cwd" "$window_label" "$primary_shell_command" single

exec tmux attach-session -t "$session_name"
