#!/usr/bin/env bash
# Switch the workspace overflow tab to <session>, then publish a
# tab.activate_overflow event so the wezterm side activates the
# overflow tab + refreshes the unified pane → session map.
#
# Used by attention.activate_in_gui as the "no host found" fallback
# for a picker jump. Without this the row would fall through to the
# entry stored wezterm_pane_id (a stale id that often resolves to
# the user own current pane), and the click would visibly do
# nothing. With this, Alt+/ on a parked-but-running session projects
# it into the workspace overflow tab and brings the user there.
#
# Usage: attention-project-into-overflow.sh <workspace> <session>
set -u

workspace="${1:?missing workspace}"
target="${2:?missing session}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/wezterm-event-lib.sh"
# shellcheck disable=SC1091
. "$script_dir/runtime-log-lib.sh" 2>/dev/null || true

start_ms="$(date +%s%3N 2>/dev/null || printf '0')"

# Step 1: switch the overflow client to the target session.
attach_rc=0
attach_out="$(bash "$script_dir/tab-overflow-attach.sh" "$workspace" "$target" 2>&1)" || attach_rc=$?

if (( attach_rc != 0 )); then
  if command -v runtime_log_warn >/dev/null 2>&1; then
    runtime_log_warn attention "project-into-overflow attach failed" \
      "workspace=$workspace" "session=$target" "rc=$attach_rc" "out=$attach_out"
  fi
  exit "$attach_rc"
fi

# Step 2: publish tab.activate_overflow so wezterm activates the
# overflow tab + refreshes the unified map for the new projection.
WEZTERM_EVENT_FORCE_FILE=1 \
  wezterm_event_send "tab.activate_overflow" \
    "v1|workspace=${workspace}|session=${target}" || true

if command -v runtime_log_info >/dev/null 2>&1; then
  runtime_log_info attention "project-into-overflow dispatched" \
    "workspace=$workspace" "session=$target" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms" 2>/dev/null || printf '?')"
fi
