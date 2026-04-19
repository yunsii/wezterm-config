#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

tmux_test_start_session wezterm_default_shell_test_a /home/yuns
tmux_test_attach_session wezterm_default_shell_test_a

actual="$(tmux_test_run_reset reset-default --cwd /home/yuns)"
tmux_test_assert_eq "reset_in_place" "$actual" "reset-default should complete in place for an attached default session"
tmux_test_wait_for_window_state wezterm_default_shell_test_a bash /home/yuns

sessions="$(tmux_test_list_sessions)"
tmux_test_assert_contains_line "wezterm_default_shell_test_a 1" "$sessions" "attached default session should still exist after in-place reset"

window_state="$(tmux list-windows -t wezterm_default_shell_test_a -F '#{window_name}|#{pane_current_command}|#{pane_current_path}')"
tmux_test_assert_eq "yuns|bash|/home/yuns" "$window_state" "default session should restore the working directory and rename the window"

printf 'PASS reset-in-place\n'

