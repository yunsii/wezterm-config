#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

render_repo="$(tmux_option_or_env TMUX_STATUS_RENDER_REPO @tmux_status_render_repo '1')"
render_worktree="$(tmux_option_or_env TMUX_STATUS_RENDER_WORKTREE @tmux_status_render_worktree '1')"
render_branch="$(tmux_option_or_env TMUX_STATUS_RENDER_BRANCH @tmux_status_render_branch '1')"
render_git_changes="$(tmux_option_or_env TMUX_STATUS_RENDER_GIT_CHANGES @tmux_status_render_git_changes '1')"
render_node="$(tmux_option_or_env TMUX_STATUS_RENDER_NODE @tmux_status_render_node '1')"
render_wakatime="$(tmux_option_or_env TMUX_STATUS_RENDER_WAKATIME @tmux_status_render_wakatime '1')"
padding="$(tmux_option_or_env TMUX_STATUS_PADDING @tmux_status_padding ' ')"
separator="$(tmux_option_or_env TMUX_STATUS_SEPARATOR @tmux_status_separator ' · ')"
session_name="${1:-}"
window_id="${2:-}"
cwd="${3:-$PWD}"

target_status="off"

line1_enabled=0
line2_enabled=0
line3_enabled=0
main_line=""
worktree_line=""
wakatime_line=""

if is_enabled "$render_repo" || is_enabled "$render_branch" || is_enabled "$render_git_changes" || is_enabled "$render_node"; then
  line1_enabled=1
fi

if is_enabled "$render_worktree"; then
  line2_enabled=1
fi

if (( line1_enabled )); then
  main_line="$(
    TMUX_STATUS_PADDING="$padding" \
    TMUX_STATUS_SEPARATOR="$separator" \
    TMUX_STATUS_RENDER_REPO="$render_repo" \
    TMUX_STATUS_RENDER_BRANCH="$render_branch" \
    TMUX_STATUS_RENDER_GIT_CHANGES="$render_git_changes" \
    TMUX_STATUS_RENDER_NODE="$render_node" \
      bash "$script_dir/tmux-status-line-main.sh" "$cwd"
  )"
fi

if (( line2_enabled )); then
  worktree_line="$(
    TMUX_STATUS_PADDING="$padding" \
    TMUX_STATUS_RENDER_WORKTREE="$render_worktree" \
      bash "$script_dir/tmux-status-line-worktree.sh" "$cwd" "$session_name" "$window_id"
  )"
fi

if is_enabled "$render_wakatime"; then
  line3_enabled=1
fi

if (( line3_enabled )); then
  wakatime_line="$(
    TMUX_STATUS_PADDING="$padding" \
    TMUX_STATUS_SEPARATOR="$separator" \
    TMUX_STATUS_RENDER_WAKATIME="$render_wakatime" \
      bash "$script_dir/tmux-status-wakatime.sh"
  )"
fi

if (( line3_enabled )); then
  target_status="3"
elif (( line2_enabled )); then
  target_status="2"
elif (( line1_enabled )); then
  target_status="on"
else
  target_status="off"
fi

current_status="$(tmux show -gv status 2>/dev/null || printf 'on')"

if [[ -n "$session_name" ]]; then
  current_status="$(tmux show-options -qv -t "$session_name" status 2>/dev/null || printf '%s' "$current_status")"
fi

if [[ "$current_status" != "$target_status" ]]; then
  if [[ -n "$session_name" ]]; then
    tmux set-option -q -t "$session_name" status "$target_status" 2>/dev/null || true
  else
    tmux set -g status "$target_status" 2>/dev/null || true
  fi
fi

if [[ -n "$session_name" ]]; then
  tmux set-option -q -t "$session_name" @tmux_status_line_0 "$main_line" 2>/dev/null || true
  tmux set-option -q -t "$session_name" @tmux_status_line_1 "$worktree_line" 2>/dev/null || true
  tmux set-option -q -t "$session_name" @tmux_status_line_2 "$wakatime_line" 2>/dev/null || true
else
  tmux set-option -gq @tmux_status_line_0 "$main_line" 2>/dev/null || true
  tmux set-option -gq @tmux_status_line_1 "$worktree_line" 2>/dev/null || true
  tmux set-option -gq @tmux_status_line_2 "$wakatime_line" 2>/dev/null || true
fi
