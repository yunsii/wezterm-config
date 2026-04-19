#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

DEFAULT_ROOT="$TEST_ROOT/default-root"
MANAGED_ROOT="$TEST_ROOT/managed-root"
PRIMARY_COMMAND="/bin/sh -lc 'pwd; exec sleep 300'"
mkdir -p "$DEFAULT_ROOT" "$MANAGED_ROOT"

DEFAULT_SESSION="wezterm_default_shell_test"
DEFAULT_WINDOW="$(tmux new-session -d -P -F '#{window_id}' -s "$DEFAULT_SESSION" -c "$DEFAULT_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"
MANAGED_SESSION="$(tmux_worktree_session_name_for_path work "$MANAGED_ROOT")"
MANAGED_WINDOW="$(tmux new-session -d -P -F '#{window_id}' -s "$MANAGED_SESSION" -c "$MANAGED_ROOT" /bin/sh -lc 'pwd; exec sleep 300')"

tmux rename-window -t "$DEFAULT_WINDOW" "$(basename "$DEFAULT_ROOT")"
tmux rename-window -t "$MANAGED_WINDOW" "$(basename "$MANAGED_ROOT")"
tmux_test_set_session_metadata "$DEFAULT_SESSION" default default
tmux_test_set_session_metadata "$MANAGED_SESSION" work managed
tmux_test_set_window_metadata "$DEFAULT_WINDOW" shell "$DEFAULT_ROOT" "$(basename "$DEFAULT_ROOT")" "$PRIMARY_COMMAND" single
tmux_test_set_window_metadata "$MANAGED_WINDOW" managed_primary "$MANAGED_ROOT" "$(basename "$MANAGED_ROOT")" "$PRIMARY_COMMAND" managed_two_pane
tmux_worktree_ensure_window_panes "$MANAGED_WINDOW" "$MANAGED_ROOT"

tmux_test_attach_session "$DEFAULT_SESSION"
tmux_test_attach_session "$MANAGED_SESSION"

CLIENT_MANAGED="$(tmux_test_client_ttys_for_session "$MANAGED_SESSION" | head -n 1)"
CLIENT_DEFAULT="$(tmux_test_client_ttys_for_session "$DEFAULT_SESSION" | head -n 1)"
actual="$(tmux_test_run_reset refresh-all --session-name "$MANAGED_SESSION" --window-id "$MANAGED_WINDOW" --cwd "$MANAGED_ROOT" --client-tty "$CLIENT_MANAGED")"
tmux_test_assert_eq "refreshed_all" "$actual" "global refresh should rebuild every session on the server"

tmux has-session -t "$DEFAULT_SESSION"
tmux has-session -t "$MANAGED_SESSION"
default_client_session="$(tmux list-clients -F '#{client_tty} #{session_name}' | awk -v target="$CLIENT_DEFAULT" '$1 == target { print $2; exit }')"
managed_client_session="$(tmux list-clients -F '#{client_tty} #{session_name}' | awk -v target="$CLIENT_MANAGED" '$1 == target { print $2; exit }')"
tmux_test_assert_eq "$DEFAULT_SESSION" "$default_client_session" "global refresh should preserve attached default-session clients"
tmux_test_assert_eq "$MANAGED_SESSION" "$managed_client_session" "global refresh should preserve attached managed-session clients"

printf 'PASS refresh-all\n'
