#!/usr/bin/env bash
set -euo pipefail

line_index="${1:-0}"
session_name="${2:-}"
option_name="@tmux_status_line_${line_index}"

if [[ -n "$session_name" ]]; then
  tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
else
  tmux show -gv "$option_name" 2>/dev/null || true
fi
