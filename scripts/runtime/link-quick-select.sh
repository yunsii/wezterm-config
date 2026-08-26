#!/usr/bin/env bash
# Trigger WezTerm QuickSelect (open http(s) URLs in the focused pane) from
# the tmux command palette. Palette run-shell has no reliable DCS path into
# WezTerm, so force the file transport; titles.lua handles link.quick_select
# on the next update-status tick (≤250 ms).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/wezterm-event-lib.sh"

WEZTERM_EVENT_FORCE_FILE=1 wezterm_event_send "link.quick_select" "1"
