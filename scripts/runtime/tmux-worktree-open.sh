#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"

session_name="${1:-}"
worktree_root="${2:-}"
source_window_id="${3:-}"
cwd="${4:-$PWD}"
target_common_dir=""
context=""
source_worktree_root=""
main_worktree_root=""
worktree_label=""
window_id=""
template_window=""

if [[ -z "$session_name" || -z "$worktree_root" ]]; then
  tmux display-message 'Worktree switch failed: missing session or worktree path'
  exit 1
fi

worktree_root="$(tmux_worktree_abs_path "$worktree_root")"

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  tmux display-message "Worktree switch failed: missing session $session_name"
  exit 1
fi

if [[ ! -d "$worktree_root" ]]; then
  tmux display-message "Worktree path is unavailable: $worktree_root"
  exit 1
fi

if ! tmux_worktree_in_git_repo "$worktree_root"; then
  tmux display-message "Not a git worktree: $worktree_root"
  exit 1
fi

target_common_dir="$(tmux_worktree_common_dir "$worktree_root" || true)"
if [[ -z "$target_common_dir" ]]; then
  tmux display-message "Target path is not a git worktree: $worktree_root"
  exit 0
fi

context="$(tmux_worktree_context_for_context "$source_window_id" "$cwd" || true)"
if [[ -z "$context" ]]; then
  tmux display-message 'Current pane is not inside a git worktree'
  exit 0
fi

IFS=$'\t' read -r source_worktree_root repo_common_dir _ _ <<< "$context"
if [[ "$target_common_dir" != "$repo_common_dir" ]]; then
  tmux display-message 'Target path is not part of the current repo family'
  exit 1
fi

main_worktree_root="$(tmux_worktree_main_root "$repo_common_dir" || true)"
worktree_label="$(tmux_worktree_label_for_root "$worktree_root" "$main_worktree_root")"
window_id="$(tmux_worktree_find_window "$session_name" "$worktree_root" || true)"

if [[ -z "$window_id" ]]; then
  runtime_log_info worktree "creating worktree window" "session_name=$session_name" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  template_window="$(tmux_worktree_template_window "$session_name" "$source_window_id" || true)"
  window_id="$(tmux_worktree_create_window_from_template "$session_name" "$worktree_root" "$worktree_label" "$template_window" "$source_worktree_root")"
else
  runtime_log_info worktree "selecting existing worktree window" "session_name=$session_name" "window_id=$window_id" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  tmux rename-window -t "$window_id" "$worktree_label"
fi

tmux select-window -t "$window_id"
bash "$script_dir/tmux-status-refresh.sh" --window "$window_id" --force --refresh-client >/dev/null 2>&1 || true
