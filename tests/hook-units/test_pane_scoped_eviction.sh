#!/usr/bin/env bash
# Failing tests for pane-scoped eviction. The earlier eviction key was
# (tmux_socket, tmux_session) which incorrectly archived a sibling pane's
# live entry whenever any pane in the same tmux session triggered
# /clear (SessionStart matcher=clear → emit-agent-status.sh pane-evict)
# or a UserPromptSubmit. Multi-pane tmux sessions hosting more than one
# Claude (split-pane worktree setups) need the eviction scoped to the
# triggering pane only.
#
# Drive: scripts/dev/test-lua-units.sh (or run this file directly).
set -u

guard_sandbox_paths() {
  local p="$1"
  if [[ -z "$p" || "$p" == /mnt/c/* ]]; then
    echo "SAFETY ABORT: sandbox path resolves to live state ($p)" >&2
    exit 99
  fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="$repo_root/scripts/runtime/attention-state-lib.sh"

pass=0
fail=0

# Per-test sandbox: source the lib with overrides that resolve
# attention_state_path to a tmpdir, so the tests never touch the user's
# live attention.json.
run_in_sandbox() {
  local sandbox="$1"; shift
  guard_sandbox_paths "$sandbox/wezterm-runtime"
  mkdir -p "$sandbox/wezterm-runtime/state/agent-attention"
  env \
    HOME="$sandbox" XDG_STATE_HOME="$sandbox/.local/state" \
    WINDOWS_RUNTIME_STATE_WSL="$sandbox/wezterm-runtime" \
    WINDOWS_LOCALAPPDATA_WSL="$sandbox" \
    WINDOWS_USERPROFILE_WSL="$sandbox" \
    WEZTERM_NO_PATH_CACHE=1 \
    bash -c '
      set -u
      . "$1"
      shift
      "$@"
    ' _bash "$lib" "$@"
}

# Manifest helpers — write a known shape directly so tests can assert
# precise inputs/outputs without going through the hook layer.
seed_state() {
  local sandbox="$1" payload="$2"
  guard_sandbox_paths "$sandbox/wezterm-runtime"
  mkdir -p "$sandbox/wezterm-runtime/state/agent-attention"
  printf '%s\n' "$payload" \
    > "$sandbox/wezterm-runtime/state/agent-attention/attention.json"
}

state_file_in() {
  printf '%s/wezterm-runtime/state/agent-attention/attention.json' "$1"
}

assert_has_entry() {
  local label="$1" sandbox="$2" sid="$3"
  local f
  f="$(state_file_in "$sandbox")"
  if jq -e --arg s "$sid" '.entries[$s]' "$f" >/dev/null 2>&1; then
    echo "  ✓ $label"; pass=$((pass+1))
  else
    echo "  ✗ $label"
    echo "    expected entries[$sid] but state was:"
    jq '.entries' "$f" 2>/dev/null | sed 's/^/    /'
    fail=$((fail+1))
  fi
}

assert_no_entry() {
  local label="$1" sandbox="$2" sid="$3"
  local f
  f="$(state_file_in "$sandbox")"
  if jq -e --arg s "$sid" '.entries[$s]' "$f" >/dev/null 2>&1; then
    echo "  ✗ $label"
    echo "    entries[$sid] still in state:"
    jq --arg s "$sid" '.entries[$s]' "$f" 2>/dev/null | sed 's/^/    /'
    fail=$((fail+1))
  else
    echo "  ✓ $label"; pass=$((pass+1))
  fi
}

assert_recent_has_sid() {
  local label="$1" sandbox="$2" sid="$3"
  local f
  f="$(state_file_in "$sandbox")"
  if jq -e --arg s "$sid" '.recent | any(.session_id == $s)' "$f" >/dev/null 2>&1; then
    echo "  ✓ $label"; pass=$((pass+1))
  else
    echo "  ✗ $label"
    echo "    expected recent[] to contain $sid but recent was:"
    jq '.recent' "$f" 2>/dev/null | sed 's/^/    /'
    fail=$((fail+1))
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  ✓ $label"; pass=$((pass+1))
  else
    echo "  ✗ $label"
    echo "    expected=$expected actual=$actual"
    fail=$((fail+1))
  fi
}

socket="/tmp/tmux-1000/default"
session="wezterm_config_x_1f5ee8662c"

echo "▸ attention_state_evict_session: pane-scoped"

# Case 1: two panes in the same tmux session, /clear in pane A must
# only evict pane A's entry. Pane B's entry must remain in entries[].
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-A":{"session_id":"sid-A","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%1","status":"running","reason":"A","ts":1000},
    "sid-B":{"session_id":"sid-B","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%3","status":"running","reason":"B","ts":1000}
  },
  "recent":[]
}'
# /clear in pane A spawns a fresh sid (`new-sid`) and pane-evict keeps
# only that one — A's old sid-A should be evicted, B's sid-B must stay.
run_in_sandbox "$sandbox" attention_state_evict_session "$socket" "$session" "new-sid" "%1"
assert_no_entry "/clear in pane A evicts sid-A" "$sandbox" "sid-A"
assert_has_entry "/clear in pane A keeps sid-B (sibling pane)" "$sandbox" "sid-B"
assert_recent_has_sid "evicted sid-A landed in recent[]" "$sandbox" "sid-A"
rm -rf "$sandbox"

# Case 2: empty tmux_pane → fallback to (socket, session) full sweep
# (preserves pre-fix behavior for legacy callers).
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-A":{"session_id":"sid-A","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%1","status":"running","reason":"A","ts":1000},
    "sid-B":{"session_id":"sid-B","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%3","status":"running","reason":"B","ts":1000}
  },
  "recent":[]
}'
run_in_sandbox "$sandbox" attention_state_evict_session "$socket" "$session" "new-sid" ""
assert_no_entry "empty tmux_pane: sid-A evicted (fallback sweep)" "$sandbox" "sid-A"
assert_no_entry "empty tmux_pane: sid-B evicted (fallback sweep)" "$sandbox" "sid-B"
rm -rf "$sandbox"

# Case 3: different tmux session must be untouched regardless of pane.
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-A":{"session_id":"sid-A","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%1","status":"running","reason":"A","ts":1000},
    "sid-other":{"session_id":"sid-other","wezterm_pane_id":"4","tmux_socket":"'"$socket"'","tmux_session":"wezterm_other_y_aaaa","tmux_window":"@10","tmux_pane":"%18","status":"running","reason":"other","ts":1000}
  },
  "recent":[]
}'
run_in_sandbox "$sandbox" attention_state_evict_session "$socket" "$session" "new-sid" "%1"
assert_no_entry "/clear targets only its own session: sid-A goes" "$sandbox" "sid-A"
assert_has_entry "/clear in different session is untouched" "$sandbox" "sid-other"
rm -rf "$sandbox"

echo
echo "▸ archive_into_recent: per-pane dedup keeps siblings"

# Case 4: when both pane A and pane B archive to recent[], both must
# survive the (socket, session, pane) dedup. Pre-fix code keyed only on
# (socket, session), so the newer archive overwrote the older one and
# erased a still-active sibling pane's history from the picker.
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-A":{"session_id":"sid-A","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%1","status":"running","reason":"A","ts":1000},
    "sid-B":{"session_id":"sid-B","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%3","status":"running","reason":"B","ts":1000}
  },
  "recent":[]
}'
# Archive A first (pane %1), then archive B (pane %3). Both should
# survive; older fix would have lost sid-A when sid-B archived.
run_in_sandbox "$sandbox" attention_state_evict_session "$socket" "$session" "keep-noone" "%1"
run_in_sandbox "$sandbox" attention_state_evict_session "$socket" "$session" "keep-noone" "%3"
assert_recent_has_sid "recent[] keeps pane %1 archive (sid-A)" "$sandbox" "sid-A"
assert_recent_has_sid "recent[] keeps pane %3 archive (sid-B) alongside" "$sandbox" "sid-B"
rm -rf "$sandbox"

echo
echo "▸ attention_state_upsert: pane-scoped same-pane eviction"

# Case 5: upsert in pane A must NOT evict pane B's entry on the same
# tmux session. This is the latent twin of Case 1 — same root cause.
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-B":{"session_id":"sid-B","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%3","status":"running","reason":"B","ts":1000}
  },
  "recent":[]
}'
run_in_sandbox "$sandbox" attention_state_upsert \
  "sid-A" "1" "$socket" "$session" "@1" "%1" "running" "A reason" "master"
assert_has_entry "upsert sid-A on pane %1 lands" "$sandbox" "sid-A"
assert_has_entry "upsert sid-A keeps sid-B on pane %3 (sibling pane)" "$sandbox" "sid-B"
rm -rf "$sandbox"

# Case 6: upsert in same pane (replacing a stale tenant) DOES evict
# the prior session_id on the same pane — same-pane /clear with a new
# uuid should still de-dup.
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{
  "version":1,
  "entries":{
    "sid-old":{"session_id":"sid-old","wezterm_pane_id":"1","tmux_socket":"'"$socket"'","tmux_session":"'"$session"'","tmux_window":"@1","tmux_pane":"%1","status":"running","reason":"old","ts":1000}
  },
  "recent":[]
}'
run_in_sandbox "$sandbox" attention_state_upsert \
  "sid-new" "1" "$socket" "$session" "@1" "%1" "running" "new" "master"
assert_has_entry "new sid lands on pane" "$sandbox" "sid-new"
assert_no_entry "old sid on same pane gets evicted" "$sandbox" "sid-old"
assert_recent_has_sid "evicted same-pane sid lands in recent[]" "$sandbox" "sid-old"
rm -rf "$sandbox"

echo
echo "▸ attention_state_upsert: sticky last_user_prompt / agent_name / window_name"

# Case 7: Stop overwrites reason with end_turn but must keep the last
# real user prompt + agent session name so Alt+/ recent rows stay useful.
sandbox="$(mktemp -d)"
seed_state "$sandbox" '{"version":1,"entries":{},"recent":[]}'
run_in_sandbox "$sandbox" attention_state_upsert \
  "sid-p" "1" "$socket" "$session" "@2" "%5" "running" "fix the i18n scripts" "master" "" \
  "fix the i18n scripts" "dev-ci-63" "dev-ci"
sf="$(state_file_in "$sandbox")"
lup="$(jq -r '.entries["sid-p"].last_user_prompt // empty' "$sf")"
an="$(jq -r '.entries["sid-p"].agent_name // empty' "$sf")"
wn="$(jq -r '.entries["sid-p"].tmux_window_name // empty' "$sf")"
assert_eq "running stores last_user_prompt" "$lup" "fix the i18n scripts"
assert_eq "running stores agent_name" "$an" "dev-ci-63"
assert_eq "running stores tmux_window_name" "$wn" "dev-ci"

run_in_sandbox "$sandbox" attention_state_upsert \
  "sid-p" "1" "$socket" "$session" "@2" "%5" "done" "end_turn" "master" "" "" "" ""
lup="$(jq -r '.entries["sid-p"].last_user_prompt // empty' "$sf")"
an="$(jq -r '.entries["sid-p"].agent_name // empty' "$sf")"
wn="$(jq -r '.entries["sid-p"].tmux_window_name // empty' "$sf")"
reason="$(jq -r '.entries["sid-p"].reason // empty' "$sf")"
assert_eq "done keeps last_user_prompt" "$lup" "fix the i18n scripts"
assert_eq "done keeps agent_name" "$an" "dev-ci-63"
assert_eq "done keeps tmux_window_name" "$wn" "dev-ci"
assert_eq "done still records stop reason" "$reason" "end_turn"

run_in_sandbox "$sandbox" attention_state_remove "sid-p"
lup="$(jq -r '(.recent // []) | map(select(.session_id=="sid-p")) | .[0].last_user_prompt // empty' "$sf")"
an="$(jq -r '(.recent // []) | map(select(.session_id=="sid-p")) | .[0].agent_name // empty' "$sf")"
assert_eq "archive preserves last_user_prompt" "$lup" "fix the i18n scripts"
assert_eq "archive preserves agent_name" "$an" "dev-ci-63"
rm -rf "$sandbox"

echo
if (( fail > 0 )); then
  echo "$pass passed, $fail failed"
  exit 1
fi
echo "$pass passed, $fail failed"
