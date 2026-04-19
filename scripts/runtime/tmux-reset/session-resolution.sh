#!/usr/bin/env bash

resolve_session_name() {
  local workspace=""
  local cwd=""

  while (($# > 0)); do
    case "$1" in
      --workspace)
        workspace="${2:?missing value for --workspace}"
        shift 2
        ;;
      --cwd)
        cwd="${2:?missing value for --cwd}"
        shift 2
        ;;
      *)
        printf 'tmux-reset session-name: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$workspace" && "$workspace" != "default" ]] || {
    printf 'tmux-reset session-name requires a non-default workspace\n' >&2
    return 1
  }
  [[ -n "$cwd" ]] || {
    printf 'tmux-reset session-name requires --cwd\n' >&2
    return 1
  }

  cwd="$(tmux_worktree_abs_path "$cwd")"
  printf '%s\n' "$(tmux_worktree_session_name_for_path "$workspace" "$cwd")"
}

resolve_attached_workspace_session() {
  local workspace="${1:?missing workspace}"
  local prefix="wezterm_${workspace}_"
  local best_session=""
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""

  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$prefix"* ]] || continue

    if (( ${session_attached:-0} > best_attached )) \
      || (( ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-sessions -F '#{session_name}|#{session_last_attached}|#{session_attached}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

resolve_current_workspace_session() {
  local workspace=""
  local cwd=""
  local session_name=""

  while (($# > 0)); do
    case "$1" in
      --workspace)
        workspace="${2:?missing value for --workspace}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset current-session: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$workspace" && "$workspace" != "default" ]] || {
    printf 'tmux-reset current-session requires a non-default workspace\n' >&2
    return 1
  }

  if [[ -n "$cwd" && -d "$cwd" ]]; then
    session_name="$(resolve_session_name --workspace "$workspace" --cwd "$cwd" || true)"
    if [[ -n "$session_name" ]]; then
      printf '%s\n' "$session_name"
      return 0
    fi
  fi

  resolve_attached_workspace_session "$workspace"
}

resolve_default_session() {
  local cwd=""
  local best_session=""
  local best_score=-1
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""
  local pane_path=""
  local score=0

  while (($# > 0)); do
    case "$1" in
      --cwd)
        cwd="${2:?missing value for --cwd}"
        shift 2
        ;;
      *)
        printf 'tmux-reset resolve-default-session: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$cwd" ]] || {
    printf 'tmux-reset resolve-default-session requires --cwd\n' >&2
    return 1
  }

  cwd="$(tmux_worktree_abs_path "$cwd")"
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached pane_path; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$default_session_prefix"* ]] || continue

    score="$(path_match_score "$pane_path" "$cwd")"
    if (( score <= 0 )); then
      continue
    fi

    if (( score > best_score )) \
      || (( score == best_score && ${session_attached:-0} > best_attached )) \
      || (( score == best_score && ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_score="$score"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-panes -a -F '#{session_name}|#{session_last_attached}|#{session_attached}|#{pane_current_path}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

resolve_attached_default_session() {
  local best_session=""
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""

  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$default_session_prefix"* ]] || continue

    if (( ${session_attached:-0} > best_attached )) \
      || (( ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-sessions -F '#{session_name}|#{session_last_attached}|#{session_attached}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

list_default_sessions() {
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v prefix="$default_session_prefix" 'index($0, prefix) == 1 { print }' \
    | unique_lines
}

list_sessions() {
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  tmux list-sessions -F '#{session_name}' 2>/dev/null | unique_lines
}

session_workspace_name() {
  local session_name="${1:?missing session name}"
  local workspace_name=""

  workspace_name="$(tmux_worktree_session_metadata "$session_name" @wezterm_workspace)"
  if [[ -n "$workspace_name" ]]; then
    printf '%s\n' "$workspace_name"
    return 0
  fi

  if [[ "$session_name" == "$default_session_prefix"* ]]; then
    printf 'default\n'
    return 0
  fi

  workspace_name="$(printf '%s' "$session_name" | sed -n 's/^wezterm_\([^_][^_]*\)_.*/\1/p')"
  if [[ -n "$workspace_name" ]]; then
    printf '%s\n' "$workspace_name"
  fi
}

session_role() {
  local session_name="${1:?missing session name}"
  local role=""

  role="$(tmux_worktree_session_metadata "$session_name" @wezterm_session_role)"
  if [[ -n "$role" ]]; then
    printf '%s\n' "$role"
    return 0
  fi

  if [[ "$session_name" == "$default_session_prefix"* ]]; then
    printf 'default\n'
  else
    printf 'managed\n'
  fi
}

workspace_session_names() {
  local workspace_name="${1:?missing workspace name}"
  local session_name=""

  while IFS= read -r session_name; do
    [[ -n "$session_name" ]] || continue
    if [[ "$(session_workspace_name "$session_name")" == "$workspace_name" ]]; then
      printf '%s\n' "$session_name"
    fi
  done < <(list_sessions)
}

ordered_target_sessions() {
  local current_session="${1:-}"
  shift || true
  local session_name=""

  for session_name in "$@"; do
    [[ -n "$session_name" && "$session_name" != "$current_session" ]] || continue
    printf '%s\n' "$session_name"
  done

  if [[ -n "$current_session" ]]; then
    for session_name in "$@"; do
      if [[ "$session_name" == "$current_session" ]]; then
        printf '%s\n' "$session_name"
        break
      fi
    done
  fi
}
