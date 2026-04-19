#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

tmux_test_start_session wezterm_default_shell_test_a /tmp
tmux_test_attach_session wezterm_default_shell_test_a

actual="$(tmux_test_run_reset reset-default --cwd /mnt/c/Users/example)"
tmux_test_assert_eq "reset_in_place" "$actual" "windows-style cwd should still recover the active tmux pane directory during default reset"
tmux_test_wait_for_window_state wezterm_default_shell_test_a bash /tmp

window_state="$(tmux list-windows -t wezterm_default_shell_test_a -F '#{window_name}|#{pane_current_command}|#{pane_current_path}')"
tmux_test_assert_eq "tmp|bash|/tmp" "$window_state" "reset-default should prefer the active tmux pane directory over an unusable Windows cwd"

printf 'PASS fallback-home-directory\n'
