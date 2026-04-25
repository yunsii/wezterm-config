#!/usr/bin/env bash
# Shared tmux-version helpers for managed-session entry scripts.
# Callers must already have runtime-log-lib.sh sourced.

tmux_version_current() {
  tmux -V 2>/dev/null | awk '{print $2}' | sed 's/[^0-9.]//g'
}

tmux_version_at_least() {
  local target_major="$1"
  local target_minor="$2"
  local version major minor
  version="$(tmux_version_current)"
  IFS='.' read -r major minor _ <<< "$version"
  major="${major:-0}"
  minor="${minor:-0}"
  (( major > target_major )) && return 0
  (( major == target_major && minor >= target_minor )) && return 0
  return 1
}

# Warn (but do not abort) when the host tmux is older than 3.6. 3.3 added
# allow-passthrough; 3.6 added the 1s flush timeout for synchronized output
# (DEC mode 2026), without which tmux stalls idle renders waiting on ESU
# and inner agent CLIs (Claude Code, ...) suppress BSU/ESU entirely.
tmux_version_ensure_supported() {
  if tmux_version_at_least 3 6; then
    return 0
  fi
  local installed
  installed="$(tmux_version_current)"
  runtime_log_warn workspace "tmux version below recommended floor" "tmux_version=${installed:-unknown}"
  cat <<EOF >&2
Warning: tmux ${installed:-} is older than 3.6.
Managed tmux workspaces require tmux 3.3+ for allow-passthrough and benefit
from 3.6+ for synchronized-output (DEC mode 2026) passthrough, which keeps
the IME candidate window stable under streaming output from agent CLIs.
EOF
}
