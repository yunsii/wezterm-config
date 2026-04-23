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
#         "ts":             <epoch ms>
#       }
#     }
#   }
#
# Sourced by:
#   scripts/claude-hooks/emit-agent-status.sh  (writer)
#   scripts/runtime/attention-jump.sh          (reader / consumer)

set -u

attention_state_path() {
  if command -v wezterm-runtime-detect-paths >/dev/null 2>&1; then
    : # placeholder
  fi
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$lib_dir/windows-runtime-paths-lib.sh"
  if windows_runtime_detect_paths 2>/dev/null; then
    printf '%s/state/agent-attention/attention.json' "$WINDOWS_RUNTIME_STATE_WSL"
    return 0
  fi
  local state_root="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
  printf '%s/state/agent-attention/attention.json' "$state_root"
}

attention_state_lock_path() {
  local path
  path="$(attention_state_path)"
  printf '%s.lock' "$path"
}

attention_state_init() {
  local path dir
  path="$(attention_state_path)"
  dir="${path%/*}"
  mkdir -p "$dir"
  if [[ ! -f "$path" ]]; then
    printf '%s\n' '{"version":1,"entries":{}}' > "$path"
  fi
}

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
         '
           .entries = (
             .entries
             | to_entries
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
         ' <<<"$current"
    )"
    attention_state_write "$next"
  ) 9>"$lock"
}

attention_state_remove() {
  local session_id="$1"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    next="$(jq --arg sid "$session_id" 'del(.entries[$sid])' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Conditional transition to `running`.
# Used by the PostToolUse hook to acknowledge that a permission prompt
# was resolved (the tool ran and completed, which is evidence the user
# allowed it). Behaviour by current status:
#   waiting → flip to running in place (ts/reason refreshed, tmux coords
#             preserved)
#   missing → upsert a fresh running entry using the caller-supplied
#             metadata. This covers the focus-ack path: when the user
#             focused the pane, maybe_ack_focused forgets the waiting
#             entry within one tick, so by the time PostToolUse fires
#             there is nothing to flip — but "running" still has to be
#             reflected on the counter, so we recreate the entry.
#   running → no-op (already reflected; do not spam OSC on every tool
#             call)
#   done    → no-op (Stop has already claimed the slot; preserve it
#             until focus-ack or another transition clears it)
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
  # with other hooks on the same session_id.
  local current_status=""
  if [[ -f "$path" ]]; then
    current_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' "$path" 2>/dev/null || printf '')"
  fi
  if [[ "$current_status" == "running" || "$current_status" == "done" ]]; then
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
    # Re-check under the lock so a concurrent transition to done (or a
    # running upsert from another hook) is respected instead of stomped
    # on by this delayed transition.
    locked_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' <<<"$current")"
    if [[ "$locked_status" == "running" || "$locked_status" == "done" ]]; then
      exit 0
    fi
    if [[ "$locked_status" == "waiting" ]]; then
      next="$(jq --arg sid "$session_id" --argjson ts "$ts" \
        '.entries[$sid].status = "running"
         | .entries[$sid].reason = ""
         | .entries[$sid].ts = $ts' <<<"$current")"
    else
      # Missing: upsert a fresh running entry. Mirror attention_state_upsert's
      # (tmux_socket, tmux_pane) dedup so a prior tenant of the same pane
      # does not double-count.
      next="$(
        jq --arg sid "$session_id" \
           --arg wp "$wezterm_pane" \
           --arg tsk "$tmux_socket" \
           --arg tses "$tmux_session" \
           --arg tw "$tmux_window" \
           --arg tp "$tmux_pane" \
           --arg gb "$git_branch" \
           --argjson ts "$ts" \
           '
             .entries = (
               .entries
               | to_entries
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

attention_state_truncate() {
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    attention_state_write '{"version":1,"entries":{}}'
  ) 9>"$lock"
}

# Drop entries older than TTL (ms). Default 30 minutes.
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
      '.entries = (.entries | with_entries(select(.value.ts >= $cutoff)))' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}
