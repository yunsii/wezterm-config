#!/usr/bin/env bash
# After kill-server, open-project-session must recreate the ledger last_path
# worktree window (directory still present) instead of leaving focus on the
# configured item cwd / primary worktree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/access-ledger-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

export XDG_STATE_HOME="$TEST_ROOT/xdg"
mkdir -p "$XDG_STATE_HOME"

PROJECT_ROOT="$TEST_ROOT/repo-main"
LINKED_ROOT="$TEST_ROOT/repo-linked"
mkdir -p "$PROJECT_ROOT"
git -C "$PROJECT_ROOT" init -q
git -C "$PROJECT_ROOT" config user.email 'test@example.com'
git -C "$PROJECT_ROOT" config user.name 'test'
printf 'seed\n' > "$PROJECT_ROOT/README"
git -C "$PROJECT_ROOT" add README
git -C "$PROJECT_ROOT" commit -qm seed
git -C "$PROJECT_ROOT" branch -M main
git -C "$PROJECT_ROOT" worktree add -q -b task-restore-probe "$LINKED_ROOT"

SESSION_NAME="$(tmux_worktree_session_name_for_path work "$PROJECT_ROOT")"
OPEN_PROJECT_SESSION_SCRIPT="$SCRIPT_DIR/../../../scripts/runtime/open-project-session.sh"

# open-project-session ends in `exec tmux attach-session`; stub attach so the
# script returns after session prep (same pattern as case 12).
cat > "$TEST_SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "attach-session" ]]; then
  exit 0
fi
exec "$TEST_REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
chmod +x "$TEST_SHIM_DIR/tmux"

# Seed durable last_path as the linked worktree, then open (creates session
# at the configured main cwd and should recreate+focus last_path).
access_ledger_touch "$SESSION_NAME" "$LINKED_ROOT" 9001

bash "$OPEN_PROJECT_SESSION_SCRIPT" \
  work \
  "$PROJECT_ROOT" \
  /bin/sh \
  -lc \
  'exec sleep 300'

tmux has-session -t "$SESSION_NAME"

window_count="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' | grep -c . || true)"
if [[ "$window_count" -lt 2 ]]; then
  printf 'expected main + restored last_path windows, got %s\n' "$window_count" >&2
  tmux list-windows -t "$SESSION_NAME" -F '#{window_id} #{window_name} #{pane_current_path}' >&2 || true
  exit 1
fi

active_path="$(tmux display-message -p -t "$SESSION_NAME" '#{pane_current_path}')"
active_path="$(tmux_worktree_abs_path "$active_path")"
linked_abs="$(tmux_worktree_abs_path "$LINKED_ROOT")"
if [[ "$active_path" != "$linked_abs" ]]; then
  printf 'cold open should focus ledger last_path worktree\nexpected: %s\ngot:      %s\n' \
    "$linked_abs" "$active_path" >&2
  tmux list-windows -t "$SESSION_NAME" -F '#{window_id} #{window_name} #{pane_current_path}' >&2 || true
  exit 1
fi

ledger_path="$(access_ledger_session_last_path "$SESSION_NAME")"
ledger_path="$(tmux_worktree_abs_path "$ledger_path")"
if [[ "$ledger_path" != "$linked_abs" ]]; then
  printf 'ledger last_path should stay on the restored worktree (not main)\nexpected: %s\ngot:      %s\n' \
    "$linked_abs" "$ledger_path" >&2
  exit 1
fi

runtime_log="${XDG_STATE_HOME}/wezterm-runtime/logs/runtime.log"
if [[ -f "$WEZTERM_RUNTIME_LOG_FILE" ]]; then
  runtime_log="$WEZTERM_RUNTIME_LOG_FILE"
fi
if [[ ! -f "$runtime_log" ]] || ! grep -Fq 'recreating last_path worktree window' "$runtime_log"; then
  printf 'expected restore_last_path_window log in %s\n' "$runtime_log" >&2
  [[ -f "$runtime_log" ]] && cat "$runtime_log" >&2
  exit 1
fi

printf 'PASS open-project-session-restores-last-path-window\n'
