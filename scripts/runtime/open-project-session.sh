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

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <workspace> <cwd> [command...]" >&2
  exit 1
fi

start_ms="$(runtime_log_now_ms)"

workspace="$1"
cwd="$2"
shift 2
cwd="$(tmux_worktree_abs_path "$cwd")"
window_id=""
session_created=0
window_created=0
startup_step="init"

cleanup_failed_startup() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi

  runtime_log_error workspace "open-project-session failed" \
    "workspace=$workspace" \
    "cwd=$cwd" \
    "session_name=${session_name:-}" \
    "window_id=${window_id:-}" \
    "session_created=$session_created" \
    "window_created=$window_created" \
    "step=$startup_step" \
    "exit_code=$exit_code"

  if (( session_created )) && [[ -n "${session_name:-}" ]]; then
    runtime_log_warn workspace "cleaning up failed tmux session" \
      "workspace=$workspace" \
      "session_name=$session_name" \
      "step=$startup_step"
    tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
  elif (( window_created )) && [[ -n "${window_id:-}" ]]; then
    runtime_log_warn workspace "cleaning up failed tmux window" \
      "workspace=$workspace" \
      "session_name=${session_name:-}" \
      "window_id=$window_id" \
      "step=$startup_step"
    tmux kill-window -t "$window_id" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap cleanup_failed_startup EXIT

tmux_version_ensure_supported

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
  local login_shell quoted_shell quoted_wrapper
  login_shell="$(resolve_login_shell)"
  quoted_shell="$(printf '%q' "$login_shell")"

  if [[ $# -gt 0 ]]; then
    # primary-pane-wrapper.sh runs the agent under INT/HUP/TERM traps and execs
    # the login shell after the agent returns, so the pane survives both normal
    # exits and Ctrl+C kills. Each transition is logged to category=primary_pane
    # for post-mortem diagnosis of pane deaths.
    quoted_wrapper="$(printf '%q' "$SCRIPT_DIR/primary-pane-wrapper.sh")"
    printf -v command_string '%q ' "$@"
    command_string="${command_string% }"
    printf 'bash %s %s' "$quoted_wrapper" "$command_string"
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

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  startup_step="create_session"
  runtime_log_info workspace "creating tmux session" "session_name=$session_name" "worktree_root=$worktree_root"
  # Pass WEZTERM_PANE directly into the new session's environment via -e so
  # the initial pane and every subsequent pane in this session inherit it.
  # Attention hooks read $WEZTERM_PANE to key state entries to a WezTerm
  # pane id; without this, tmux's default env-propagation would strip it.
  session_env_args=()
  if [[ -n "${WEZTERM_PANE:-}" ]]; then
    session_env_args+=("-e" "WEZTERM_PANE=$WEZTERM_PANE")
  fi
  window_id="$(tmux new-session -d -P -F '#{window_id}' "${session_env_args[@]}" -s "$session_name" -c "$worktree_root" "$primary_shell_command")"
  session_created=1
else
  startup_step="reuse_session"
  runtime_log_info workspace "reusing tmux session" "session_name=$session_name" "worktree_root=$worktree_root"
  # Refresh the session-level WEZTERM_PANE each time a managed tab
  # re-bootstraps; new panes spawned afterwards pick up the current value.
  if [[ -n "${WEZTERM_PANE:-}" ]]; then
    tmux set-environment -t "$session_name" WEZTERM_PANE "$WEZTERM_PANE" 2>/dev/null || true
  fi
  window_id="$(tmux_worktree_find_window "$session_name" "$worktree_root" || true)"
fi

if [[ -z "$window_id" ]]; then
  startup_step="create_window"
  runtime_log_info worktree "creating worktree window" "session_name=$session_name" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  window_id="$(tmux_worktree_create_window "$session_name" "$worktree_root" "$primary_shell_command" "$worktree_label")"
  window_created=1
else
  startup_step="reuse_window"
  runtime_log_info worktree "reusing worktree window" "session_name=$session_name" "window_id=$window_id" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  tmux rename-window -t "$window_id" "$worktree_label"
  if (( session_created )); then
    startup_step="ensure_window_panes"
    tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"
  fi
fi

tmux_worktree_set_session_metadata "$session_name" "$workspace" managed
tmux_worktree_set_window_metadata "$window_id" managed_primary "$worktree_root" "$worktree_label" "$primary_shell_command" managed_two_pane

startup_step="load_tmux_config"
tmux_worktree_ensure_tmux_config_loaded "$TMUX_CONF" "$(repo_root_path)"
startup_step="select_window"
tmux select-window -t "$window_id"

startup_step="attach"
runtime_log_info workspace "open-project-session prepared tmux session" "session_name=$session_name" "window_id=$window_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
runtime_log_info workspace "attaching tmux session" "session_name=$session_name" "window_id=$window_id"
trap - EXIT
exec tmux attach-session -t "$session_name"
