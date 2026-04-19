#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

mkdir -p /tmp/wezterm-reset-repo-a /tmp/wezterm-reset-repo-b
tmux_test_start_session wezterm_work_repoa_hash /tmp/wezterm-reset-repo-a
tmux_test_start_session wezterm_work_repob_hash /tmp/wezterm-reset-repo-b
tmux_test_attach_session wezterm_work_repob_hash

actual="$(tmux_test_run_reset current-session --workspace work --cwd /nonexistent/path || true)"
tmux_test_assert_eq "wezterm_work_repob_hash" "$actual" "managed current-session resolution should fall back to the most recently attached workspace session"

printf 'PASS resolve-current-workspace-session\n'
