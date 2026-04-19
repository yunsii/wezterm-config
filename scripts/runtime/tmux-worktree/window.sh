#!/usr/bin/env bash

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
    tmux split-window -d -h -t "$first_pane" -c "$cwd"
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
  local first_command=""
  local window_id=""
  local new_pane_count=0
  local new_pane_index=""
  local new_pane_id=""
  local target_window_ref=""
  local -a pane_cwds=()
  local -a pane_commands=()

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

      pane_cwds+=("$mapped_cwd")
      pane_commands+=("$resolved_command")
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
    : "${new_pane_id:?missing new pane id}"
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
