#!/usr/bin/env bash
# Shared state helpers for the agent-attention feature.
#
# State file layout (JSON):
#   {
#     "version": 1,
#     "entries": {
#       "<session_id>": {
#         "session_id":     "<string>",
#         "wezterm_pane_id":"<string>",
#         "tmux_socket":    "<string>",
#         "tmux_session":   "<string>",
#         "tmux_window":    "<string>",   -- e.g. "@5"
#         "tmux_pane":      "<string>",   -- e.g. "%12"
#         "status":         "running" | "waiting" | "done",
#         "reason":         "<short text>",
#         "git_branch":     "<string>",
#         "ts":             <epoch ms>
#       }
#     },
#     "recent": [
#       {
#         "session_id", "wezterm_pane_id",
#         "tmux_socket", "tmux_session", "tmux_window", "tmux_pane",
#         "git_branch",
#         "last_reason":  "<text at archive time>",
#         "last_status":  "running" | "waiting" | "done",
#         "live_ts":      <epoch ms when entry last lived>,
#         "archived_ts":  <epoch ms when entry was archived>
#       }
#     ]
#   }
#
# `recent[]` stores tombstones for sessions that left .entries via any of
# the five exit paths (same-pane eviction, evict_pane, --forget, TTL
# prune, --clear-all). Dedup key is (session_id, tmux_socket, tmux_session,
# tmux_pane); cap is 50 entries; TTL is 7 days. Active state in `.entries`
# is the source of truth — picker dedups recent against active by
# session_id (active wins).
#
# Sourced by:
#   scripts/claude-hooks/emit-agent-status.sh  (writer)
#   scripts/runtime/attention-jump.sh          (reader / consumer)

set -u

# Source paths-lib once at lib-load time. The previous shape sourced it
# inside attention_state_path on every call (parsed ~150 lines of bash
# 3+ times per menu.sh invocation). Sourcing here lifts that work to the
# single source point in the parent script.
__ATTENTION_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$__ATTENTION_STATE_LIB_DIR/windows-runtime-paths-lib.sh"

# Cached state path. Resolved on first call and reused — saves a wslpath /
# windows_runtime_detect_paths re-evaluation per call. Callers invalidate
# by unsetting this var (the bench harness does not, since the path is
# stable per-machine).
__ATTENTION_STATE_PATH_CACHED=""

attention_state_path() {
  if [[ -n "$__ATTENTION_STATE_PATH_CACHED" ]]; then
    printf '%s' "$__ATTENTION_STATE_PATH_CACHED"
    return 0
  fi
  if windows_runtime_detect_paths 2>/dev/null; then
    __ATTENTION_STATE_PATH_CACHED="$WINDOWS_RUNTIME_STATE_WSL/state/agent-attention/attention.json"
  else
    local state_root="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
    __ATTENTION_STATE_PATH_CACHED="$state_root/state/agent-attention/attention.json"
  fi
  printf '%s' "$__ATTENTION_STATE_PATH_CACHED"
}

attention_state_lock_path() {
  local path
  path="$(attention_state_path)"
  printf '%s.lock' "$path"
}

# Sibling of attention.json. Written by `attention.write_live_snapshot` on
# every Alt+/ keypress; consumed by tmux-attention-picker.sh to label rows
# without paying for a `wezterm.exe cli list` round-trip from the popup pty.
attention_live_panes_path() {
  local state_path
  state_path="$(attention_state_path)"
  printf '%s/live-panes.json' "${state_path%/*}"
}

attention_state_init() {
  local path dir
  path="$(attention_state_path)"
  dir="${path%/*}"
  mkdir -p "$dir"
  if [[ ! -f "$path" ]]; then
    printf '%s\n' '{"version":1,"entries":{},"recent":[]}' > "$path"
  fi
}

# Recent archive bookkeeping. Cap and TTL apply at every archive call so
# the array stays bounded even if the picker never opens. 7 days mirrors
# how long a user might reasonably want to recall a previous session.
ATTENTION_RECENT_CAP=50
ATTENTION_RECENT_TTL_MS=604800000

# jq prelude that defines `archive_into_recent($entries; $now; $cap; $ttl)`
# so each writer can compose `... | archive_into_recent(...)` into its own
# pipeline. Implemented as a string constant rather than a here-doc fork
# so the writers stay one jq invocation.
__ATTENTION_RECENT_DEF='
def archive_into_recent($to_archive; $now; $cap; $ttl):
  ($to_archive
   | map(select((.session_id // "") != ""))
   | map({
       session_id,
       wezterm_pane_id: (.wezterm_pane_id // ""),
       tmux_socket: (.tmux_socket // ""),
       tmux_session: (.tmux_session // ""),
       tmux_window: (.tmux_window // ""),
       tmux_pane: (.tmux_pane // ""),
       git_branch: (.git_branch // ""),
       last_reason: (.reason // ""),
       last_status: (.status // ""),
       live_ts: (.ts // $now),
       archived_ts: $now
     })) as $new_recents
  | .recent = (
      ($new_recents + (.recent // []))
      | group_by([.session_id, .tmux_socket, .tmux_session, .tmux_pane])
      | map(max_by(.archived_ts))
      | sort_by(-.archived_ts)
      | map(select(.archived_ts >= ($now - $ttl)))
      | .[0:$cap]
    );
'

attention_state_now_ms() {
  date +%s%3N
}

attention_state_read() {
  local path
  path="$(attention_state_path)"
  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' '{"version":1,"entries":{}}'
  fi
}

# atomic write via tmp + rename. Caller holds flock.
attention_state_write() {
  local payload="$1" path tmp
  path="$(attention_state_path)"
  tmp="${path}.tmp.$$"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$path"
}

attention_state_upsert() {
  local session_id="$1" wezterm_pane="$2" tmux_socket="$3" tmux_session="$4"
  local tmux_window="$5" tmux_pane="$6" status="$7" reason="$8" git_branch="${9:-}"
  local ts; ts="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    # One tmux pane hosts at most one active attention entry, so drop any
    # other entry that shares this (tmux_socket, tmux_pane) before the
    # upsert — old sessions left behind by a killed agent or an
    # un-consumed `done` do not double-count in the counter. Falls back to
    # session_id-only dedup when the new entry has no tmux coords.
    # Evicted entries are archived to .recent[] so the picker can surface
    # them later; same-session_id replacement (status transition for the
    # same agent) is not an eviction and does not archive.
    #
    # Waiting is sticky: once a session's entry is `waiting`, a subsequent
    # `waiting` event (typically another permission_prompt in the same
    # turn) is a no-op — the original ts and reason are preserved so the
    # counter does not oscillate and the TTL clock keeps running from the
    # moment Claude first blocked for input. Only a non-waiting upsert
    # (normally `done`) transitions the entry out.
    next="$(
      jq --arg sid "$session_id" \
         --arg wp "$wezterm_pane" \
         --arg tsk "$tmux_socket" \
         --arg tses "$tmux_session" \
         --arg tw "$tmux_window" \
         --arg tp "$tmux_pane" \
         --arg st "$status" \
         --arg rs "$reason" \
         --arg gb "$git_branch" \
         --argjson ts "$ts" \
         --argjson cap "$ATTENTION_RECENT_CAP" \
         --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
         "$__ATTENTION_RECENT_DEF"'
           . as $orig
           | (($orig.entries // {}) | to_entries
              | map(select(
                  .key != $sid and $tsk != "" and $tp != ""
                  and (.value.tmux_socket // "") == $tsk
                  and (.value.tmux_pane // "") == $tp
                ))
              | map(.value)) as $evicted
           | .entries = (
               ($orig.entries // {}) | to_entries
               | map(select(
                   .key == $sid
                   or $tsk == "" or $tp == ""
                   or (.value.tmux_socket // "") != $tsk
                   or (.value.tmux_pane // "") != $tp
                 ))
               | from_entries
             )
           | if ($st == "waiting") and ((.entries[$sid].status // "") == "waiting")
             then .
             else .entries[$sid] = {
                 session_id: $sid,
                 wezterm_pane_id: $wp,
                 tmux_socket: $tsk,
                 tmux_session: $tses,
                 tmux_window: $tw,
                 tmux_pane: $tp,
                 status: $st,
                 reason: $rs,
                 git_branch: $gb,
                 ts: $ts
               }
             end
           | archive_into_recent($evicted; $ts; $cap; $ttl)
         ' <<<"$current"
    )"
    attention_state_write "$next"
  ) 9>"$lock"
}

attention_state_remove() {
  local session_id="$1"
  local now; now="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    # Archive the entry being removed so the picker can surface it under
    # the recent band. Used by --forget (focus-ack, Alt+. delayed forget,
    # Alt+/ jump-to-done forget) — every one of those is an exit path
    # per docs/agent-attention.md.
    next="$(
      jq --arg sid "$session_id" \
         --argjson now "$now" \
         --argjson cap "$ATTENTION_RECENT_CAP" \
         --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
         "$__ATTENTION_RECENT_DEF"'
           ((.entries // {})[$sid] // null) as $removed
           | del(.entries[$sid])
           | if $removed != null
             then archive_into_recent([$removed]; $now; $cap; $ttl)
             else .
             end
         ' <<<"$current"
    )"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Remove a single recent[] entry by (session_id, archived_ts). Used by
# attention-jump.sh --recent when the recorded tmux pane no longer
# exists — we stop showing the dead row instead of fooling the user with
# a tmux command that selects nothing.
attention_state_recent_remove() {
  local session_id="$1" archived_ts="$2"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    next="$(jq --arg sid "$session_id" --argjson ats "$archived_ts" '
      .recent = ((.recent // []) | map(select(
        .session_id != $sid or (.archived_ts // 0) != $ats
      )))
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Conditional transition to `running`.
# Used by the PostToolUse hook to acknowledge that a permission prompt
# was resolved (the tool ran and completed, which is evidence the user
# allowed it). Behaviour by current status:
#   waiting → flip to running in place (ts/reason refreshed, tmux coords
#             preserved)
#   done    → flip to running in place (an async event — typically a
#             Monitor subscription delivering a streamed event after the
#             prior turn's Stop — woke the agent and a tool call landed,
#             which means Claude is mid-turn again. Stop has no way to
#             re-fire running on wake-up; this branch is how the counter
#             reflects reality.)
#   missing → upsert a fresh running entry using the caller-supplied
#             metadata. This covers the focus-ack path: when the user
#             focused the pane, maybe_ack_focused forgets the waiting
#             entry within one tick, so by the time PostToolUse fires
#             there is nothing to flip — but "running" still has to be
#             reflected on the counter, so we recreate the entry.
#   running → no-op (already reflected; do not spam OSC on every tool
#             call)
#
# Returns 0 if the state file changed, 1 on no-op. Callers use the
# return code to skip the OSC tick / log emit on no-op so PostToolUse
# (which fires on every tool call, auto-allowed or not) does not flood
# wezterm with spurious reload nudges.
attention_state_transition_to_running() {
  local session_id="$1" wezterm_pane="$2" tmux_socket="$3" tmux_session="$4"
  local tmux_window="$5" tmux_pane="$6" git_branch="${7:-}"
  attention_state_init
  local path
  path="$(attention_state_path)"
  # Fast path without the lock: most PostToolUse invocations hit tools
  # that were auto-allowed, so the entry is already `running` for this
  # session and the short-circuit here keeps the hot path cheap. Racy
  # with a concurrent writer, but in practice PostToolUse does not race
  # with other hooks on the same session_id. `done` is deliberately not
  # short-circuited: a Monitor event can wake the agent after Stop wrote
  # done, so we need to take the lock and flip back to running.
  local current_status=""
  if [[ -f "$path" ]]; then
    current_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' "$path" 2>/dev/null || printf '')"
  fi
  if [[ "$current_status" == "running" ]]; then
    return 1
  fi
  local lock
  lock="$(attention_state_lock_path)"
  local changed_flag
  changed_flag="$(mktemp 2>/dev/null || printf '')"
  local ts; ts="$(attention_state_now_ms)"
  (
    flock -x 9
    local current next locked_status
    current="$(attention_state_read)"
    # Re-check under the lock so a concurrent running upsert from another
    # hook is respected instead of stomped on by this delayed transition.
    # `done` is eligible for transition here — see docstring's `done` branch.
    locked_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' <<<"$current")"
    if [[ "$locked_status" == "running" ]]; then
      exit 0
    fi
    if [[ "$locked_status" == "waiting" || "$locked_status" == "done" ]]; then
      next="$(jq --arg sid "$session_id" --argjson ts "$ts" \
        '.entries[$sid].status = "running"
         | .entries[$sid].reason = ""
         | .entries[$sid].ts = $ts' <<<"$current")"
    else
      # Missing: upsert a fresh running entry. Mirror attention_state_upsert's
      # (tmux_socket, tmux_pane) dedup (and its archive-on-eviction) so a
      # prior tenant of the same pane neither double-counts nor vanishes.
      next="$(
        jq --arg sid "$session_id" \
           --arg wp "$wezterm_pane" \
           --arg tsk "$tmux_socket" \
           --arg tses "$tmux_session" \
           --arg tw "$tmux_window" \
           --arg tp "$tmux_pane" \
           --arg gb "$git_branch" \
           --argjson ts "$ts" \
           --argjson cap "$ATTENTION_RECENT_CAP" \
           --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
           "$__ATTENTION_RECENT_DEF"'
             . as $orig
             | (($orig.entries // {}) | to_entries
                | map(select(
                    .key != $sid and $tsk != "" and $tp != ""
                    and (.value.tmux_socket // "") == $tsk
                    and (.value.tmux_pane // "") == $tp
                  ))
                | map(.value)) as $evicted
             | .entries = (
                 ($orig.entries // {}) | to_entries
                 | map(select(
                     .key == $sid
                     or $tsk == "" or $tp == ""
                     or (.value.tmux_socket // "") != $tsk
                     or (.value.tmux_pane // "") != $tp
                   ))
                 | from_entries
               )
             | .entries[$sid] = {
                 session_id: $sid,
                 wezterm_pane_id: $wp,
                 tmux_socket: $tsk,
                 tmux_session: $tses,
                 tmux_window: $tw,
                 tmux_pane: $tp,
                 status: "running",
                 reason: "",
                 git_branch: $gb,
                 ts: $ts
               }
             | archive_into_recent($evicted; $ts; $cap; $ttl)
         ' <<<"$current"
      )"
    fi
    attention_state_write "$next"
    [[ -n "$changed_flag" ]] && printf '1' > "$changed_flag"
  ) 9>"$lock"
  local rc=1
  if [[ -n "$changed_flag" && -s "$changed_flag" ]]; then
    rc=0
  fi
  [[ -n "$changed_flag" ]] && rm -f "$changed_flag" 2>/dev/null
  return "$rc"
}

# Remove every entry on a given (tmux_socket, tmux_pane), optionally
# preserving one session_id. Used by the SessionStart `source=clear` hook
# to clean up stale entries when the user runs `/clear` and the prior
# turn's Stop hook never fired (e.g. the turn was still in flight). The
# new session's session_id is unknown to the old entries, so the standard
# same-pane eviction in attention_state_upsert does not trigger until the
# next UserPromptSubmit — which can be many minutes away. A no-op when
# tmux coords are empty, since we cannot identify the pane.
attention_state_evict_pane() {
  local tmux_socket="$1" tmux_pane="$2" except_session_id="${3:-}"
  if [[ -z "$tmux_socket" || -z "$tmux_pane" ]]; then
    return 0
  fi
  local now; now="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    next="$(jq --arg tsk "$tmux_socket" \
               --arg tp "$tmux_pane" \
               --arg ex "$except_session_id" \
               --argjson now "$now" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      . as $orig
      | (($orig.entries // {}) | to_entries
         | map(select(
             .key != $ex
             and (.value.tmux_socket // "") == $tsk
             and (.value.tmux_pane // "") == $tp
           ))
         | map(.value)) as $evicted
      | .entries = (
          ($orig.entries // {}) | to_entries
          | map(select(
              .key == $ex
              or (.value.tmux_socket // "") != $tsk
              or (.value.tmux_pane // "") != $tp
            ))
          | from_entries
        )
      | archive_into_recent($evicted; $now; $cap; $ttl)
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

attention_state_truncate() {
  local now; now="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    # --clear-all archives every active entry into .recent[] before
    # wiping .entries — the user is resetting active state, not
    # discarding the history of what was there.
    next="$(jq --argjson now "$now" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      ((.entries // {}) | to_entries | map(.value)) as $all
      | .entries = {}
      | archive_into_recent($all; $now; $cap; $ttl)
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Drop entries older than TTL (ms). Default 30 minutes. Pruned entries
# are archived into .recent[] so a user who left an agent idle past TTL
# can still find it under the recent band.
attention_state_prune() {
  local ttl_ms="${1:-1800000}"
  local now; now="$(attention_state_now_ms)"
  local cutoff=$((now - ttl_ms))
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    next="$(jq --argjson cutoff "$cutoff" \
               --argjson now "$now" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      ((.entries // {}) | to_entries | map(.value) | map(select(.ts < $cutoff))) as $pruned
      | .entries = ((.entries // {}) | with_entries(select(.value.ts >= $cutoff)))
      | archive_into_recent($pruned; $now; $cap; $ttl)
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}
