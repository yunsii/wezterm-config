#!/usr/bin/env bash

wt_git_in_repo() {
  local cwd="${1:-$PWD}"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1
}

wt_git_abs_path() {
  local cwd="${1:-$PWD}"
  local flag="${2:?missing git rev-parse flag}"
  local value=""

  value="$(git -C "$cwd" rev-parse --path-format=absolute "$flag" 2>/dev/null || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  value="$(git -C "$cwd" rev-parse "$flag" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    return 1
  fi

  if [[ "$value" == /* ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if (
    cd "$cwd"
    cd "$value" 2>/dev/null
  ); then
    (
      cd "$cwd"
      cd "$value"
      pwd -P
    )
    return 0
  fi

  local git_dir=""
  git_dir="$(git -C "$cwd" rev-parse --git-dir 2>/dev/null || true)"
  if [[ -n "$git_dir" ]]; then
    if [[ "$git_dir" == /* ]]; then
      if (
        cd "$git_dir"
        cd "$value" 2>/dev/null
      ); then
        (
          cd "$git_dir"
          cd "$value"
          pwd -P
        )
        return 0
      fi
    else
      if (
        cd "$cwd"
        cd "$git_dir"
        cd "$value" 2>/dev/null
      ); then
        (
          cd "$cwd"
          cd "$git_dir"
          cd "$value"
          pwd -P
        )
        return 0
      fi
    fi
  fi

  printf '%s\n' "$value"
}

wt_git_repo_root() {
  wt_git_abs_path "${1:-$PWD}" --show-toplevel
}

wt_git_common_dir() {
  wt_git_abs_path "${1:-$PWD}" --git-common-dir
}

wt_git_main_root() {
  local common_dir="${1:-}"
  [[ -n "$common_dir" ]] || return 1
  dirname "$common_dir"
}

wt_git_repo_label() {
  local repo_root="${1:-$PWD}"
  basename "$repo_root"
}

wt_git_branch_for_root() {
  local worktree_root="${1:-$PWD}"

  if ! wt_git_in_repo "$worktree_root"; then
    return 0
  fi

  git -C "$worktree_root" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$worktree_root" rev-parse --short HEAD 2>/dev/null \
    || true
}

wt_git_branch_exists() {
  local repo_root="${1:?missing repo root}"
  local branch_name="${2:?missing branch name}"
  git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name"
}

wt_git_worktree_label_for_root() {
  local worktree_root="${1:?missing worktree root}"
  local main_root="${2:-}"
  local branch=""

  if [[ -n "$main_root" && "$worktree_root" == "$main_root" ]]; then
    branch="$(wt_git_branch_for_root "$worktree_root")"
    if [[ -n "$branch" ]]; then
      printf '%s\n' "$branch"
    else
      printf 'main\n'
    fi
    return 0
  fi

  basename "$worktree_root"
}
