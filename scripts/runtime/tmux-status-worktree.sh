#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"

session_name="${1:-}"
window_id="${2:-}"
cwd="${3:-$PWD}"

if [[ ! -d "$cwd" ]]; then
  cwd="$PWD"
fi

main_worktree_root=""
worktree_kind=""
list_root="$cwd"
linked_count=""
worktree_root=""
context=""

context="$(tmux_worktree_context_for_path "$cwd" || true)"
if [[ -n "$context" ]]; then
  IFS=$'\t' read -r worktree_root _ main_worktree_root _ <<< "$context"
fi

if [[ -n "$worktree_root" && -n "$main_worktree_root" ]]; then
  worktree_kind="$(tmux_worktree_kind_for_root "$worktree_root" "$main_worktree_root")"
  list_root="$main_worktree_root"
fi

if [[ -n "$worktree_kind" ]]; then
  linked_count="$(tmux_worktree_linked_count "$list_root")"
  join_with_separator \
    "$(style 'fg=#7f7a72' ' · ')" \
    "$(style 'fg=#7f7a72' "linked:${linked_count:-0}")" \
    "$(style 'fg=#4e7a54' "$worktree_kind")"
else
  style 'fg=#7f7a72' 'no-worktree'
fi
