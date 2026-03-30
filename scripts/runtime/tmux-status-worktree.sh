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
linked_count=""
worktree_root=""

count_linked_worktrees() {
  local main_root="${1:-}"
  local count=0
  local line=""
  local listed_root=""

  if [[ -z "$main_root" || ! -d "$main_root" ]]; then
    printf '0\n'
    return
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        listed_root="${line#worktree }"
        if [[ "$listed_root" != "$main_root" ]]; then
          ((count += 1))
        fi
        ;;
    esac
  done < <(git -C "$main_root" worktree list --porcelain 2>/dev/null || true)

  printf '%s\n' "$count"
}

if [[ -n "$session_name" ]]; then
  main_worktree_root="$(tmux_worktree_session_option "$session_name" @wezterm_main_worktree_root)"
fi

if [[ -n "$window_id" ]]; then
  worktree_root="$(tmux_worktree_window_option "$window_id" @wezterm_worktree_root)"
fi

if [[ -n "$worktree_root" && -n "$main_worktree_root" ]]; then
  worktree_kind="$(tmux_worktree_kind_for_root "$worktree_root" "$main_worktree_root")"
elif tmux_worktree_in_git_repo "$cwd"; then
  worktree_root="$(tmux_worktree_repo_root "$cwd")"
  if [[ -z "$main_worktree_root" ]]; then
    main_worktree_root="$(tmux_worktree_main_root "$(tmux_worktree_common_dir "$cwd")" || true)"
  fi
  worktree_kind="$(tmux_worktree_kind_for_root "$worktree_root" "$main_worktree_root")"
fi

if [[ -n "$worktree_kind" ]]; then
  linked_count="$(count_linked_worktrees "$main_worktree_root")"
  join_with_separator \
    "$(style 'fg=#7f7a72' ' · ')" \
    "$(style 'fg=#7f7a72' "linked:${linked_count:-0}")" \
    "$(style 'fg=#4e7a54' "$worktree_kind")"
else
  style 'fg=#7f7a72' 'no-worktree'
fi
