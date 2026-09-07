#!/usr/bin/env bash
set -u

guard_sandbox_paths() {
  local p="$1"
  if [[ -z "$p" || "$p" == /mnt/c/* ]]; then
    echo "SAFETY ABORT: sandbox path resolves to live state ($p)" >&2
    exit 99
  fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/runtime/tab-activity-sample.sh"
session_script="$repo_root/scripts/runtime/tmux-worktree/print-session-names.sh"

pass=0
fail=0
ok() { pass=$((pass+1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  \xe2\x9c\x97 %s\n' "$1"; }

sandbox="$(mktemp -d -t wezterm-tab-activity-XXXXXX)"
guard_sandbox_paths "$sandbox/wezterm-runtime"
mkdir -p "$sandbox/wezterm-runtime/state/tab-stats"
workdir="$sandbox/repo"

git init -q "$workdir"
git -C "$workdir" config user.email test@example.com
git -C "$workdir" config user.name Test
printf 'one\n' > "$workdir/file.txt"
git -C "$workdir" add file.txt
git -C "$workdir" commit -q -m initial

session="$(bash "$session_script" work "$workdir" | awk -F '\t' 'NR == 1 { print $2 }')"
snapshot="$sandbox/wezterm-runtime/state/tab-stats/work-items.json"
cat > "$snapshot" <<JSON
{
  "version": 1,
  "workspace": "work",
  "items": [
    { "cwd": "$workdir", "label": "repo", "has_tab": true }
  ]
}
JSON

run_sample() {
  env \
    WINDOWS_RUNTIME_STATE_WSL="$sandbox/wezterm-runtime" \
    WINDOWS_LOCALAPPDATA_WSL="$sandbox" \
    WINDOWS_USERPROFILE_WSL="$sandbox" \
    XDG_STATE_HOME="$sandbox" \
    WEZTERM_NO_PATH_CACHE=1 \
    bash "$script" work
}

printf '\xe2\x96\xb8 %s\n' 'tab activity sampler'

run_sample >/dev/null
score=$(jq -r --arg s "$session" '.sessions[$s].activity_score // "MISS"' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count=$(jq -r --arg s "$session" '.sessions[$s].activity_count // "MISS"' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
# Path-keyed map is the source of truth; legacy last_git_fingerprint may
# stay empty when the sampler always passes a cwd_key.
fp=$(jq -r --arg s "$session" '
  (.sessions[$s] // {}) as $row
  | if (($row.git_fingerprints // {}) | length) > 0 then
      (($row.git_fingerprints // {}) | to_entries[0].value)
    else ($row.last_git_fingerprint // "")
    end
' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
[[ "$score" == "0" ]] && ok "first sample writes baseline without score" \
  || no "baseline activity_score expected 0, got $score"
[[ "$count" == "0" ]] && ok "first sample does not increment activity_count" \
  || no "baseline activity_count expected 0, got $count"
[[ -n "$fp" ]] && ok "first sample stores git fingerprint" \
  || no "baseline fingerprint missing"

printf 'two\n' >> "$workdir/file.txt"
run_sample >/dev/null
score=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
score_ok=$(awk -v s="$score" 'BEGIN { print (s >= 19 && s <= 21) ? 1 : 0 }')
[[ "$score_ok" == "1" ]] && ok "worktree diff adds activity score" \
  || no "worktree diff score expected about 20, got $score"
[[ "$count" == "1" ]] && ok "worktree diff increments activity_count" \
  || no "activity_count expected 1, got $count"

git -C "$workdir" add file.txt
run_sample >/dev/null
score=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
score_ok=$(awk -v s="$score" 'BEGIN { print (s >= 79 && s <= 81) ? 1 : 0 }')
[[ "$score_ok" == "1" ]] && ok "index transition adds index + worktree score" \
  || no "index transition score expected about 80, got $score"
[[ "$count" == "2" ]] && ok "index transition increments activity_count" \
  || no "activity_count expected 2, got $count"

git -C "$workdir" commit -q -m update
run_sample >/dev/null
score=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
score_ok=$(awk -v s="$score" 'BEGIN { print (s >= 219 && s <= 221) ? 1 : 0 }')
[[ "$score_ok" == "1" ]] && ok "commit adds head + index transition score" \
  || no "commit score expected about 220, got $score"
[[ "$count" == "3" ]] && ok "commit increments activity_count" \
  || no "activity_count expected 3, got $count"

# --- linked worktree: first sight is baseline only (no false score) ---
linked="$sandbox/linked-wt"
git -C "$workdir" worktree add -q -b feature/sample-wt "$linked" >/dev/null 2>&1
score_pre=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count_pre=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
run_sample >/dev/null
score_base=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count_base=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
# Must not treat "missing per-path fp + legacy last_git_fingerprint" as a change.
score_same=$(awk -v a="$score_pre" -v b="$score_base" 'BEGIN { print (a == b) ? 1 : 0 }')
[[ "$score_same" == "1" && "$count_base" == "$count_pre" ]] \
  && ok "first sight of linked worktree is baseline-only (no false score)" \
  || no "linked baseline polluted score (pre=$score_pre/$count_pre post=$score_base/$count_base)"

# Commit only in the linked worktree → credit base session.
printf 'linked-only\n' > "$linked/file.txt"
git -C "$linked" add file.txt
git -C "$linked" commit -q -m 'linked worktree commit'
run_sample >/dev/null
score_after=$(jq -r --arg s "$session" '.sessions[$s].activity_score // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
count_after=$(jq -r --arg s "$session" '.sessions[$s].activity_count // 0' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
linked_abs="$(cd "$linked" && pwd -P 2>/dev/null || printf '%s' "$linked")"
fp_linked=$(jq -r --arg s "$session" --arg p "$linked" \
  '.sessions[$s].git_fingerprints[$p] // empty' \
  "$sandbox/wezterm-runtime/state/tab-stats/work.json")
fp_linked_abs=$(jq -r --arg s "$session" --arg p "$linked_abs" \
  '.sessions[$s].git_fingerprints[$p] // empty' \
  "$sandbox/wezterm-runtime/state/tab-stats/work.json")
delta=$(awk -v a="$score_after" -v b="$score_base" 'BEGIN { print a - b }')
delta_ok=$(awk -v d="$delta" 'BEGIN { print (d >= 99 && d <= 161) ? 1 : 0 }')
[[ "$delta_ok" == "1" ]] && ok "linked worktree commit credits base session (delta=$delta)" \
  || no "linked worktree delta expected ~100-160, got $delta (before=$score_base after=$score_after)"
[[ "$count_after" -gt "$count_base" ]] && ok "linked worktree increments activity_count" \
  || no "activity_count expected > $count_base, got $count_after"
if [[ -n "$fp_linked" || -n "$fp_linked_abs" ]]; then
  ok "linked path fingerprint stored under git_fingerprints"
else
  keys=$(jq -r --arg s "$session" '(.sessions[$s].git_fingerprints // {}) | keys[]' \
    "$sandbox/wezterm-runtime/state/tab-stats/work.json" 2>/dev/null | tr '\n' ' ')
  no "git_fingerprints missing linked path (have: $keys; tried $linked and $linked_abs)"
fi

orphan=$(jq -r '
  [.sessions | keys[] | select(test("feature|sample-wt|linked";"i"))] | length
' "$sandbox/wezterm-runtime/state/tab-stats/work.json")
[[ "$orphan" == "0" ]] && ok "linked worktree does not create orphan session rows" \
  || no "unexpected orphan session rows from worktree path: $orphan"

printf 'tab-activity sampler suite: %d passed, %d failed\n' "$pass" "$fail"
exit "$fail"
