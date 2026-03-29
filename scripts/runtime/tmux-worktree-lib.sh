#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"

tmux_worktree_hash() {
  local value="${1:-}"

  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha1sum | awk '{print substr($1, 1, 10)}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum | awk '{print substr($1, 1, 10)}'
    return
  fi

  printf '%s' "$value" | cksum | awk '{print $1}'
}

tmux_worktree_shell_quote() {
  printf '%q' "${1:-}"
}

tmux_worktree_sanitize_name() {
  printf '%s' "${1:-}" | tr '/ .:' '____'
}

tmux_worktree_abs_path() {
  local path="${1:-$PWD}"
  (
    cd "$path"
    pwd -P
  )
}

tmux_worktree_in_git_repo() {
  local cwd="${1:-$PWD}"
  git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1
}

tmux_worktree_git_abs_path() {
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

tmux_worktree_repo_root() {
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

tmux_worktree_session_option() {
  local session_name="${1:?missing session name}"
  local option_name="${2:?missing option name}"
  tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
}

tmux_worktree_window_option() {
  local window_target="${1:?missing window target}"
  local option_name="${2:?missing option name}"
  tmux show-options -qv -w -t "$window_target" "$option_name" 2>/dev/null || true
}

tmux_worktree_current_root_for_context() {
  local current_window_id="${1:-}"
  local cwd="${2:-$PWD}"
  local current_worktree_root=""

  if [[ -n "$current_window_id" ]]; then
    current_worktree_root="$(tmux_worktree_window_option "$current_window_id" @wezterm_worktree_root)"
  fi

  if [[ -z "$current_worktree_root" && -d "$cwd" ]] && tmux_worktree_in_git_repo "$cwd"; then
    current_worktree_root="$(tmux_worktree_repo_root "$cwd")"
  fi

  printf '%s\n' "$current_worktree_root"
}

tmux_worktree_set_session_metadata() {
  local session_name="${1:?missing session name}"
  local repo_common_dir="${2:-}"
  local repo_label="${3:-}"
  local main_worktree_root="${4:-}"
  local primary_shell_command="${5:-}"

  tmux set-option -q -t "$session_name" @wezterm_repo_common_dir "$repo_common_dir"
  tmux set-option -q -t "$session_name" @wezterm_repo_label "$repo_label"
  tmux set-option -q -t "$session_name" @wezterm_main_worktree_root "$main_worktree_root"
  tmux set-option -q -t "$session_name" @wezterm_primary_shell_command "$primary_shell_command"
}

tmux_worktree_set_window_metadata() {
  local window_target="${1:?missing window target}"
  local worktree_root="${2:-}"
  local worktree_label="${3:-}"

  tmux set-option -q -w -t "$window_target" @wezterm_worktree_root "$worktree_root"
  tmux set-option -q -w -t "$window_target" @wezterm_worktree_label "$worktree_label"
}

tmux_worktree_find_window() {
  local session_name="${1:?missing session name}"
  local worktree_root="${2:?missing worktree root}"

  while IFS=$'\t' read -r window_id window_root; do
    if [[ "$window_root" == "$worktree_root" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}	#{@wezterm_worktree_root}' 2>/dev/null || true)

  return 1
}

tmux_worktree_ensure_window_panes() {
  local window_target="${1:?missing window target}"
  local cwd="${2:?missing cwd}"
  local pane_count=""
  local first_pane=""

  pane_count="$(tmux list-panes -t "$window_target" 2>/dev/null | wc -l | tr -d ' ')"
  first_pane="$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null | head -n 1)"

  if [[ -z "$first_pane" ]]; then
    return 1
  fi

  if [[ "${pane_count:-0}" -lt 2 ]]; then
    runtime_log_info worktree "adding missing secondary pane" "window_target=$window_target" "cwd=$cwd" "pane_count=${pane_count:-0}"
    tmux split-window -h -t "$first_pane" -c "$cwd"
  fi

  tmux select-pane -t "$first_pane"
}

tmux_worktree_create_window() {
  local session_name="${1:?missing session name}"
  local worktree_root="${2:?missing worktree root}"
  local primary_shell_command="${3:?missing primary shell command}"
  local worktree_label="${4:?missing worktree label}"
  local create_mode="${5:-attach}"
  local window_id=""
  local tmux_args=(new-window -P -F '#{window_id}' -t "$session_name" -c "$worktree_root")

  case "$create_mode" in
    attach)
      ;;
    detached)
      tmux_args+=(-d)
      ;;
    *)
      printf 'invalid create mode: %s\n' "$create_mode" >&2
      return 1
      ;;
  esac

  window_id="$(tmux "${tmux_args[@]}" "$primary_shell_command")"
  tmux_worktree_set_window_metadata "$window_id" "$worktree_root" "$worktree_label"
  tmux rename-window -t "$window_id" "$worktree_label"
  tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"
  printf '%s\n' "$window_id"
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
