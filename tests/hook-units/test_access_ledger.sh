#!/usr/bin/env bash
# Unit tests for scripts/runtime/access-ledger-lib.sh
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="$repo_root/scripts/runtime/access-ledger-lib.sh"

pass=0
fail=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n    got:  %q\n    want: %q\n' "$name" "$got" "$want"
  fi
}

assert_contains() {
  local name="$1" hay="$2" needle="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s\n    haystack missing %q\n' "$name" "$needle"
  fi
}

sandbox="$(mktemp -d -t access-ledger-test.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT
export XDG_STATE_HOME="$sandbox/xdg"
mkdir -p "$XDG_STATE_HOME"

# shellcheck disable=SC1090
source "$lib"

ledger="$(access_ledger_path)"
assert_contains "ledger path under xdg state" "$ledger" "wezterm-runtime/state/access-ledger.json"

access_ledger_touch "sess-a" "/tmp/wt-a" 1000
access_ledger_touch "sess-a" "/tmp/wt-b" 2000
access_ledger_touch "sess-b" "/tmp/wt-c" 1500

got="$(access_ledger_session_ms sess-a)"
assert_eq "session a last ms" "$got" "2000"

got="$(access_ledger_session_last_path sess-a)"
assert_eq "session a last path" "$got" "/tmp/wt-b"

got="$(access_ledger_worktree_ms /tmp/wt-a)"
assert_eq "worktree a ms retained" "$got" "1000"

recent="$(access_ledger_session_recent_paths sess-a 5 | tr '\n' ' ')"
assert_contains "recent paths MRU head" "$recent" "/tmp/wt-b"
assert_contains "recent paths keep older" "$recent" "/tmp/wt-a"

tsv="$(access_ledger_all_session_ms_tsv)"
assert_contains "all sessions tsv has a" "$tsv" $'sess-a\t2000'
assert_contains "all sessions tsv has b" "$tsv" $'sess-b\t1500'

# Cap: touching more than ACCESS_LEDGER_RECENT_CAP keeps newest only.
ACCESS_LEDGER_RECENT_CAP=2
access_ledger_touch "sess-a" "/tmp/wt-d" 3000
access_ledger_touch "sess-a" "/tmp/wt-e" 4000
recent="$(access_ledger_session_recent_paths sess-a 10)"
lines="$(printf '%s\n' "$recent" | grep -c . || true)"
assert_eq "recent cap enforced" "$lines" "2"
assert_contains "newest path kept" "$recent" "/tmp/wt-e"

# Visit clock: live wins over older ledger; ledger wins over bare path
# with no live stamp when we pass an explicit ledger_s.
got="$(access_ledger_visit_ts_s "/tmp/wt-e" 10 50)"
assert_eq "visit clock takes max(live, ledger)" "$got" "50"
got="$(access_ledger_visit_ts_s "/tmp/wt-e" 90 50)"
assert_eq "visit clock live can beat ledger" "$got" "90"

# Hot paths: with tmux-worktree helpers + a real repo family.
# shellcheck disable=SC1091
source "$repo_root/scripts/runtime/tmux-worktree-lib.sh"
repo="$sandbox/repo"
git init -q "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T
printf 'x\n' > "$repo/f"
git -C "$repo" add f && git -C "$repo" commit -q -m i
wt_hot="$sandbox/wt-hot"
wt_cold="$sandbox/wt-cold"
git -C "$repo" worktree add -q -b hot "$wt_hot" >/dev/null 2>&1
git -C "$repo" worktree add -q -b cold "$wt_cold" >/dev/null 2>&1
repo_abs="$(cd "$repo" && pwd -P)"
wt_hot_abs="$(cd "$wt_hot" && pwd -P)"
wt_cold_abs="$(cd "$wt_cold" && pwd -P)"
sess="$(tmux_worktree_session_name_for_path work "$repo_abs")"

# No ledger visits → bootstrap emits all linked.
hot_all="$(access_ledger_hot_worktree_paths "$sess" "$repo_abs" | tr '\n' ' ')"
assert_contains "bootstrap includes main" "$hot_all" "$repo_abs"
assert_contains "bootstrap includes hot wt" "$hot_all" "$wt_hot_abs"
assert_contains "bootstrap includes cold wt" "$hot_all" "$wt_cold_abs"

# After visiting only hot → main ∪ hot, not cold.
access_ledger_touch "$sess" "$wt_hot_abs" 5000
hot_set="$(access_ledger_hot_worktree_paths "$sess" "$repo_abs")"
assert_contains "hot set keeps main" "$hot_set" "$repo_abs"
assert_contains "hot set keeps visited wt" "$hot_set" "$wt_hot_abs"
if printf '%s\n' "$hot_set" | grep -qxF "$wt_cold_abs"; then
  fail=$((fail + 1))
  printf '  FAIL  hot set should omit cold wt\n'
else
  pass=$((pass + 1))
  printf '  PASS  hot set omits unvisited cold wt\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
