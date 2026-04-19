#!/usr/bin/env bash

tmux_worktree_set_session_metadata() {
  local session_name="${1:?missing session name}"
  local workspace_name="${2:-}"
  local session_role="${3:-}"

  if [[ -n "$workspace_name" ]]; then
    tmux set-option -t "$session_name" -q @wezterm_workspace "$workspace_name"
  fi

  if [[ -n "$session_role" ]]; then
    tmux set-option -t "$session_name" -q @wezterm_session_role "$session_role"
  fi
}

tmux_worktree_session_metadata() {
  local session_name="${1:?missing session name}"
  local key="${2:?missing metadata key}"
  tmux show-options -v -t "$session_name" "$key" 2>/dev/null || true
}

tmux_worktree_set_window_metadata() {
  local window_target="${1:?missing window target}"
  local window_role="${2:-}"
  local worktree_root="${3:-}"
  local window_label="${4:-}"
  local primary_command="${5:-}"
  local layout="${6:-}"

  if [[ -n "$window_role" ]]; then
    tmux set-window-option -t "$window_target" -q @wezterm_window_role "$window_role"
  fi

  if [[ -n "$worktree_root" ]]; then
    tmux set-window-option -t "$window_target" -q @wezterm_window_root "$worktree_root"
  fi

  if [[ -n "$window_label" ]]; then
    tmux set-window-option -t "$window_target" -q @wezterm_window_label "$window_label"
  fi

  if [[ -n "$primary_command" ]]; then
    tmux set-window-option -t "$window_target" -q @wezterm_window_primary_command "$primary_command"
  fi

  if [[ -n "$layout" ]]; then
    tmux set-window-option -t "$window_target" -q @wezterm_window_layout "$layout"
  fi
}

tmux_worktree_window_metadata() {
  local window_target="${1:?missing window target}"
  local key="${2:?missing metadata key}"
  tmux show-window-options -v -t "$window_target" "$key" 2>/dev/null || true
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
