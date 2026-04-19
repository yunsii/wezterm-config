#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

PROJECT_ROOT="$TEST_ROOT/open-project-session-root"
mkdir -p "$PROJECT_ROOT"

SESSION_NAME="$(tmux_worktree_session_name_for_path work "$PROJECT_ROOT")"
OPEN_PROJECT_SESSION_SCRIPT="$SCRIPT_DIR/../../../scripts/runtime/open-project-session.sh"

cat > "$TEST_SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "attach-session" ]]; then
  exit 0
fi
exec "$TEST_REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
chmod +x "$TEST_SHIM_DIR/tmux"

bash "$OPEN_PROJECT_SESSION_SCRIPT" \
  work \
  "$PROJECT_ROOT" \
  /bin/sh \
  -lc \
  'printf open-project-agent\n; exec sleep 300'

tmux has-session -t "$SESSION_NAME"

WINDOW_ID="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' | head -n 1)"
primary_command_metadata="$(tmux show-window-options -v -t "$WINDOW_ID" @wezterm_window_primary_command 2>/dev/null || true)"
case "$primary_command_metadata" in
  *"open-project-agent"*)
    ;;
  *)
    printf 'open-project-session should persist the managed primary command metadata\nexpected substring: open-project-agent\nactual: %s\n' "$primary_command_metadata" >&2
    exit 1
    ;;
esac

printf 'PASS open-project-session-persists-primary-command\n'
