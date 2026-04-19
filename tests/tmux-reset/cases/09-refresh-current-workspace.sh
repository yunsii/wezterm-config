#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

ROOT_A="$TEST_ROOT/workspace-a"
ROOT_B="$TEST_ROOT/workspace-b"
PRIMARY_COMMAND="/bin/sh -lc 'pwd; exec sleep 300'"
mkdir -p "$ROOT_A" "$ROOT_B"

SESSION_A="$(tmux_worktree_session_name_for_path work "$ROOT_A")"
SESSION_B="$(tmux_worktree_session_name_for_path work "$ROOT_B")"
WINDOW_A="$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION_A" -c "$ROOT_A" /bin/sh -lc 'pwd; exec sleep 300')"
WINDOW_B="$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION_B" -c "$ROOT_B" /bin/sh -lc 'pwd; exec sleep 300')"
tmux rename-window -t "$WINDOW_A" "$(basename "$ROOT_A")"
tmux rename-window -t "$WINDOW_B" "$(basename "$ROOT_B")"

tmux_test_set_session_metadata "$SESSION_A" work managed
tmux_test_set_session_metadata "$SESSION_B" work managed
tmux_test_set_window_metadata "$WINDOW_A" managed_primary "$ROOT_A" "$(basename "$ROOT_A")" "$PRIMARY_COMMAND" managed_two_pane
tmux_test_set_window_metadata "$WINDOW_B" managed_primary "$ROOT_B" "$(basename "$ROOT_B")" "$PRIMARY_COMMAND" managed_two_pane
tmux_worktree_ensure_window_panes "$WINDOW_A" "$ROOT_A"
tmux_worktree_ensure_window_panes "$WINDOW_B" "$ROOT_B"

tmux_test_attach_session "$SESSION_A"
tmux_test_attach_session "$SESSION_B"

CLIENT_A="$(tmux_test_client_ttys_for_session "$SESSION_A" | head -n 1)"
CLIENT_B="$(tmux_test_client_ttys_for_session "$SESSION_B" | head -n 1)"
actual="$(tmux_test_run_reset refresh-current-workspace --session-name "$SESSION_A" --window-id "$WINDOW_A" --cwd "$ROOT_A" --client-tty "$CLIENT_A")"
tmux_test_assert_eq "refreshed_workspace" "$actual" "workspace refresh should rebuild every workspace session"

tmux has-session -t "$SESSION_A"
tmux has-session -t "$SESSION_B"
client_a_session="$(tmux list-clients -F '#{client_tty} #{session_name}' | awk -v target="$CLIENT_A" '$1 == target { print $2; exit }')"
client_b_session="$(tmux list-clients -F '#{client_tty} #{session_name}' | awk -v target="$CLIENT_B" '$1 == target { print $2; exit }')"
tmux_test_assert_eq "$SESSION_A" "$client_a_session" "workspace refresh should preserve the current attached client"
tmux_test_assert_eq "$SESSION_B" "$client_b_session" "workspace refresh should preserve sibling attached clients"

printf 'PASS refresh-current-workspace\n'
