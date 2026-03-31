#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="$SCRIPT_DIR/../../tmux.conf"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <workspace> <cwd> [command...]" >&2
  exit 1
fi

workspace="$1"
cwd="$2"
shift 2
cwd="$(tmux_worktree_abs_path "$cwd")"

tmux_version() {
  tmux -V 2>/dev/null | awk '{print $2}' | sed 's/[^0-9.]//g'
}

tmux_version_at_least() {
  local version
  version=$(tmux_version)
  local target_major=$1
  local target_minor=$2
  local major minor
  IFS='.' read -r major minor _ <<< "$version"
  major=${major:-0}
  minor=${minor:-0}
  (( major > target_major )) && return 0
  (( major == target_major && minor >= target_minor )) && return 0
  return 1
}

ensure_tmux_support() {
  if ! tmux_version_at_least 3 3; then
    local installed
    installed=$(tmux_version)
    runtime_log_warn workspace "tmux version lacks allow-passthrough support" "tmux_version=${installed:-unknown}"
    cat <<EOF >&2
Warning: tmux ${installed:-} lacks allow-passthrough support.
Managed tmux workspaces work best with tmux 3.3 or newer.
EOF
  fi
}

ensure_tmux_support

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
  local command_string=""
  local login_shell quoted_shell
  login_shell="$(resolve_login_shell)"
  quoted_shell="$(printf '%q' "$login_shell")"

  if [[ $# -gt 0 ]]; then
    printf -v command_string '%q ' "$@"
    command_string="${command_string% }"
    command_string="$command_string; exec ${quoted_shell} -l"
    printf '%s -lc %q' "$quoted_shell" "$command_string"
    return
  fi

  printf '%s -l' "$quoted_shell"
}

primary_shell_command="$(build_primary_shell_command "$@")"

worktree_root="$cwd"
repo_common_dir=""
main_worktree_root=""
repo_label="$(basename "$cwd")"

if tmux_worktree_in_git_repo "$cwd"; then
  worktree_root="$(tmux_worktree_repo_root "$cwd")"
  repo_common_dir="$(tmux_worktree_common_dir "$cwd")"
  main_worktree_root="$(tmux_worktree_main_root "$repo_common_dir")"
  repo_label="$(tmux_worktree_repo_label "$worktree_root")"
fi

worktree_label="$(tmux_worktree_label_for_root "$worktree_root" "$main_worktree_root")"
session_name="$(tmux_worktree_session_name_for_path "$workspace" "$cwd")"
runtime_log_info workspace "open-project-session invoked" "workspace=$workspace" "cwd=$cwd" "session_name=$session_name" "worktree_root=$worktree_root" "arg_count=$#"

window_id=""
session_created=0
if ! tmux has-session -t "$session_name" 2>/dev/null; then
  runtime_log_info workspace "creating tmux session" "session_name=$session_name" "worktree_root=$worktree_root"
  window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -c "$worktree_root" "$primary_shell_command")"
  session_created=1
else
  runtime_log_info workspace "reusing tmux session" "session_name=$session_name" "worktree_root=$worktree_root"
  window_id="$(tmux_worktree_find_window "$session_name" "$worktree_root" || true)"
fi

if [[ -z "$window_id" ]]; then
  runtime_log_info worktree "creating worktree window" "session_name=$session_name" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  window_id="$(tmux_worktree_create_window "$session_name" "$worktree_root" "$primary_shell_command" "$worktree_label")"
else
  runtime_log_info worktree "reusing worktree window" "session_name=$session_name" "window_id=$window_id" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  tmux rename-window -t "$window_id" "$worktree_label"
  if (( session_created )); then
    tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"
  fi
fi

tmux_worktree_ensure_tmux_config_loaded "$TMUX_CONF" "$(repo_root_path)"
tmux select-window -t "$window_id"

runtime_log_info workspace "attaching tmux session" "session_name=$session_name" "window_id=$window_id"
exec tmux attach-session -t "$session_name"
