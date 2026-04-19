#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

tmux_test_start_session wezterm_default_shell_test_a /home/yuns
tmux_test_attach_session wezterm_default_shell_test_a
tmux_test_start_session wezterm_default_shell_test_b /tmp
tmux_test_start_session plain_other_session /var/tmp

actual="$(tmux_test_run_reset reset-default --cwd /home/yuns --kill-other-sessions)"
tmux_test_assert_eq "reset_in_place" "$actual" "global cleanup should still reset the active default session in place"
tmux_test_wait_for_window_state wezterm_default_shell_test_a bash /home/yuns

sessions="$(tmux_test_list_sessions)"
tmux_test_assert_eq "wezterm_default_shell_test_a 1" "$sessions" "global cleanup should leave only the active attached default session"

printf 'PASS cleanup-all-sessions\n'

