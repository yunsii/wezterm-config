#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

PRIMARY_ROOT="$TEST_ROOT/session-primary"
SECONDARY_ROOT="$TEST_ROOT/session-secondary"
PRIMARY_COMMAND="/bin/sh -lc 'printf session-agent-refresh\\n; exec sleep 300'"
mkdir -p "$PRIMARY_ROOT" "$SECONDARY_ROOT"

SESSION_NAME="$(tmux_worktree_session_name_for_path work "$PRIMARY_ROOT")"
WINDOW_A="$(tmux new-session -d -P -F '#{window_id}' -s "$SESSION_NAME" -c "$PRIMARY_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"
tmux rename-window -t "$WINDOW_A" "$(basename "$PRIMARY_ROOT")"
WINDOW_B="$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION_NAME" -c "$SECONDARY_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"
tmux rename-window -t "$WINDOW_B" "$(basename "$SECONDARY_ROOT")"

tmux_test_set_session_metadata "$SESSION_NAME" work managed
tmux_test_set_window_metadata "$WINDOW_A" managed_primary "$PRIMARY_ROOT" "$(basename "$PRIMARY_ROOT")" "$PRIMARY_COMMAND" managed_two_pane
tmux_test_set_window_metadata "$WINDOW_B" managed_primary "$SECONDARY_ROOT" "$(basename "$SECONDARY_ROOT")" "$PRIMARY_COMMAND" managed_two_pane
tmux_worktree_ensure_window_panes "$WINDOW_A" "$PRIMARY_ROOT"
tmux_worktree_ensure_window_panes "$WINDOW_B" "$SECONDARY_ROOT"
tmux select-window -t "$WINDOW_A"
tmux_test_attach_session "$SESSION_NAME"

CLIENT_TTY="$(tmux_test_client_ttys_for_session "$SESSION_NAME" | head -n 1)"
actual="$(tmux_test_run_reset refresh-current-session --session-name "$SESSION_NAME" --window-id "$WINDOW_A" --cwd "$PRIMARY_ROOT" --client-tty "$CLIENT_TTY")"
tmux_test_assert_eq "refreshed_session" "$actual" "current session refresh should rebuild through replacement session"

tmux has-session -t "$SESSION_NAME"
tmux_test_wait_for_session_attached "$SESSION_NAME" 1
client_session="$(tmux list-clients -F '#{client_tty} #{session_name}' | awk -v target="$CLIENT_TTY" '$1 == target { print $2; exit }')"
tmux_test_assert_eq "$SESSION_NAME" "$client_session" "attached client should stay bound to the canonical session name after refresh"

window_listing="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_name}|#{pane_current_path}' | sort)"
tmux_test_assert_contains_line "$(basename "$PRIMARY_ROOT")|$PRIMARY_ROOT" "$window_listing" "refreshed session should keep the primary worktree window"
tmux_test_assert_contains_line "$(basename "$SECONDARY_ROOT")|$SECONDARY_ROOT" "$window_listing" "refreshed session should keep the sibling worktree window"

REFRESHED_WINDOW_A="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}|#{window_name}|#{pane_current_path}' \
  | awk -F'|' -v target_name="$(basename "$PRIMARY_ROOT")" -v target_path="$PRIMARY_ROOT" '$2 == target_name && $3 == target_path { print $1; exit }')"
if [[ -z "$REFRESHED_WINDOW_A" ]]; then
  printf 'primary refreshed window should be resolvable\n' >&2
  exit 1
fi

primary_pane_start_command="$(tmux display-message -p -t "${REFRESHED_WINDOW_A}.0" '#{pane_start_command}')"
case "$primary_pane_start_command" in
  *"session-agent-refresh"*)
    ;;
  *)
    printf 'session refresh should restore the primary pane managed command\nexpected substring: session-agent-refresh\nactual: %s\n' "$primary_pane_start_command" >&2
    exit 1
    ;;
esac

printf 'PASS refresh-current-session\n'
