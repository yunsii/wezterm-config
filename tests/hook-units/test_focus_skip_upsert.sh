#!/usr/bin/env bash
# Failing tests for the second focus-ack semantic gap: when the firing
# pane is the currently-focused tmux pane, emit-agent-status.sh should
# NOT upsert a waiting / done entry into attention.json. The user
# rationale: "如果 focus 了的 tmux pane 不触发 waiting 和 done 的加一操作".
#
# Drive: scripts/dev/test-lua-units.sh (or run this file directly).
set -u

# Hard safety: refuse to run if any of the WINDOWS_* path overrides
# are unset OR resolve to /mnt/c — the hook would otherwise write
# into the user's real attention.json. This caught a real incident
# during development of this very test (bare debug invocation
# polluted live state with pane:10 / pane:11 waiting entries).
guard_sandbox_paths() {
  local p="$1"
  if [[ -z "$p" || "$p" == /mnt/c/* ]]; then
    echo "SAFETY ABORT: sandbox path resolves to live state ($p)" >&2
    exit 99
  fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/scripts/claude-hooks/emit-agent-status.sh"

pass=0
fail=0

# Build an isolated sandbox per case so state files do not leak across
# tests. Override XDG_STATE_HOME so attention_state_path resolves
# inside the sandbox; clear the in-process path cache that the lib
# memoizes; pretend we are not running on hybrid-wsl so the windows
# branch does not steal our XDG path.
run_hook_in_sandbox() {
  local sandbox status notification_type wezterm_pane tmux_socket tmux_session tmux_pane focused_pane
  sandbox="$1" status="$2" notification_type="$3"
  wezterm_pane="$4" tmux_socket="$5" tmux_session="$6" tmux_pane="$7" focused_pane="$8"

  guard_sandbox_paths "$sandbox/wezterm-runtime"
  mkdir -p "$sandbox/wezterm-runtime/state/agent-attention/tmux-focus"
  if [[ -n "$focused_pane" ]]; then
    local safe_socket safe_session
    safe_socket="${tmux_socket//\//_}"
    safe_session="${tmux_session#\$}"
    printf '%s\n' "$focused_pane" > \
      "$sandbox/wezterm-runtime/state/agent-attention/tmux-focus/${safe_socket}__${safe_session}.txt"
  fi
  # Wezterm-side focused pane signal. Tests pass an extra positional
  # arg `wezterm_focused_pane_id` via the env override below; default
  # to the firing wezterm_pane so the "focused on this pane" cases
  # still suppress as expected.
  printf '{"focused_wezterm_pane_id":"%s"}\n' "${MOCK_WEZTERM_FOCUSED_PANE_ID:-$wezterm_pane}" > \
    "$sandbox/wezterm-runtime/state/agent-attention/live-panes.json"

  # Mock tmux so hook reads our values instead of the real session
  # this test runs inside.
  mkdir -p "$sandbox/bin"
  cat > "$sandbox/bin/tmux" <<'TMUX_EOF'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    fmt=""; want_fmt=0
    for arg in "$@"; do
      if (( want_fmt == 1 )); then fmt="$arg"; want_fmt=0
      elif [[ "$arg" == "-F" ]]; then want_fmt=1
      fi
    done
    out="$fmt"
    out="${out//#\{socket_path\}/${MOCK_TMUX_SOCKET}}"
    out="${out//#\{session_name\}/${MOCK_TMUX_SESSION}}"
    out="${out//#\{window_id\}/${MOCK_TMUX_WINDOW}}"
    out="${out//#\{pane_id\}/${MOCK_TMUX_PANE}}"
    out="${out//#\{pane_current_path\}/${HOME}}"
    printf '%s\n' "$out"
    ;;
  *) exit 0 ;;
esac
TMUX_EOF
  chmod +x "$sandbox/bin/tmux"

  env \
    HOME="$HOME" USER="$USER" SHELL="$SHELL" LANG="${LANG:-C}" \
    PATH="$sandbox/bin:$PATH" \
    TMUX="dummy" \
    MOCK_TMUX_SOCKET="$tmux_socket" \
    MOCK_TMUX_SESSION="$tmux_session" \
    MOCK_TMUX_WINDOW="@1" \
    MOCK_TMUX_PANE="$tmux_pane" \
    MOCK_WEZTERM_FOCUSED_PANE_ID="${MOCK_WEZTERM_FOCUSED_PANE_ID:-}" \
    MOCK_HOOK_STDIN="${MOCK_HOOK_STDIN:-}" \
    WINDOWS_RUNTIME_STATE_WSL="$sandbox/wezterm-runtime" \
    WINDOWS_LOCALAPPDATA_WSL="$sandbox" \
    WINDOWS_USERPROFILE_WSL="$sandbox" \
    WEZTERM_NO_PATH_CACHE=1 \
    WEZTERM_PANE="$wezterm_pane" \
    TMUX_PANE="$tmux_pane" \
    NOTIFICATION_TYPE="$notification_type" \
    bash "$hook" "$status" <<<"${MOCK_HOOK_STDIN:-}" >/dev/null 2>&1 || true
}

state_file_in() {
  printf '%s/wezterm-runtime/state/agent-attention/attention.json' "$1"
}

assert_no_entry_for_pane() {
  local label="$1" sandbox="$2" tmux_pane="$3"
  local state_path
  state_path="$(state_file_in "$sandbox")"
  if [[ ! -s "$state_path" ]]; then
    echo "  ✓ $label"; pass=$((pass+1)); return
  fi
  if jq -e --arg p "$tmux_pane" '.entries // {} | to_entries[] | select(.value.tmux_pane == $p)' "$state_path" >/dev/null 2>&1; then
    echo "  ✗ $label"; echo "    found upserted entry for tmux_pane=$tmux_pane on focused pane:"
    jq '.entries' "$state_path" 2>/dev/null | sed 's/^/    /'
    fail=$((fail+1))
  else
    echo "  ✓ $label"; pass=$((pass+1))
  fi
}

assert_has_entry_for_pane() {
  local label="$1" sandbox="$2" tmux_pane="$3"
  local state_path
  state_path="$(state_file_in "$sandbox")"
  if [[ ! -s "$state_path" ]]; then
    echo "  ✗ $label"; echo "    no state file written"; fail=$((fail+1)); return
  fi
  if jq -e --arg p "$tmux_pane" '.entries // {} | to_entries[] | select(.value.tmux_pane == $p)' "$state_path" >/dev/null 2>&1; then
    echo "  ✓ $label"; pass=$((pass+1))
  else
    echo "  ✗ $label"; echo "    expected entry for tmux_pane=$p but state has:"
    jq '.entries' "$state_path" 2>/dev/null | sed 's/^/    /'
    fail=$((fail+1))
  fi
}

assert_no_entry_for_session() {
  local label="$1" sandbox="$2" session_id="$3"
  local state_path
  state_path="$(state_file_in "$sandbox")"
  if [[ ! -s "$state_path" ]]; then
    echo "  ✓ $label"; pass=$((pass+1)); return
  fi
  if jq -e --arg s "$session_id" '.entries // {} | has($s)' "$state_path" >/dev/null 2>&1; then
    if jq -e --arg s "$session_id" '.entries[$s]' "$state_path" >/dev/null 2>&1; then
      echo "  ✗ $label"; echo "    session $session_id still in state:"
      jq --arg s "$session_id" '.entries[$s]' "$state_path" 2>/dev/null | sed 's/^/    /'
      fail=$((fail+1))
      return
    fi
  fi
  echo "  ✓ $label"; pass=$((pass+1))
}

# Seed the state file with an existing entry before the hook runs —
# simulates "agent has been running, now hits done while user is
# focused on the pane".
seed_running_entry() {
  local sandbox session_id wezterm_pane tmux_socket tmux_session tmux_window tmux_pane
  sandbox="$1"; session_id="$2"; wezterm_pane="$3"
  tmux_socket="$4"; tmux_session="$5"; tmux_window="$6"; tmux_pane="$7"
  guard_sandbox_paths "$sandbox/wezterm-runtime"
  mkdir -p "$sandbox/wezterm-runtime/state/agent-attention"
  cat > "$sandbox/wezterm-runtime/state/agent-attention/attention.json" <<JSON
{
  "version": 1,
  "entries": {
    "$session_id": {
      "session_id": "$session_id",
      "wezterm_pane_id": "$wezterm_pane",
      "tmux_socket": "$tmux_socket",
      "tmux_session": "$tmux_session",
      "tmux_window": "$tmux_window",
      "tmux_pane": "$tmux_pane",
      "status": "running",
      "reason": "old running",
      "ts": $(date +%s%3N)
    }
  }
}
JSON
}

echo "▸ emit-agent-status.sh focused-pane skip"

# Case 1: pane IS focused, status=waiting → entry MUST NOT appear.
sandbox="$(mktemp -d)"
run_hook_in_sandbox "$sandbox" "waiting" "permission_prompt" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_no_entry_for_pane "waiting on focused pane is suppressed" "$sandbox" "%5"
rm -rf "$sandbox"

# Case 2: pane IS focused, status=done → entry MUST NOT appear.
sandbox="$(mktemp -d)"
run_hook_in_sandbox "$sandbox" "done" "" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_no_entry_for_pane "done on focused pane is suppressed" "$sandbox" "%5"
rm -rf "$sandbox"

# Case 3: pane is NOT focused (different tmux_pane), status=waiting → entry MUST appear.
sandbox="$(mktemp -d)"
run_hook_in_sandbox "$sandbox" "waiting" "permission_prompt" \
  "11" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%7" "%5"
assert_has_entry_for_pane "waiting on UNfocused pane still upserts" "$sandbox" "%7"
rm -rf "$sandbox"

# Case 4: running should always upsert regardless of focus (informational).
sandbox="$(mktemp -d)"
run_hook_in_sandbox "$sandbox" "running" "" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_has_entry_for_pane "running on focused pane still upserts" "$sandbox" "%5"
rm -rf "$sandbox"

# Case 5 (regression — coco-server stuck-running bug): a previously
# upserted `running` entry must be REMOVED when the focused-pane done
# fires, not just skipped. Otherwise the badge sits on `running`
# forever after the user already saw the pane finish.
sandbox="$(mktemp -d)"
seed_running_entry "$sandbox" "ccdc-test-sid" "10" \
  "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "@1" "%5"
MOCK_HOOK_STDIN='{"session_id":"ccdc-test-sid"}' \
  run_hook_in_sandbox "$sandbox" "done" "" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_no_entry_for_session "focused done removes prior running entry" "$sandbox" "ccdc-test-sid"
rm -rf "$sandbox"

# Case 6 (regression): same for waiting — focused waiting should clear
# any prior running entry too.
sandbox="$(mktemp -d)"
seed_running_entry "$sandbox" "ccdc-test-sid" "10" \
  "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "@1" "%5"
MOCK_HOOK_STDIN='{"session_id":"ccdc-test-sid"}' \
  run_hook_in_sandbox "$sandbox" "waiting" "permission_prompt" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_no_entry_for_session "focused waiting removes prior running entry" "$sandbox" "ccdc-test-sid"
rm -rf "$sandbox"

# Case 7 (cross-workspace bug the user just hit): tmux pane IS focused
# in its session (the sticky last-focused), but the user is actually
# on a different wezterm pane in another workspace. Done MUST upsert
# (not skip) — otherwise the badge silently swallows it.
sandbox="$(mktemp -d)"
MOCK_WEZTERM_FOCUSED_PANE_ID="999" \
  run_hook_in_sandbox "$sandbox" "done" "" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_has_entry_for_pane "done in other workspace still upserts (wezterm focus elsewhere)" "$sandbox" "%5"
rm -rf "$sandbox"

# Case 8: same case for waiting — cross-workspace must NOT skip.
sandbox="$(mktemp -d)"
MOCK_WEZTERM_FOCUSED_PANE_ID="999" \
  run_hook_in_sandbox "$sandbox" "waiting" "permission_prompt" \
  "10" "/tmp/tmux-1000/default" "wezterm_work_a_aaaaaaaaaa" "%5" "%5"
assert_has_entry_for_pane "waiting in other workspace still upserts (wezterm focus elsewhere)" "$sandbox" "%5"
rm -rf "$sandbox"

echo
if (( fail > 0 )); then
  echo "$pass passed, $fail failed"
  exit 1
fi
echo "$pass passed, $fail failed"
