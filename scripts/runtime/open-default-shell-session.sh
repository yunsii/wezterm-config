#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="$SCRIPT_DIR/../../tmux.conf"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

start_ms="$(runtime_log_now_ms)"
cwd="${1:-$PWD}"
cwd="$(tmux_worktree_abs_path "$cwd")"

tmux_version() {
  tmux -V 2>/dev/null | awk '{print $2}' | sed 's/[^0-9.]//g'
}

tmux_version_at_least() {
  local version
  version="$(tmux_version)"
  local target_major="$1"
  local target_minor="$2"
  local major minor
  IFS='.' read -r major minor _ <<< "$version"
  major="${major:-0}"
  minor="${minor:-0}"
  (( major > target_major )) && return 0
  (( major == target_major && minor >= target_minor )) && return 0
  return 1
}

ensure_tmux_support() {
  if ! tmux_version_at_least 3 3; then
    local installed
    installed="$(tmux_version)"
    runtime_log_warn workspace "default WSL tmux session uses tmux older than 3.3" "tmux_version=${installed:-unknown}"
  fi
}

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

ensure_tmux_support

primary_shell_command="$(build_primary_shell_command)"
session_name="wezterm_default_shell_$(date +%Y%m%dT%H%M%S)-$$"
window_label="$(basename "$cwd")"
if [[ -z "$window_label" || "$window_label" == "/" ]]; then
  window_label="shell"
fi

runtime_log_info workspace "opening default WSL tmux session" \
  "cwd=$cwd" \
  "session_name=$session_name" \
  "window_label=$window_label"

window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -c "$cwd" "$primary_shell_command")"
tmux rename-window -t "$window_id" "$window_label"
tmux_worktree_ensure_tmux_config_loaded "$TMUX_CONF" "$(repo_root_path)"
tmux set-option -t "$session_name" status off
tmux set-option -t "$session_name" destroy-unattached on >/dev/null 2>&1 || true
tmux select-window -t "$window_id"

runtime_log_info workspace "default WSL tmux session prepared" \
  "cwd=$cwd" \
  "session_name=$session_name" \
  "window_id=$window_id" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")"

exec tmux attach-session -t "$session_name"
