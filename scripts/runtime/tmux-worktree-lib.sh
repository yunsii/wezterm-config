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

tmux_worktree_file_mtime() {
  local path="${1:?missing path}"

  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
    return
  fi

  stat -f %m "$path"
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

tmux_worktree_window_context() {
  local window_target="${1:?missing window target}"
  local expected_common_dir="${2:-}"
  local pane_path=""
  local pane_context=""
  local pane_root=""
  local pane_common_dir=""
  local pane_main_root=""
  local pane_repo_label=""
  local resolved_root=""
  local resolved_common_dir=""
  local resolved_main_root=""
  local resolved_repo_label=""

  while IFS= read -r pane_path; do
    [[ -n "$pane_path" && -d "$pane_path" ]] || continue

    pane_context="$(tmux_worktree_context_for_path "$pane_path" || true)"
    [[ -n "$pane_context" ]] || continue

    IFS=$'\t' read -r pane_root pane_common_dir pane_main_root pane_repo_label <<< "$pane_context"
    [[ -n "$pane_root" && -n "$pane_common_dir" ]] || continue

    if [[ -n "$expected_common_dir" && "$pane_common_dir" != "$expected_common_dir" ]]; then
      continue
    fi

    if [[ -z "$resolved_root" ]]; then
      resolved_root="$pane_root"
      resolved_common_dir="$pane_common_dir"
      resolved_main_root="$pane_main_root"
      resolved_repo_label="$pane_repo_label"
      continue
    fi

    if [[ "$pane_root" != "$resolved_root" || "$pane_common_dir" != "$resolved_common_dir" ]]; then
      return 1
    fi
  done < <(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null || true)

  [[ -n "$resolved_root" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$resolved_root" "$resolved_common_dir" "$resolved_main_root" "$resolved_repo_label"
}

tmux_worktree_context_for_context() {
  local current_window_id="${1:-}"
  local cwd="${2:-$PWD}"
  local context=""

  if [[ -n "$cwd" && -d "$cwd" ]]; then
    context="$(tmux_worktree_context_for_path "$cwd" || true)"
    if [[ -n "$context" ]]; then
      printf '%s\n' "$context"
      return 0
    fi
  fi

  if [[ -n "$current_window_id" ]]; then
    context="$(tmux_worktree_window_context "$current_window_id" || true)"
    if [[ -n "$context" ]]; then
      printf '%s\n' "$context"
      return 0
    fi
  fi

  return 1
}

tmux_worktree_current_root_for_context() {
  local current_window_id="${1:-}"
  local cwd="${2:-$PWD}"
  local current_worktree_root=""
  local context=""

  context="$(tmux_worktree_context_for_context "$current_window_id" "$cwd" || true)"
  if [[ -n "$context" ]]; then
    IFS=$'\t' read -r current_worktree_root _ <<< "$context"
  fi

  printf '%s\n' "$current_worktree_root"
}

tmux_worktree_ensure_tmux_config_loaded() {
  local tmux_conf="${1:?missing tmux conf}"
  local repo_root="${2:?missing repo root}"
  local desired_mtime=""
  local current_repo_root=""
  local current_mtime=""

  desired_mtime="$(tmux_worktree_file_mtime "$tmux_conf" 2>/dev/null || printf '0')"
  current_repo_root="$(tmux show -gv @wezterm_runtime_root 2>/dev/null || true)"
  current_mtime="$(tmux show -gv @wezterm_tmux_conf_mtime 2>/dev/null || true)"

  if [[ "$current_repo_root" == "$repo_root" && "$current_mtime" == "$desired_mtime" ]]; then
    return 0
  fi

  tmux set-option -g @wezterm_runtime_root "$repo_root"
  tmux source-file "$tmux_conf"
  tmux set-option -gq @wezterm_tmux_conf_mtime "$desired_mtime"
}

tmux_worktree_find_window() {
  local session_name="${1:?missing session name}"
  local worktree_root="${2:?missing worktree root}"
  local repo_common_dir=""
  local window_context=""
  local window_id=""
  local window_root=""

  repo_common_dir="$(tmux_worktree_common_dir "$worktree_root" || true)"

  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    window_context="$(tmux_worktree_window_context "$window_id" "$repo_common_dir" || true)"
    [[ -n "$window_context" ]] || continue
    IFS=$'\t' read -r window_root _ <<< "$window_context"
    if [[ "$window_root" == "$worktree_root" ]]; then
      printf '%s\n' "$window_id"
      return 0
    fi
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)

  return 1
}

tmux_worktree_is_shell_command() {
  local command="${1:-}"
  local command_name=""

  command_name="${command##*/}"
  command_name="${command_name%% *}"

  case "$command_name" in
    sh|ash|bash|dash|fish|ksh|zsh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tmux_worktree_map_path_to_root() {
  local path="${1:-}"
  local source_root="${2:-}"
  local target_root="${3:?missing target root}"
  local resolved_path=""
  local candidate=""

  if [[ -n "$path" && -d "$path" ]]; then
    resolved_path="$(tmux_worktree_abs_path "$path")"
  else
    resolved_path="$source_root"
  fi

  if [[ -n "$source_root" && "$resolved_path" == "$source_root" ]]; then
    candidate="$target_root"
  elif [[ -n "$source_root" && "$resolved_path" == "$source_root"/* ]]; then
    candidate="$target_root/${resolved_path#"$source_root"/}"
  else
    candidate="$target_root"
  fi

  while [[ -n "$candidate" && "$candidate" != "/" && ! -d "$candidate" ]]; do
    candidate="$(dirname "$candidate")"
  done

  if [[ -n "$candidate" && -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  printf '%s\n' "$target_root"
}

tmux_worktree_pane_template_command() {
  local pane_start_command="${1:-}"
  local pane_current_command="${2:-}"

  if [[ -n "$pane_current_command" ]] && ! tmux_worktree_is_shell_command "$pane_current_command"; then
    if [[ -n "$pane_start_command" && "$pane_start_command" != *'--prompt-file '* && "$pane_start_command" != *'--prompt-file='* ]]; then
      printf '%s\n' "$pane_start_command"
      return 0
    fi
    printf '%s\n' "$pane_current_command"
    return 0
  fi

  if [[ -n "$pane_start_command" ]] && ! tmux_worktree_is_shell_command "$pane_start_command" && "$pane_start_command" != *'--prompt-file '* && "$pane_start_command" != *'--prompt-file='* ]]; then
    printf '%s\n' "$pane_start_command"
    return 0
  fi

  printf '\n'
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

tmux_worktree_template_window() {
  local session_name="${1:?missing session name}"
  local current_window_id="${2:-}"
  local window_id=""

  if [[ -n "$current_window_id" ]] && tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null | grep -Fxq "$current_window_id"; then
    printf '%s\n' "$current_window_id"
    return 0
  fi

  window_id="$(tmux display-message -p -t "$session_name" '#{window_id}' 2>/dev/null || true)"
  [[ -n "$window_id" ]] || return 1
  printf '%s\n' "$window_id"
}

tmux_worktree_create_window_from_template() {
  local session_name="${1:?missing session name}"
  local worktree_root="${2:?missing worktree root}"
  local worktree_label="${3:?missing worktree label}"
  local template_window="${4:-}"
  local source_worktree_root="${5:-}"
  local create_mode="${6:-attach}"
  local tmux_args=(new-window -P -F '#{window_id}' -t "$session_name" -c "$worktree_root")
  local layout=""
  local pane_count=0
  local pane_index=""
  local pane_active=""
  local pane_path=""
  local pane_current_command=""
  local pane_start_command=""
  local mapped_cwd=""
  local resolved_command=""
  local active_pane_index=""
  local first_cwd=""
  local first_command=""
  local window_id=""
  local new_pane_count=0
  local new_pane_index=""
  local new_pane_id=""
  local target_window_ref=""
  local -a pane_indices=()
  local -a pane_cwds=()
  local -a pane_commands=()
  local -a pane_active_flags=()
  local -a new_pane_ids=()

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

  if [[ -n "$template_window" ]]; then
    layout="$(tmux display-message -p -t "$template_window" '#{window_layout}' 2>/dev/null || true)"
    while IFS= read -r pane_index; do
      [[ -n "$pane_index" ]] || continue

      pane_active="$(tmux display-message -p -t "${template_window}.${pane_index}" '#{pane_active}' 2>/dev/null || true)"
      pane_path="$(tmux display-message -p -t "${template_window}.${pane_index}" '#{pane_current_path}' 2>/dev/null || true)"
      pane_current_command="$(tmux display-message -p -t "${template_window}.${pane_index}" '#{pane_current_command}' 2>/dev/null || true)"
      pane_start_command="$(tmux display-message -p -t "${template_window}.${pane_index}" '#{pane_start_command}' 2>/dev/null || true)"
      mapped_cwd="$(tmux_worktree_map_path_to_root "$pane_path" "$source_worktree_root" "$worktree_root")"
      resolved_command="$(tmux_worktree_pane_template_command "$pane_start_command" "$pane_current_command")"

      pane_indices+=("$pane_index")
      pane_cwds+=("$mapped_cwd")
      pane_commands+=("$resolved_command")
      pane_active_flags+=("$pane_active")
      if [[ "$pane_active" == "1" ]]; then
        active_pane_index="$pane_index"
      fi
      ((pane_count += 1))
    done < <(tmux list-panes -t "$template_window" -F '#{pane_index}' 2>/dev/null || true)
  fi

  if (( pane_count == 0 )); then
    window_id="$(tmux "${tmux_args[@]}")"
    tmux rename-window -t "$window_id" "$worktree_label"
    printf '%s\n' "$window_id"
    return 0
  fi

  first_cwd="${pane_cwds[0]}"
  first_command="${pane_commands[0]}"
  if [[ -n "$first_command" ]]; then
    window_id="$(tmux "${tmux_args[@]}" "$first_command")"
  else
    window_id="$(tmux "${tmux_args[@]}")"
  fi
  tmux rename-window -t "$window_id" "$worktree_label"

  target_window_ref="$window_id"
  while (( new_pane_count < pane_count - 1 )); do
    new_pane_index=$((new_pane_count + 1))
    if [[ -n "${pane_commands[$new_pane_index]}" ]]; then
      new_pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t "$target_window_ref" -c "${pane_cwds[$new_pane_index]}" "${pane_commands[$new_pane_index]}")"
    else
      new_pane_id="$(tmux split-window -d -P -F '#{pane_id}' -t "$target_window_ref" -c "${pane_cwds[$new_pane_index]}")"
    fi
    new_pane_ids+=("$new_pane_id")
    ((new_pane_count += 1))
  done

  if (( pane_count > 1 )) && [[ -n "$layout" ]]; then
    tmux select-layout -t "$window_id" "$layout" >/dev/null 2>&1 || true
  fi

  if [[ -n "$active_pane_index" ]]; then
    tmux select-pane -t "${window_id}.${active_pane_index}" >/dev/null 2>&1 || true
  fi

  printf '%s\n' "$window_id"
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
