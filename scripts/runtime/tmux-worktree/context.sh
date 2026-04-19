#!/usr/bin/env bash

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

tmux_worktree_current_root_for_window() {
  local current_window_id="${1:-}"
  local current_worktree_root=""
  local context=""

  if [[ -n "$current_window_id" ]]; then
    context="$(tmux_worktree_window_context "$current_window_id" || true)"
    if [[ -n "$context" ]]; then
      IFS=$'\t' read -r current_worktree_root _ <<< "$context"
    fi
  fi

  printf '%s\n' "$current_worktree_root"
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
