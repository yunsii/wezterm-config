#!/usr/bin/env bash
# Low-frequency git-activity sampler for tab visibility.
#
# Focus/view events are diagnostic only. This script promotes a session
# when a git fingerprint changes on the configured main cwd or a *hot*
# linked worktree. The hot set is the same contract Alt+g uses:
# access_ledger_hot_worktree_paths = main ∪ (ledger recent_paths ∩ linked),
# falling back to all linked when the session has never been visited.
# Activity is always attributed to the base session derived from the
# item's main cwd — never from a worktree path alone.
#
# Fingerprints are stored per absolute path under
# sessions[<base>].git_fingerprints so main and worktrees do not thrash
# each other. The same pass also stamps last_access_ms from the
# access-ledger onto each base session so sticky ranking can mix a
# decayed visit bonus with activity_score.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/tab-stats-lib.sh"
# shellcheck disable=SC1091
. "$script_dir/tmux-worktree-lib.sh" 2>/dev/null || {
  tmux_worktree_session_name_for_path() { :; }
  tmux_worktree_list() { :; }
  tmux_worktree_abs_path() { printf '%s\n' "$1"; }
}
# shellcheck disable=SC1091
. "$script_dir/access-ledger-lib.sh" 2>/dev/null || {
  access_ledger_session_ms() { :; }
  access_ledger_hot_worktree_paths() {
    local main_cwd="${2:-}"
    [[ -n "$main_cwd" && -d "$main_cwd" ]] || return 0
    if declare -F tmux_worktree_linked_abs_paths >/dev/null 2>&1; then
      tmux_worktree_linked_abs_paths "$main_cwd"
    else
      printf '%s\n' "$main_cwd"
    fi
  }
}

workspace="${1:?missing workspace}"
mode="${2:-visible}"
stats_dir="$(tab_stats_dir)"
snapshot="$stats_dir/$(tab_stats_workspace_slug "$workspace")-items.json"

[[ -f "$snapshot" ]] || exit 0

hash_stream() {
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

git_fingerprint() {
  local cwd="$1"
  local head index_hash worktree_hash
  head="$(git -C "$cwd" rev-parse --verify HEAD 2>/dev/null || printf 'NOHEAD')"
  index_hash="$(git -C "$cwd" diff --cached --name-status -- 2>/dev/null | hash_stream)"
  worktree_hash="$(git -C "$cwd" diff --name-status -- 2>/dev/null | hash_stream)"
  printf 'head=%s;index=%s;worktree=%s' "$head" "$index_hash" "$worktree_hash"
}

fingerprint_part() {
  local fp="$1"
  local key="$2"
  printf '%s' "$fp" | tr ';' '\n' | awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }'
}

activity_delta() {
  local old_fp="$1"
  local new_fp="$2"
  local delta=0
  if [[ "$(fingerprint_part "$old_fp" head)" != "$(fingerprint_part "$new_fp" head)" ]]; then
    delta=$((delta + 100))
  fi
  if [[ "$(fingerprint_part "$old_fp" index)" != "$(fingerprint_part "$new_fp" index)" ]]; then
    delta=$((delta + 40))
  fi
  if [[ "$(fingerprint_part "$old_fp" worktree)" != "$(fingerprint_part "$new_fp" worktree)" ]]; then
    delta=$((delta + 20))
  fi
  printf '%s' "$delta"
}

# Prefer per-path map. Legacy last_git_fingerprint is consulted only for
# the item main cwd, and only when the per-path map has no entries yet
# (pre-upgrade single-fp rows). Once any path key exists, main must use
# its own map entry — otherwise a stale legacy mirror (or a previously
# overwritten one) falsely scores the main cwd on every tick.
old_fingerprint_for_path() {
  local session="$1"
  local path="$2"
  local main_cwd="$3"
  local fp=""
  local map_n=0
  fp="$(tab_stats_git_fingerprint_for_path "$workspace" "$session" "$path")"
  if [[ -n "$fp" ]]; then
    printf '%s' "$fp"
    return 0
  fi
  if [[ "$path" == "$main_cwd" ]]; then
    map_n="$(tab_stats_read "$workspace" \
      | jq -r --arg s "$session" \
          '((.sessions[$s].git_fingerprints // {}) | length)' 2>/dev/null || echo 0)"
    if [[ "$map_n" == "0" ]]; then
      tab_stats_git_fingerprint_for_path "$workspace" "$session" ""
    fi
  fi
}

# Hot paths for one item: delegates to access_ledger_hot_worktree_paths
# (shared with Alt+g's visit set). Attribution still uses base_session
# from the item cwd, not from each worktree path.
sample_paths_for_session() {
  local base_session="$1"
  local main_cwd="$2"
  access_ledger_hot_worktree_paths "$base_session" "$main_cwd"
}

sample_one_path() {
  local base_session="$1"
  local main_cwd="$2"
  local path="$3"
  local new_fp old_fp delta

  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  new_fp="$(git_fingerprint "$path")"
  [[ -n "$new_fp" ]] || return 0

  old_fp="$(old_fingerprint_for_path "$base_session" "$path" "$main_cwd")"
  if [[ -z "$old_fp" ]]; then
    tab_stats_set_git_fingerprint "$workspace" "$base_session" "$new_fp" "$path" || true
    return 0
  fi
  if [[ "$old_fp" == "$new_fp" ]]; then
    return 0
  fi

  delta="$(activity_delta "$old_fp" "$new_fp")"
  if (( delta > 0 )); then
    tab_stats_record_activity "$workspace" "$base_session" "$delta" "$new_fp" "$path" || true
  else
    tab_stats_set_git_fingerprint "$workspace" "$base_session" "$new_fp" "$path" || true
  fi
}

row_filter='.items[] | select(.cwd != null)'
if [[ "$mode" != "all" ]]; then
  row_filter='.items[] | select(.cwd != null and (.has_tab // false) == true)'
fi

# session_name -> 1 for every base session we resolved this pass (for
# access-ledger stamping even when no git delta fired).
declare -A sampled_sessions=()

while IFS=$'\t' read -r cwd _has_tab; do
  [[ -n "$cwd" && -d "$cwd" ]] || continue

  main_cwd="$(tmux_worktree_abs_path "$cwd" 2>/dev/null || printf '%s' "$cwd")"
  base_session="$(tmux_worktree_session_name_for_path "$workspace" "$main_cwd" 2>/dev/null || true)"
  [[ -n "$base_session" ]] || continue
  sampled_sessions["$base_session"]=1

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    sample_one_path "$base_session" "$main_cwd" "$path"
  done < <(sample_paths_for_session "$base_session" "$main_cwd")
done < <(jq -r "$row_filter | [.cwd, (.has_tab // false | tostring)] | @tsv" "$snapshot" 2>/dev/null)

# Stamp access-ledger recency onto base sessions so sticky ranking can
# mix visit bonus without Lua reading the WSL ledger over /mnt/c.
for base_session in "${!sampled_sessions[@]}"; do
  access_ms="$(access_ledger_session_ms "$base_session" 2>/dev/null || true)"
  if [[ "$access_ms" =~ ^[0-9]+$ ]] && (( access_ms > 0 )); then
    tab_stats_set_last_access "$workspace" "$base_session" "$access_ms" || true
  fi
done
