#!/usr/bin/env bash
# smoke.sh — end-to-end regression test for worktree-task CLI engine.
#
# Runs in an isolated /tmp git repo, exercises launch + reclaim through
# the `none` provider (no tmux/agent dependencies). Sandboxes HOME so the
# transcript-archive path can be exercised without touching the real
# user's ~/.claude/projects/.
#
# Cases:
#   1. happy-path: launch + reclaim creates and removes worktree, branch,
#      and metadata; no phantom worktree entry afterward.
#   2. dev-* prefix refusal: reclaim of a dev-* worktree refuses with a
#      clear error and leaves the worktree in place.
#
# Exit non-zero on any failure with a short trace.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKTREE_TASK="$REPO_ROOT/scripts/runtime/worktree/worktree-task"

[[ -x "$WORKTREE_TASK" ]] || {
  printf 'FAIL: worktree-task CLI not found or not executable: %s\n' "$WORKTREE_TASK" >&2
  exit 1
}

WORK_DIR="$(mktemp -d -t wt-smoke.XXXXXX)"
SANDBOX_HOME="$WORK_DIR/home"
mkdir -p "$SANDBOX_HOME"

# Persist the original HOME so we can hand it to subprocess git commands
# that need user identity (or anything else that legitimately reads the
# real HOME). The runtime under test uses $HOME for transcript paths only.
ORIGINAL_HOME="$HOME"

cleanup() {
  local rc=$?
  # Best-effort cleanup of any leftover worktrees in the throwaway repos.
  if [[ -d "$WORK_DIR" ]]; then
    find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -name 'origin*' 2>/dev/null | while read -r repo; do
      git -C "$repo" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / {print $2}' \
        | grep -v "^$repo$" \
        | while read -r wt; do
            git -C "$repo" worktree remove -f "$wt" >/dev/null 2>&1 || true
          done
    done
  fi
  rm -rf "$WORK_DIR"
  return $rc
}
trap cleanup EXIT

setup_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "smoke@example.invalid"
  git -C "$repo" config user.name "Smoke Test"
  echo init > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
}

PASS=0
FAIL=0

assert_pass() {
  printf '[ok ] %s\n' "$1"
  PASS=$((PASS + 1))
}

assert_fail() {
  printf '[FAIL] %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

# ---------- case 1: happy path ----------
case1_happy_path() {
  printf '\n=== case 1: happy path ===\n'

  local repo="$WORK_DIR/origin1"
  setup_repo "$repo"
  local slug="smoke-pr2-happy"
  local expect_wt="$WORK_DIR/.worktrees/origin1/$slug"

  HOME="$SANDBOX_HOME" \
  WEZTERM_CONFIG_REPO="$REPO_ROOT" \
  "$WORKTREE_TASK" launch \
    --cwd "$repo" \
    --title "$slug" \
    --base-ref HEAD \
    --provider none \
    --no-prompt \
    --no-attach >/dev/null \
    || { assert_fail "launch returned non-zero"; return 1; }

  [[ -d "$expect_wt" ]] && assert_pass "worktree dir present" \
    || { assert_fail "worktree dir missing: $expect_wt"; return 1; }

  git -C "$repo" branch --list "task/$slug" | grep -q "task/$slug" \
    && assert_pass "branch present" \
    || { assert_fail "branch task/$slug missing"; return 1; }

  HOME="$SANDBOX_HOME" \
  WEZTERM_CONFIG_REPO="$REPO_ROOT" \
  "$WORKTREE_TASK" reclaim \
    --cwd "$repo" \
    --task-slug "$slug" \
    --provider none >/dev/null \
    || { assert_fail "reclaim returned non-zero"; return 1; }

  [[ ! -d "$expect_wt" ]] && assert_pass "worktree dir gone" \
    || { assert_fail "worktree dir still present after reclaim"; return 1; }

  if git -C "$repo" branch --list "task/$slug" | grep -q "task/$slug"; then
    assert_fail "branch task/$slug still present after reclaim"
    return 1
  fi
  assert_pass "branch gone"

  if git -C "$repo" worktree list --porcelain | grep -q "$expect_wt"; then
    assert_fail "phantom worktree entry remains"
    return 1
  fi
  assert_pass "no phantom worktree entry"
}

# ---------- case 2: dev-* refusal ----------
case2_dev_refusal() {
  printf '\n=== case 2: dev-* prefix refusal ===\n'

  local repo="$WORK_DIR/origin2"
  setup_repo "$repo"
  local slug="dev-billing"
  local expect_wt="$WORK_DIR/.worktrees/origin2/$slug"

  HOME="$SANDBOX_HOME" \
  WEZTERM_CONFIG_REPO="$REPO_ROOT" \
  "$WORKTREE_TASK" launch \
    --cwd "$repo" \
    --title "$slug" \
    --base-ref HEAD \
    --provider none \
    --no-prompt \
    --no-attach >/dev/null \
    || { assert_fail "launch returned non-zero for dev-* slug"; return 1; }

  [[ -d "$expect_wt" ]] || { assert_fail "dev-* worktree not created"; return 1; }
  assert_pass "dev-* worktree created (launch is allowed)"

  # Reclaim must refuse with a recognizable message.
  local stderr_file="$WORK_DIR/case2-stderr"
  if HOME="$SANDBOX_HOME" \
     WEZTERM_CONFIG_REPO="$REPO_ROOT" \
     "$WORKTREE_TASK" reclaim \
       --cwd "$repo" \
       --task-slug "$slug" \
       --provider none >/dev/null 2>"$stderr_file"; then
    assert_fail "reclaim of $slug should have failed but succeeded"
    return 1
  fi
  assert_pass "reclaim of dev-* refused (non-zero exit)"

  if grep -qiE "long-lived|dev-billing" "$stderr_file"; then
    assert_pass "refusal message mentions long-lived/dev-billing"
  else
    assert_fail "refusal message unclear: $(cat "$stderr_file")"
    return 1
  fi

  [[ -d "$expect_wt" ]] && assert_pass "dev-* worktree still present after refused reclaim" \
    || { assert_fail "dev-* worktree was removed despite refusal"; return 1; }

  # Manual cleanup so case 3 starts clean.
  git -C "$repo" worktree remove -f "$expect_wt" >/dev/null 2>&1 || true
}

# ---------- case 3: transcript preservation ----------
# Reclaim intentionally leaves ~/.claude/projects/<escaped>/ in place so a
# later same-named worktree (rare but legitimate when reusing task types)
# can resume the prior conversation via `claude --continue`. /clear is the
# escape hatch when the resumed context isn't wanted.
case3_transcript_preserved() {
  printf '\n=== case 3: transcript preserved across reclaim ===\n'

  local repo="$WORK_DIR/origin3"
  setup_repo "$repo"
  local slug="task-resume"
  local expect_wt="$WORK_DIR/.worktrees/origin3/$slug"

  HOME="$SANDBOX_HOME" \
  WEZTERM_CONFIG_REPO="$REPO_ROOT" \
  "$WORKTREE_TASK" launch \
    --cwd "$repo" \
    --title "$slug" \
    --base-ref HEAD \
    --provider none \
    --no-prompt \
    --no-attach >/dev/null \
    || { assert_fail "launch failed"; return 1; }

  local escaped="${expect_wt//\//-}"
  local transcript_src="$SANDBOX_HOME/.claude/projects/$escaped"
  mkdir -p "$transcript_src"
  echo '{"role":"user","content":"hello"}' > "$transcript_src/dummy.jsonl"

  HOME="$SANDBOX_HOME" \
  WEZTERM_CONFIG_REPO="$REPO_ROOT" \
  "$WORKTREE_TASK" reclaim \
    --cwd "$repo" \
    --task-slug "$slug" \
    --provider none >/dev/null \
    || { assert_fail "reclaim failed"; return 1; }

  [[ -f "$transcript_src/dummy.jsonl" ]] && assert_pass "transcript file preserved at original path" \
    || { assert_fail "transcript dir/file disappeared after reclaim"; return 1; }

  [[ ! -d "$SANDBOX_HOME/.claude/projects/.archive" ]] && assert_pass "no .archive/ side-effect created" \
    || { assert_fail ".archive/ unexpectedly created — archive code may not be fully removed"; return 1; }
}

# ---------- run ----------
case1_happy_path
case2_dev_refusal
case3_transcript_preserved

printf '\n=== summary ===\n'
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo PASS smoke
