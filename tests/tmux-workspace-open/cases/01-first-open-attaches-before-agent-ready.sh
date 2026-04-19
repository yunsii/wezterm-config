#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../tmux-reset/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../scripts/runtime/tmux-worktree-lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

WORKTREE_ROOT="$REPO_ROOT"
EVENT_LOG="$TEST_ROOT/fake-agent-events.log"
SESSION_NAME="$(tmux_worktree_session_name_for_path config "$WORKTREE_ROOT")"

cat > "$TEST_SHIM_DIR/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'start\n' >> "$EVENT_LOG"
sleep 5
printf 'ready\n' >> "$EVENT_LOG"
exec sleep 300
EOF
chmod +x "$TEST_SHIM_DIR/codex"

printf -v open_cmd 'bash %q config %q codex -c %q' \
  "$REPO_ROOT/scripts/runtime/open-project-session.sh" \
  "$WORKTREE_ROOT" \
  'tui.theme="github"'

script -qefc "$open_cmd" /dev/null >/dev/null 2>&1 &
open_pid=$!
ATTACH_PIDS+=("$open_pid")

attached=""
for _ in $(seq 1 40); do
  attached="$(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
    | awk -v target="$SESSION_NAME" '$1 == target { print $2; exit }' || true)"
  if [[ "$attached" == "1" ]]; then
    break
  fi
  sleep 0.1
done

tmux_test_assert_eq "1" "$attached" "first workspace open should attach the tmux session without waiting for the managed command to finish"

if [[ -f "$EVENT_LOG" ]] && grep -Fqx 'ready' "$EVENT_LOG"; then
  printf 'managed command became ready before the session attached; event log:\n%s\n' "$(cat "$EVENT_LOG")" >&2
  exit 1
fi

runtime_log_contents="$(cat "$TEST_LOG")"
if [[ -z "$runtime_log_contents" ]]; then
  printf 'runtime log should be populated\n' >&2
  exit 1
fi

if ! grep -Fq 'message="open-project-session prepared tmux session"' "$TEST_LOG"; then
  printf 'expected open-project-session to log prepared tmux session before attach\nruntime log:\n%s\n' "$runtime_log_contents" >&2
  exit 1
fi

if ! grep -Fq 'message="attaching tmux session"' "$TEST_LOG"; then
  printf 'expected open-project-session to log tmux attach\nruntime log:\n%s\n' "$runtime_log_contents" >&2
  exit 1
fi

printf 'PASS first-open-attaches-before-agent-ready\n'
