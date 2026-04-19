#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

DEFAULT_ROOT="$TEST_ROOT/default-open-root"
OPEN_DEFAULT_SCRIPT="$SCRIPT_DIR/../../../scripts/runtime/open-default-shell-session.sh"
FAKE_SHELL="$TEST_ROOT/fake-login-shell.sh"
ATTACH_MARKER="$TEST_ROOT/default-attach-called"
DESTROY_UNATTACHED_MARKER="$TEST_ROOT/default-destroy-unattached-called"
mkdir -p "$DEFAULT_ROOT"

cat > "$FAKE_SHELL" <<'EOF'
#!/usr/bin/env bash
shift $#
exec sleep 300
EOF
chmod +x "$FAKE_SHELL"
export WEZTERM_MANAGED_SHELL="$FAKE_SHELL"

cat > "$TEST_SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "attach-session" ]]; then
  : > "$ATTACH_MARKER"
  exit 0
fi
exec "$TEST_REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
chmod +x "$TEST_SHIM_DIR/tmux"

bash "$OPEN_DEFAULT_SCRIPT" "$DEFAULT_ROOT"

SESSION_NAME="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | awk '/^wezterm_default_shell_/ { print; exit }')"

if [[ -z "$SESSION_NAME" ]]; then
  printf 'default open should create a tmux-backed default session\n' >&2
  exit 1
fi

if [[ ! -f "$ATTACH_MARKER" ]]; then
  printf 'default open should attempt to attach the tmux-backed default session\n' >&2
  exit 1
fi

WINDOW_ID="$(tmux list-windows -t "$SESSION_NAME" -F '#{window_id}' | head -n 1)"
WINDOW_LABEL="$(tmux display-message -p -t "$WINDOW_ID" '#{window_name}')"
PANE_PATH="$(tmux display-message -p -t "${WINDOW_ID}.0" '#{pane_current_path}')"
SESSION_WORKSPACE="$(tmux show-options -v -t "$SESSION_NAME" @wezterm_workspace 2>/dev/null || true)"
SESSION_ROLE="$(tmux show-options -v -t "$SESSION_NAME" @wezterm_session_role 2>/dev/null || true)"
WINDOW_ROLE="$(tmux show-window-options -v -t "$WINDOW_ID" @wezterm_window_role 2>/dev/null || true)"
WINDOW_ROOT="$(tmux show-window-options -v -t "$WINDOW_ID" @wezterm_window_root 2>/dev/null || true)"
WINDOW_LAYOUT="$(tmux show-window-options -v -t "$WINDOW_ID" @wezterm_window_layout 2>/dev/null || true)"
WINDOW_PRIMARY_COMMAND="$(tmux show-window-options -v -t "$WINDOW_ID" @wezterm_window_primary_command 2>/dev/null || true)"
CLIENT_ATTACHED_HOOK="$(tmux show-hooks -t "$SESSION_NAME" client-attached 2>/dev/null || true)"

tmux_test_assert_eq "default" "$SESSION_WORKSPACE" "default open should mark the tmux session as the default workspace"
tmux_test_assert_eq "default" "$SESSION_ROLE" "default open should persist the default session role"
tmux_test_assert_eq "shell" "$WINDOW_ROLE" "default open should mark the window as a shell window"
tmux_test_assert_eq "$DEFAULT_ROOT" "$WINDOW_ROOT" "default open should persist the default window root"
tmux_test_assert_eq "single" "$WINDOW_LAYOUT" "default open should keep the default session single-pane layout"
tmux_test_assert_eq "$(basename "$DEFAULT_ROOT")" "$WINDOW_LABEL" "default open should label the window from the cwd basename"
tmux_test_assert_eq "$DEFAULT_ROOT" "$PANE_PATH" "default open should start the pane in the requested cwd"

case "$CLIENT_ATTACHED_HOOK" in
  *"destroy-unattached on"*)
    ;;
  *)
    printf 'default open should arm destroy-unattached after the first client attach\nactual hook: %s\n' "$CLIENT_ATTACHED_HOOK" >&2
    exit 1
    ;;
esac

if [[ -f "$DESTROY_UNATTACHED_MARKER" ]]; then
  printf 'default open should not enable destroy-unattached before attach-session runs\n' >&2
  exit 1
fi

case "$WINDOW_PRIMARY_COMMAND" in
  *"$FAKE_SHELL"*"-il"*)
    ;;
  *)
    printf 'default open should persist the login-shell primary command\nexpected shell: %s\nactual: %s\n' "$FAKE_SHELL" "$WINDOW_PRIMARY_COMMAND" >&2
    exit 1
    ;;
esac

printf 'PASS open-default-shell-session-attaches\n'
