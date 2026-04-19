#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

PRIMARY_ROOT="$TEST_ROOT/window-primary"
SECONDARY_ROOT="$TEST_ROOT/window-secondary"
SECONDARY_PANE_ROOT="$TEST_ROOT/window-secondary-pane"
mkdir -p "$PRIMARY_ROOT" "$SECONDARY_ROOT"
mkdir -p "$SECONDARY_PANE_ROOT"

SESSION_NAME="$(tmux_worktree_session_name_for_path work "$PRIMARY_ROOT")"
WINDOW_A="$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION_NAME" -c "$PRIMARY_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"
tmux rename-window -t "$WINDOW_A" "$(basename "$PRIMARY_ROOT")"
tmux_worktree_ensure_window_panes "$WINDOW_A" "$PRIMARY_ROOT"
tmux respawn-pane -k -t "${WINDOW_A}.1" -c "$SECONDARY_PANE_ROOT" /bin/sh -lc 'pwd; exec sleep 300'
tmux new-window -d -P -F '#{window_id}' -t "$SESSION_NAME" -c "$SECONDARY_ROOT" /bin/sh -lc 'pwd; exec sleep 300' >/dev/null
tmux rename-window -t "$SESSION_NAME:1" "$(basename "$SECONDARY_ROOT")"
tmux_test_set_session_metadata "$SESSION_NAME" work managed
tmux_test_set_window_metadata "$WINDOW_A" managed_primary "$PRIMARY_ROOT" "$(basename "$PRIMARY_ROOT")" "/bin/sh -lc 'pwd; exec sleep 300'" managed_two_pane
tmux_test_set_window_metadata "$SESSION_NAME:1" managed_primary "$SECONDARY_ROOT" "$(basename "$SECONDARY_ROOT")" "/bin/sh -lc 'pwd; exec sleep 300'" managed_two_pane
tmux select-window -t "$WINDOW_A"
tmux select-pane -t "${WINDOW_A}.1"
tmux_test_attach_session "$SESSION_NAME"

actual="$(tmux_test_run_reset refresh-current-window --session-name "$SESSION_NAME" --window-id "$WINDOW_A" --cwd "$SECONDARY_PANE_ROOT")"
tmux_test_assert_eq "reset_window_in_place" "$actual" "managed window reset should complete in place"

window_count="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' | wc -l | tr -d ' ')"
tmux_test_assert_eq "2" "$window_count" "managed window reset should not kill sibling windows"

pane_listing="$(tmux list-panes -t "$WINDOW_A" -F '#{pane_index}|#{pane_current_path}' | sort)"
tmux_test_assert_contains_line "0|$PRIMARY_ROOT" "$pane_listing" "managed window reset should keep the primary pane on the worktree root"
tmux_test_assert_contains_line "1|$SECONDARY_PANE_ROOT" "$pane_listing" "managed window reset should refresh only the focused shell pane"

window_name="$(tmux display-message -p -t "$WINDOW_A" '#{window_name}')"
tmux_test_assert_eq "$(basename "$PRIMARY_ROOT")" "$window_name" "managed window reset should preserve the window label"

window_listing="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}|#{pane_current_path}')"
tmux_test_assert_contains_line "$(basename "$SECONDARY_ROOT")|$SECONDARY_ROOT" "$window_listing" "managed window reset should leave sibling windows untouched"

printf 'PASS reset-managed-window\n'
