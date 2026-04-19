#!/usr/bin/env bash
set -euo pipefail

line_index="${1:-0}"
session_name="${2:-}"
option_name="@tmux_status_line_${line_index}"
override_option_name="@tmux_status_override_line_${line_index}"

if [[ -n "$session_name" ]]; then
  override_value="$(tmux show-options -qv -t "$session_name" "$override_option_name" 2>/dev/null || true)"
else
  override_value="$(tmux show -gv "$override_option_name" 2>/dev/null || true)"
fi

if [[ -n "${override_value:-}" ]]; then
  printf '%s' "$override_value"
  exit 0
fi

if [[ -n "$session_name" ]]; then
  tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
else
  tmux show -gv "$option_name" 2>/dev/null || true
fi
