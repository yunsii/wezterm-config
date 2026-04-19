#!/usr/bin/env bash

tmux_worktree_find_git_root() {
  local cwd="${1:-$PWD}"
  local current=""

  current="$(tmux_worktree_abs_path "$cwd")"
  while [[ -n "$current" ]]; do
    if [[ -e "$current/.git" ]]; then
      printf '%s\n' "$current"
      return 0
    fi

    if [[ "$current" == "/" ]]; then
      break
    fi

    current="$(dirname "$current")"
  done

  return 1
}

tmux_worktree_in_git_repo() {
  local cwd="${1:-$PWD}"
  tmux_worktree_find_git_root "$cwd" >/dev/null 2>&1 || git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1
}

tmux_worktree_git_abs_path() {
  local cwd="${1:-$PWD}"
  local flag="${2:?missing git rev-parse flag}"
  local value=""
  local git_dir=""

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

tmux_worktree_repo_root() {
  local root=""

  root="$(tmux_worktree_find_git_root "${1:-$PWD}" || true)"
  if [[ -n "$root" ]]; then
    printf '%s\n' "$root"
    return 0
  fi

  tmux_worktree_git_abs_path "${1:-$PWD}" --show-toplevel
}

tmux_worktree_common_dir() {
  tmux_worktree_git_abs_path "${1:-$PWD}" --git-common-dir
}

tmux_worktree_main_root() {
  local common_dir="${1:-}"
  [[ -n "$common_dir" ]] || return 1
  dirname "$common_dir"
}

tmux_worktree_primary_root_for_path() {
  local cwd="${1:-$PWD}"
  local resolved_cwd=""
  local common_dir=""
  local main_root=""
  local repo_root=""

  resolved_cwd="$(tmux_worktree_abs_path "$cwd")"

  if ! tmux_worktree_in_git_repo "$resolved_cwd"; then
    printf '%s\n' "$resolved_cwd"
    return 0
  fi

  common_dir="$(tmux_worktree_common_dir "$resolved_cwd" || true)"
  if [[ -n "$common_dir" ]]; then
    main_root="$(tmux_worktree_main_root "$common_dir" || true)"
    if [[ -n "$main_root" && -d "$main_root" ]]; then
      printf '%s\n' "$main_root"
      return 0
    fi
  fi

  repo_root="$(tmux_worktree_repo_root "$resolved_cwd" || true)"
  if [[ -n "$repo_root" ]]; then
    printf '%s\n' "$repo_root"
    return 0
  fi

  printf '%s\n' "$resolved_cwd"
}

tmux_worktree_repo_label() {
  local repo_root="${1:-$PWD}"
  basename "$repo_root"
}

tmux_worktree_label_for_root() {
  local worktree_root="${1:-}"
  local main_root="${2:-}"
  local branch=""

  if [[ -z "$worktree_root" ]]; then
    printf 'unknown\n'
    return 0
  fi

  if [[ -n "$main_root" && "$worktree_root" == "$main_root" ]]; then
    branch="$(tmux_worktree_branch_for_root "$worktree_root")"
    if [[ -n "$branch" ]]; then
      printf '%s\n' "$branch"
    else
      printf 'main\n'
    fi
    return 0
  fi

  basename "$worktree_root"
}

tmux_worktree_kind_for_root() {
  local worktree_root="${1:-}"
  local main_root="${2:-}"

  if [[ -z "$worktree_root" ]]; then
    printf 'unknown\n'
    return 0
  fi

  if [[ -n "$main_root" && "$worktree_root" == "$main_root" ]]; then
    printf 'primary\n'
    return 0
  fi

  printf 'linked\n'
}

tmux_worktree_branch_for_root() {
  local worktree_root="${1:-$PWD}"

  if ! tmux_worktree_in_git_repo "$worktree_root"; then
    return 0
  fi

  git -C "$worktree_root" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$worktree_root" rev-parse --short HEAD 2>/dev/null \
    || true
}

tmux_worktree_session_name_for_path() {
  local workspace="${1:?missing workspace}"
  local cwd="${2:?missing cwd}"
  local session_key=""
  local repo_label=""
  local resolved_cwd=""

  resolved_cwd="$(tmux_worktree_abs_path "$cwd")"

  if tmux_worktree_in_git_repo "$resolved_cwd"; then
    local repo_root=""
    local common_dir=""
    repo_root="$(tmux_worktree_repo_root "$resolved_cwd")"
    common_dir="$(tmux_worktree_common_dir "$resolved_cwd")"
    repo_label="$(tmux_worktree_repo_label "$repo_root")"
    session_key="$common_dir"
  else
    repo_label="$(basename "$resolved_cwd")"
    session_key="$resolved_cwd"
  fi

  printf 'wezterm_%s_%s_%s\n' \
    "$(tmux_worktree_sanitize_name "$workspace")" \
    "$(tmux_worktree_sanitize_name "$repo_label")" \
    "$(tmux_worktree_hash "$session_key")"
}

tmux_worktree_context_for_path() {
  local cwd="${1:-$PWD}"
  local repo_root=""
  local common_dir=""
  local main_root=""
  local repo_label=""

  [[ -d "$cwd" ]] || return 1
  tmux_worktree_in_git_repo "$cwd" || return 1

  repo_root="$(tmux_worktree_repo_root "$cwd" || true)"
  common_dir="$(tmux_worktree_common_dir "$cwd" || true)"
  [[ -n "$repo_root" && -n "$common_dir" ]] || return 1

  main_root="$(tmux_worktree_main_root "$common_dir" || true)"
  repo_label="$(tmux_worktree_repo_label "$repo_root")"

  printf '%s\t%s\t%s\t%s\n' "$repo_root" "$common_dir" "$main_root" "$repo_label"
}

tmux_worktree_list() {
  local cwd="${1:-$PWD}"
  local repo_root=""
  local main_root=""
  local current_path=""
  local current_branch=""

  if ! tmux_worktree_in_git_repo "$cwd"; then
    return 1
  fi

  repo_root="$(tmux_worktree_repo_root "$cwd")"
  main_root="$(tmux_worktree_main_root "$(tmux_worktree_common_dir "$cwd")")"

  emit_current() {
    local label=""
    local branch="$current_branch"

    [[ -n "$current_path" ]] || return 0

    label="$(tmux_worktree_label_for_root "$current_path" "$main_root")"
    if [[ -z "$branch" ]]; then
      branch="$(tmux_worktree_branch_for_root "$current_path")"
    fi

    printf '%s\t%s\t%s\n' "$label" "$current_path" "$branch"
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      worktree\ *)
        emit_current
        current_path="${line#worktree }"
        current_branch=""
        ;;
      branch\ refs/heads/*)
        current_branch="${line#branch refs/heads/}"
        ;;
      branch\ *)
        current_branch="${line#branch }"
        ;;
      "")
        emit_current
        current_path=""
        current_branch=""
        ;;
    esac
  done < <(git -C "$repo_root" worktree list --porcelain 2>/dev/null || true)

  emit_current
}

tmux_worktree_linked_count() {
  local cwd="${1:-$PWD}"
  local count=0
  local label=""
  local worktree_path=""
  local main_root=""

  if tmux_worktree_in_git_repo "$cwd"; then
    main_root="$(tmux_worktree_main_root "$(tmux_worktree_common_dir "$cwd")" || true)"
  fi

  while IFS=$'\t' read -r label worktree_path _; do
    [[ -n "$label" ]] || continue
    if [[ -n "$main_root" && "$worktree_path" != "$main_root" ]]; then
      ((count += 1))
    fi
  done < <(tmux_worktree_list "$cwd" || true)

  printf '%s\n' "$count"
}
