#!/usr/bin/env bash
# Durable user-access ledger for navigation surfaces (Alt+g / Alt+x) and
# worktree focus restore after WezTerm / tmux restart.
#
# Signal is "user visited / selected", never pane output. Live tmux
# mirrors (@wezterm_user_interact_ts) remain the hot-path sort key when
# present; this file fills gaps after tmux death and feeds Alt+x.
#
# Schema (single JSON, atomic tmp+rename under flock):
# {
#   "version": 1,
#   "sessions": {
#     "<tmux_session>": {
#       "last_access_ms": 0,
#       "last_path": "/abs/worktree",
#       "recent_paths": [ {"path":"...", "ms":0}, ... ]  # capped MRU
#     }
#   },
#   "worktrees": {
#     "/abs/worktree": { "last_access_ms": 0, "session": "<tmux_session>" }
#   }
# }
#
# Fail-open: every helper returns 0 / empty on error so hooks never
# break the tmux server or picker open path.

# shellcheck disable=SC2034

ACCESS_LEDGER_RECENT_CAP="${ACCESS_LEDGER_RECENT_CAP:-8}"
ACCESS_LEDGER_VERSION=1

access_ledger_path() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$lib_dir/wsl-runtime-paths-lib.sh"
  printf '%s' "$WSL_ACCESS_LEDGER_FILE"
}

access_ledger_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s\n' "$(( ${EPOCHREALTIME//./} / 1000 ))"
    return 0
  fi
  date +%s%3N 2>/dev/null || date +%s000
}

# Sanitize session / path for jq --arg use (already literal; no-op).
# Touch session + worktree. Optional ms defaults to now.
# Usage: access_ledger_touch <session> <worktree_path> [ms]
access_ledger_touch() {
  local session_name="${1:-}"
  local worktree_path="${2:-}"
  local ms="${3:-}"
  local ledger_path=""
  local lock_path=""
  local tmp=""
  local cap="$ACCESS_LEDGER_RECENT_CAP"

  [[ -n "$session_name" && -n "$worktree_path" ]] || return 0
  if [[ ! "$ms" =~ ^[0-9]+$ ]]; then
    ms="$(access_ledger_now_ms)"
  fi
  [[ "$ms" =~ ^[0-9]+$ ]] || return 0

  ledger_path="$(access_ledger_path)"
  [[ -n "$ledger_path" ]] || return 0
  mkdir -p "${ledger_path%/*}" 2>/dev/null || return 0
  lock_path="${ledger_path}.lock"
  tmp="${ledger_path}.tmp.$$"

  (
    flock -x 9 || exit 0
    if [[ ! -s "$ledger_path" ]]; then
      printf '{"version":%s,"sessions":{},"worktrees":{}}\n' \
        "$ACCESS_LEDGER_VERSION" >"$ledger_path" 2>/dev/null || exit 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
      exit 0
    fi
    jq -c \
      --arg sess "$session_name" \
      --arg path "$worktree_path" \
      --argjson ms "$ms" \
      --argjson cap "$cap" '
      .version = (.version // 1)
      | .sessions = (.sessions // {})
      | .worktrees = (.worktrees // {})
      | .sessions[$sess] = (
          (.sessions[$sess] // {})
          | .last_access_ms = $ms
          | .last_path = $path
          | .recent_paths = (
              (
                [ {path: $path, ms: $ms} ]
                + (
                    ((.recent_paths // []) | map(select(.path != $path)))
                  )
              ) | .[0:$cap]
            )
        )
      | .worktrees[$path] = {
          last_access_ms: $ms,
          session: $sess
        }
      ' "$ledger_path" >"$tmp" 2>/dev/null || exit 0
    mv -f "$tmp" "$ledger_path" 2>/dev/null || rm -f "$tmp"
  ) 9>"$lock_path" 2>/dev/null || true

  return 0
}

# Print last_access_ms for a session (or empty).
access_ledger_session_ms() {
  local session_name="${1:-}"
  local ledger_path=""
  [[ -n "$session_name" ]] || return 0
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg s "$session_name" \
    '(.sessions[$s].last_access_ms // empty)|tostring' \
    "$ledger_path" 2>/dev/null || true
}

# Print last_path for a session (or empty).
access_ledger_session_last_path() {
  local session_name="${1:-}"
  local ledger_path=""
  [[ -n "$session_name" ]] || return 0
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg s "$session_name" \
    '.sessions[$s].last_path // empty' \
    "$ledger_path" 2>/dev/null || true
}

# Print last_access_ms for a worktree path (or empty).
access_ledger_worktree_ms() {
  local worktree_path="${1:-}"
  local ledger_path=""
  [[ -n "$worktree_path" ]] || return 0
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg p "$worktree_path" \
    '(.worktrees[$p].last_access_ms // empty)|tostring' \
    "$ledger_path" 2>/dev/null || true
}

# Print recent worktree paths for a session, most recent first (one per line).
# Usage: access_ledger_session_recent_paths <session> [limit]
access_ledger_session_recent_paths() {
  local session_name="${1:-}"
  local limit="${2:-$ACCESS_LEDGER_RECENT_CAP}"
  local ledger_path=""
  [[ -n "$session_name" ]] || return 0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit="$ACCESS_LEDGER_RECENT_CAP"
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg s "$session_name" --argjson n "$limit" '
    ((.sessions[$s].recent_paths // [])[:$n][] | .path // empty)
  ' "$ledger_path" 2>/dev/null || true
}

# Emit TSV: session_name \t last_access_ms for every known session.
access_ledger_all_session_ms_tsv() {
  local ledger_path=""
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    (.sessions // {})
    | to_entries[]
    | select((.value.last_access_ms // 0) > 0)
    | [.key, (.value.last_access_ms|tostring)] | @tsv
  ' "$ledger_path" 2>/dev/null || true
}

# Emit TSV: path \t last_access_ms for every known worktree.
access_ledger_all_worktree_ms_tsv() {
  local ledger_path=""
  ledger_path="$(access_ledger_path)"
  [[ -s "$ledger_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '
    (.worktrees // {})
    | to_entries[]
    | select((.value.last_access_ms // 0) > 0)
    | [.key, (.value.last_access_ms|tostring)] | @tsv
  ' "$ledger_path" 2>/dev/null || true
}

# Visit clock in epoch seconds for one worktree path — same contract
# Alt+g uses to rank rows (user visit, not agent output):
#   1. live interact ts (caller passes @wezterm_user_interact_ts when known)
#   2. durable access-ledger worktree stamp
#   3. directory birth time, else mtime (never-visited兜底)
#
# Usage:
#   access_ledger_visit_ts_s <path> [live_interact_s]
#   access_ledger_visit_ts_s <path> <live_interact_s> <ledger_s>
#
# Pass ledger_s (epoch seconds, may be 0) when the caller already bulk-
# loaded access_ledger_all_worktree_ms_tsv — avoids N jq reads on the
# Alt+g hot path. Omit the third arg to look up the ledger per call.
access_ledger_visit_ts_s() {
  local path="${1:-}"
  local live="${2:-0}"
  local best=0
  local ledger_ms=0
  local ledger_s=0
  local created_s birth_s mtime_s

  [[ -n "$path" ]] || { printf '0\n'; return 0; }
  [[ "$live" =~ ^[0-9]+$ ]] || live=0
  best=$live

  if [[ -n "${3+x}" ]]; then
    ledger_s="${3:-0}"
    [[ "$ledger_s" =~ ^[0-9]+$ ]] || ledger_s=0
  else
    ledger_ms="$(access_ledger_worktree_ms "$path" 2>/dev/null || true)"
    if [[ "$ledger_ms" =~ ^[0-9]+$ ]] && (( ledger_ms > 0 )); then
      ledger_s=$(( ledger_ms / 1000 ))
    else
      ledger_s=0
    fi
  fi
  if (( ledger_s > best )); then
    best=$ledger_s
  fi

  if (( best == 0 )) && [[ -d "$path" ]]; then
    created_s="$(stat -c '%W %Y' "$path" 2>/dev/null || true)"
    birth_s="${created_s%% *}"
    mtime_s="${created_s##* }"
    if [[ "$birth_s" =~ ^[0-9]+$ ]] && (( birth_s > 0 )); then
      best=$birth_s
    elif [[ "$mtime_s" =~ ^[0-9]+$ ]] && (( mtime_s > 0 )); then
      best=$mtime_s
    fi
  fi

  printf '%s\n' "$best"
}

# Hot worktree paths for a managed base session — shared by the
# tab-activity sampler and any caller that wants Alt+g's "where did the
# user actually go" set instead of the full git worktree list.
#
# Emits absolute paths, main first:
#   1. always the item main cwd
#   2. ledger recent_paths ∩ currently linked worktrees
#   3. if (2) is empty → all linked paths (cold bootstrap; same as Alt+g
#      falling back to git-list order when nothing has been visited)
#
# Requires the caller to have sourced tmux-worktree-lib.sh (uses
# tmux_worktree_linked_abs_paths / tmux_worktree_abs_path). Soft-degrades
# to main + recent_paths that still exist on disk when those helpers are
# missing.
#
# Usage: access_ledger_hot_worktree_paths <session> <main_cwd> [limit]
access_ledger_hot_worktree_paths() {
  local session_name="${1:-}"
  local main_cwd="${2:-}"
  local limit="${3:-$ACCESS_LEDGER_RECENT_CAP}"
  local abs_main=""
  local path=""
  local rp=""
  local rp_abs=""
  local recent_hit=0
  local seen=$'\n'

  [[ -n "$session_name" && -n "$main_cwd" ]] || return 0

  if declare -F tmux_worktree_abs_path >/dev/null 2>&1; then
    abs_main="$(tmux_worktree_abs_path "$main_cwd" 2>/dev/null || printf '%s' "$main_cwd")"
  else
    abs_main="$main_cwd"
  fi
  [[ -n "$abs_main" && -d "$abs_main" ]] || return 0

  declare -A linked=()
  if declare -F tmux_worktree_linked_abs_paths >/dev/null 2>&1; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      linked["$path"]=1
    done < <(tmux_worktree_linked_abs_paths "$abs_main")
  elif declare -F tmux_worktree_list >/dev/null 2>&1; then
    local label branch
    while IFS=$'\t' read -r label path branch; do
      [[ -n "$path" && -d "$path" ]] || continue
      if declare -F tmux_worktree_abs_path >/dev/null 2>&1; then
        path="$(tmux_worktree_abs_path "$path" 2>/dev/null || printf '%s' "$path")"
      fi
      linked["$path"]=1
    done < <(tmux_worktree_list "$abs_main" 2>/dev/null || true)
  fi
  linked["$abs_main"]=1

  emit() {
    local p="$1"
    case "$seen" in
      *$'\n'"$p"$'\n'*) return 0 ;;
    esac
    seen="${seen}${p}"$'\n'
    printf '%s\n' "$p"
  }

  emit "$abs_main"

  while IFS= read -r rp; do
    [[ -n "$rp" ]] || continue
    if declare -F tmux_worktree_abs_path >/dev/null 2>&1; then
      rp_abs="$(tmux_worktree_abs_path "$rp" 2>/dev/null || printf '%s' "$rp")"
    else
      rp_abs="$rp"
    fi
    [[ -n "$rp_abs" && -d "$rp_abs" ]] || continue
    if [[ -n "${linked[$rp_abs]:-}" ]]; then
      recent_hit=1
      emit "$rp_abs"
    fi
  done < <(access_ledger_session_recent_paths "$session_name" "$limit")

  if (( recent_hit == 0 )); then
    for path in "${!linked[@]}"; do
      emit "$path"
    done
  fi
}
