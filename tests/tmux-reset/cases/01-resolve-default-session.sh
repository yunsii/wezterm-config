#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

tmux_test_start_session wezterm_default_shell_test_a /home/yuns
tmux_test_start_session wezterm_default_shell_test_b /tmp

actual="$(tmux_test_run_reset resolve-default-session --cwd /home/yuns)"
tmux_test_assert_eq "wezterm_default_shell_test_a" "$actual" "resolve-default-session should match the exact default-session cwd"

printf 'PASS resolve-default-session\n'

