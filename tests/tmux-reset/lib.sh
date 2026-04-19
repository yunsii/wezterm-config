#!/usr/bin/env bash
set -euo pipefail

TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_LIB_DIR/../.." && pwd)"
TMUX_RESET_SCRIPT="$REPO_ROOT/scripts/runtime/tmux-reset.sh"

tmux_test_require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$name" >&2
    exit 1
  }
}

tmux_test_setup() {
  tmux_test_require_cmd tmux
  tmux_test_require_cmd script
  tmux_test_require_cmd mktemp

  TEST_REAL_TMUX="$(command -v tmux)"
  TEST_ROOT="$(mktemp -d /tmp/wezterm-tmux-reset.XXXXXX)"
  TEST_SOCKET="wezterm-tmux-reset-${RANDOM}-$$"
  TEST_SHIM_DIR="$TEST_ROOT/bin"
  TEST_HOME="$TEST_ROOT/home"
  TEST_LOG="$TEST_ROOT/runtime.log"
  mkdir -p "$TEST_SHIM_DIR" "$TEST_HOME"

  cat > "$TEST_SHIM_DIR/tmux" <<EOF
#!/usr/bin/env bash
exec "$TEST_REAL_TMUX" -L "$TEST_SOCKET" "\$@"
EOF
  chmod +x "$TEST_SHIM_DIR/tmux"

  export PATH="$TEST_SHIM_DIR:$PATH"
  export HOME="$TEST_HOME"
  export WEZTERM_RUNTIME_LOG_FILE="$TEST_LOG"
  export WEZTERM_MANAGED_SHELL=/bin/bash
  export TEST_REAL_TMUX
  export TEST_SOCKET
  : > "$HOME/.hushlogin"

  ATTACH_PIDS=()
}

tmux_test_teardown() {
  local pid=""

  for pid in "${ATTACH_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done

  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "${TEST_ROOT:-}"
}

tmux_test_start_session() {
  local session_name="${1:?missing session name}"
  local cwd="${2:?missing cwd}"
  local startup_command="${3:-pwd; exec sleep 300}"

  tmux new-session -d -s "$session_name" -c "$cwd" /bin/sh -lc "$startup_command"
}

tmux_test_attach_session() {
  local session_name="${1:?missing session name}"
  local attach_cmd=""
  local pid=""

  printf -v attach_cmd 'tmux attach-session -t %q' "$session_name"
  script -qefc "$attach_cmd" /dev/null >/dev/null 2>&1 &
  pid=$!
  ATTACH_PIDS+=("$pid")

  tmux_test_wait_for_session_attached "$session_name" 1
}

tmux_test_wait_for_session_attached() {
  local session_name="${1:?missing session name}"
  local expected="${2:?missing expected attached flag}"
  local attempt=""
  local attached=""

  for attempt in $(seq 1 100); do
    attached="$(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
      | awk -v target="$session_name" '$1 == target { print $2; exit }')"
    if [[ "$attached" == "$expected" ]]; then
      return 0
    fi
    sleep 0.05
  done

  printf 'session %s did not reach attached=%s\n' "$session_name" "$expected" >&2
  return 1
}

tmux_test_wait_for_window_state() {
  local session_name="${1:?missing session name}"
  local expected_command="${2:?missing expected command}"
  local expected_path="${3:?missing expected path}"
  local attempt=""
  local state=""

  for attempt in $(seq 1 100); do
    state="$(tmux list-windows -t "$session_name" -F '#{pane_current_command}|#{pane_current_path}' 2>/dev/null | head -n 1 || true)"
    if [[ "$state" == "$expected_command|$expected_path" ]]; then
      return 0
    fi
    sleep 0.05
  done

  printf 'window state for %s did not reach command=%s path=%s; last=%s\n' "$session_name" "$expected_command" "$expected_path" "$state" >&2
  return 1
}

tmux_test_assert_eq() {
  local expected="${1-}"
  local actual="${2-}"
  local message="${3:-assertion failed}"

  if [[ "$expected" != "$actual" ]]; then
    printf '%s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

tmux_test_assert_contains_line() {
  local needle="${1:?missing needle}"
  local haystack="${2-}"
  local message="${3:-missing expected line}"

  if ! grep -Fqx "$needle" <<<"$haystack"; then
    printf '%s\nmissing: %s\nhaystack:\n%s\n' "$message" "$needle" "$haystack" >&2
    exit 1
  fi
}

tmux_test_assert_not_contains_line() {
  local needle="${1:?missing needle}"
  local haystack="${2-}"
  local message="${3:-unexpected line found}"

  if grep -Fqx "$needle" <<<"$haystack"; then
    printf '%s\nunexpected: %s\nhaystack:\n%s\n' "$message" "$needle" "$haystack" >&2
    exit 1
  fi
}

tmux_test_run_reset() {
  bash "$TMUX_RESET_SCRIPT" "$@"
}

tmux_test_list_sessions() {
  tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null || true
}

tmux_test_set_session_metadata() {
  local session_name="${1:?missing session name}"
  local workspace_name="${2:?missing workspace name}"
  local session_role="${3:?missing session role}"

  tmux set-option -t "$session_name" -q @wezterm_workspace "$workspace_name"
  tmux set-option -t "$session_name" -q @wezterm_session_role "$session_role"
}

tmux_test_set_window_metadata() {
  local window_target="${1:?missing window target}"
  local window_role="${2:?missing window role}"
  local window_root="${3:?missing window root}"
  local window_label="${4:?missing window label}"
  local primary_command="${5:?missing primary command}"
  local layout="${6:?missing layout}"

  tmux set-window-option -t "$window_target" -q @wezterm_window_role "$window_role"
  tmux set-window-option -t "$window_target" -q @wezterm_window_root "$window_root"
  tmux set-window-option -t "$window_target" -q @wezterm_window_label "$window_label"
  tmux set-window-option -t "$window_target" -q @wezterm_window_primary_command "$primary_command"
  tmux set-window-option -t "$window_target" -q @wezterm_window_layout "$layout"
}

tmux_test_client_ttys_for_session() {
  local session_name="${1:?missing session name}"

  tmux list-clients -F '#{client_tty} #{session_name}' 2>/dev/null \
    | awk -v target="$session_name" '$2 == target { print $1 }'
}
