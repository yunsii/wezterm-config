#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

PRIMARY_ROOT="$TEST_ROOT/main-pane-primary"
mkdir -p "$PRIMARY_ROOT"

SESSION_NAME="$(tmux_worktree_session_name_for_path work "$PRIMARY_ROOT")"
WINDOW_ID="$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION_NAME" -c "$PRIMARY_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"
tmux rename-window -t "$WINDOW_ID" "$(basename "$PRIMARY_ROOT")"

PRIMARY_COMMAND="/bin/sh -lc 'printf agent-refresh\\n; exec sleep 300'"
tmux_test_set_session_metadata "$SESSION_NAME" work managed
tmux_test_set_window_metadata "$WINDOW_ID" managed_primary "$PRIMARY_ROOT" "$(basename "$PRIMARY_ROOT")" "$PRIMARY_COMMAND" managed_two_pane
tmux_worktree_ensure_window_panes "$WINDOW_ID" "$PRIMARY_ROOT"
tmux select-window -t "$WINDOW_ID"
tmux select-pane -t "${WINDOW_ID}.0"
tmux_test_attach_session "$SESSION_NAME"

actual="$(tmux_test_run_reset refresh-current-window --session-name "$SESSION_NAME" --window-id "$WINDOW_ID" --cwd "$PRIMARY_ROOT")"
tmux_test_assert_eq "reset_window_in_place" "$actual" "main pane refresh should complete in place"

pane_start_command="$(tmux display-message -p -t "${WINDOW_ID}.0" '#{pane_start_command}')"
case "$pane_start_command" in
  *"agent-refresh"*)
    ;;
  *)
    printf 'main pane refresh should reuse the metadata primary command\nexpected substring: agent-refresh\nactual: %s\n' "$pane_start_command" >&2
    exit 1
    ;;
esac

printf 'PASS refresh-main-pane-command\n'
