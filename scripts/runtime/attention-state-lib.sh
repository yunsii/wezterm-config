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
#         "tmux_window_name":"<string>",  -- e.g. "dev-ci" (worktree leaf)
#         "status":         "running" | "waiting" | "done",
#         "reason":         "<short text>",  -- may be overwritten by Stop
#         "last_user_prompt":"<string>", -- UserPromptSubmit first line; sticky
#         "agent_name":     "<string>",  -- provider session name when known
#         "git_branch":     "<string>",
#         "waiting_kind":   "<optional; only while status=waiting>",
#                          # e.g. permission_prompt | elicitation_dialog |
#                          # approval_required. PostToolUse must NOT clear
#                          # elicitation_dialog (Grok fires PostToolUse while
#                          # the Ask dialog is still on screen); the prompt
#                          # watcher / Stop / next UserPromptSubmit clear it.
#         "ts":             <epoch ms>
#       }
#     },
#     "recent": [
#       {
#         "session_id", "wezterm_pane_id",
#         "tmux_socket", "tmux_session", "tmux_window", "tmux_pane",
#         "tmux_window_name", "git_branch",
#         "agent_name", "last_user_prompt",
#         "last_reason":  "<text at archive time>",
#         "last_status":  "running" | "waiting" | "done",
#         "live_ts":      <epoch ms when entry last lived>,
#         "archived_ts":  <epoch ms when entry was archived>
#       }
#     ]
#   }
#
# `recent[]` stores tombstones for sessions that left .entries via any of
# the five exit paths (same-session eviction, evict_session, --forget, TTL
# prune, --clear-all). Disk dedup key is (tmux_socket, tmux_session,
# tmux_pane); cap is 50 entries; TTL is 7 days. Active state in `.entries`
# is the source of truth — the Alt+/ picker further dedups display by
# (tmux_session, tmux_window) and shows the freshest 20.
#
# Sourced by:
#   scripts/runtime/agent-attention/emit.sh  (writer)
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
#
# Dedup key: (tmux_socket, tmux_session, tmux_pane). Older designs keyed
# on (tmux_socket, tmux_session) under the assumption "one tmux session
# hosts at most one Claude pane", which is wrong for split-pane setups —
# a /clear-driven archive in pane B would silently overwrite pane A's
# archived row, erasing it from the picker even though pane A's session
# was still alive (or had its own legitimate history). Including
# tmux_pane in the key gives each pane its own slot. tmux pane ids
# (`%N`) are server-internal monotonic identifiers — they survive
# split-window / swap-pane / break-pane and only change when the pane is
# truly destroyed and a new one is created (pane death already
# invalidates the row, so a new pane in a reused id is correct
# behavior). Empty tmux_pane (legacy entries / non-tmux contexts) all
# share the same "" pane key, preserving the old behavior for that
# slice.
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
       tmux_window_name: (.tmux_window_name // ""),
       git_branch: (.git_branch // ""),
       agent_name: (.agent_name // ""),
       last_user_prompt: (.last_user_prompt // ""),
       last_reason: (.reason // ""),
       last_status: (.status // ""),
       live_ts: (.ts // $now),
       archived_ts: $now
     })) as $new_recents
  | .recent = (
      ($new_recents + (.recent // []))
      | group_by([.tmux_socket, .tmux_session, (.tmux_pane // "")])
      | map(max_by(.archived_ts))
      | sort_by(-.archived_ts)
      | map(select(.archived_ts >= ($now - $ttl)))
      | .[0:$cap]
    );
'

# Best-effort Claude session display name from ~/.claude/sessions/<pid>.json
# (field `name`, usually derived like `dev-ci-63`). Returns empty on miss.
# Cost is a single grep -rlF over small JSON files (~tens of ms).
attention_resolve_agent_name() {
  local sid="${1:-}"
  [[ -z "$sid" || "$sid" == pane:* ]] && return 0
  local dir="${HOME}/.claude/sessions"
  [[ -d "$dir" ]] || return 0
  local f=""
  f="$(grep -rlF --include='*.json' -- "$sid" "$dir" 2>/dev/null | head -n1 || true)"
  [[ -n "$f" && -f "$f" ]] || return 0
  jq -r --arg sid "$sid" \
    'select(.sessionId == $sid) | .name // empty' \
    "$f" 2>/dev/null || true
}

attention_state_now_ms() {
  date +%s%3N
}

# Self-healing read: validate JSON before handing the buffer to the
# downstream jq pipeline. A corrupt file (truncated mid-write, leftover
# from a crashed pipeline, accidentally clobbered by an unsandboxed
# trace, etc.) would otherwise feed unparseable input into jq, blow it
# up, and either mask the bug behind `2>/dev/null || true` or — worse —
# the upstream writer's empty $next would then trip attention_state_write's
# refuse-empty guard, leaving the file stuck corrupt forever.
#
# When the file fails the parse check we treat it as the empty default
# state. The next successful write produces a clean baseline,
# self-healing the file without operator intervention. Logs a single
# warn line per recovery so the trail still shows the corruption
# (otherwise the silent reset would mask whatever wrote bad bytes).
attention_state_read() {
  local path content
  path="$(attention_state_path)"
  if [[ -f "$path" ]]; then
    content="$(cat "$path")"
    if printf '%s' "$content" | jq -e . >/dev/null 2>&1; then
      printf '%s' "$content"
      return 0
    fi
    if command -v runtime_log_warn >/dev/null 2>&1; then
      runtime_log_warn attention "state file unparseable; resetting to empty" \
        "path=$path" "size=${#content}" 2>/dev/null || true
    fi
  fi
  printf '%s' '{"version":1,"entries":{},"recent":[]}'
}

# atomic write via tmp + rename. Caller holds flock. Refuses to write
# an empty payload — every callsite produces output via a `jq` pipeline,
# and a failed jq run leaves $next empty; without this guard a transient
# jq error (bad input JSON, malformed --argjson, etc.) silently truncates
# attention.json to a single `\n` and the next reader either parses it
# as empty entries (losing every live entry) or fails outright. The
# write fails closed instead so the existing on-disk state survives the
# error and the caller's `2>/dev/null || true` handler can keep going.
attention_state_write() {
  local payload="$1" path tmp
  if [[ -z "$payload" ]]; then
    return 1
  fi
  path="$(attention_state_path)"
  tmp="${path}.tmp.$$"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$path"
}

attention_state_upsert() {
  local session_id="$1" wezterm_pane="$2" tmux_socket="$3" tmux_session="$4"
  local tmux_window="$5" tmux_pane="$6" status="$7" reason="$8" git_branch="${9:-}"
  # Optional 10th arg: waiting_kind (permission_prompt / elicitation_dialog /
  # approval_required). Stored only while status=waiting so PostToolUse can
  # refuse to clear elicitation_dialog (see transition_to_running).
  local waiting_kind="${10:-}"
  # Optional sticky display fields. Empty means "keep previous value".
  local last_user_prompt="${11:-}"
  local agent_name="${12:-}"
  local tmux_window_name="${13:-}"
  local ts; ts="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    # One tmux pane hosts at most one active attention entry, so drop any
    # other entry that shares this (tmux_socket, tmux_session, tmux_pane)
    # before the upsert — old session_ids left behind by `/clear` (new
    # uuid, same pane) do not double-count in the counter. Identity is
    # the *pane*, not the tmux session: split-pane setups can run
    # multiple Claude instances in one tmux session, and using session
    # alone as the eviction key would let one pane's UserPromptSubmit
    # silently archive a sibling pane's still-live entry. tmux pane ids
    # (`%N`) are server-internal monotonic identifiers that survive
    # split-window / swap-pane / break-pane and only change when the
    # pane is destroyed — using them as the key is safe. Falls back to
    # session_id-only dedup when the new entry has no tmux_pane (non-
    # tmux contexts; tmux race-guard already skips empty-pane upserts
    # for status mutations). Evicted entries are archived to .recent[]
    # so the picker can surface them later; same-session_id replacement
    # (status transition for the same agent) is not an eviction and
    # does not archive.
    #
    # Waiting is sticky: once a session's entry is `waiting`, a subsequent
    # `waiting` event (typically another permission_prompt in the same
    # turn) is a no-op — the original ts, reason, and waiting_kind are
    # preserved so the counter does not oscillate and the TTL clock keeps
    # running from the moment Claude first blocked for input. Only a
    # non-waiting upsert (normally `done`) transitions the entry out.
    #
    # last_user_prompt / agent_name / tmux_window_name are sticky across
    # Stop and waiting: an empty incoming value keeps the previous entry's
    # field so Alt+/ recent rows still show the last real user input and
    # provider session name after reason is overwritten with end_turn /
    # task done.
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
         --arg wk "$waiting_kind" \
         --arg lup "$last_user_prompt" \
         --arg an "$agent_name" \
         --arg wn "$tmux_window_name" \
         --argjson ts "$ts" \
         --argjson cap "$ATTENTION_RECENT_CAP" \
         --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
         "$__ATTENTION_RECENT_DEF"'
           . as $orig
           | (($orig.entries // {}) | to_entries
              | map(select(
                  .key != $sid and $tsk != "" and $tses != "" and $tp != ""
                  and (.value.tmux_socket  // "") == $tsk
                  and (.value.tmux_session // "") == $tses
                  and (.value.tmux_pane    // "") == $tp
                ))
              | map(.value)) as $evicted
           | .entries = (
               ($orig.entries // {}) | to_entries
               | map(select(
                   .key == $sid
                   or $tsk == "" or $tses == "" or $tp == ""
                   or (.value.tmux_socket  // "") != $tsk
                   or (.value.tmux_session // "") != $tses
                   or (.value.tmux_pane    // "") != $tp
                 ))
               | from_entries
             )
           | if ($st == "waiting") and ((.entries[$sid].status // "") == "waiting")
             then .
             else
               ((.entries[$sid] // {}) as $prev
               | .entries[$sid] = (
                   {
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
                   + (if $lup != "" then {last_user_prompt: $lup}
                      elif (($prev.last_user_prompt // "") != "")
                      then {last_user_prompt: $prev.last_user_prompt}
                      else {} end)
                   + (if $an != "" then {agent_name: $an}
                      elif (($prev.agent_name // "") != "")
                      then {agent_name: $prev.agent_name}
                      else {} end)
                   + (if $wn != "" then {tmux_window_name: $wn}
                      elif (($prev.tmux_window_name // "") != "")
                      then {tmux_window_name: $prev.tmux_window_name}
                      else {} end)
                   + (if ($st == "waiting") and ($wk != "")
                      then {waiting_kind: $wk}
                      else {}
                      end)
                 ))
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
# Called from the `resolved` branch in emit-agent-status.sh, which is
# wired to both PreToolUse and PostToolUse. The two hooks fire at
# different lifecycle points and target different source statuses:
#
#   PreToolUse  fires once before the tool starts (and before any
#               permission_prompt). It does NOT fire when the user
#               approves a permission prompt — Claude Code exposes no
#               hook for that — so PreToolUse can only flip done →
#               running (Monitor wake-up).
#   PostToolUse fires after the tool completes. This is the only
#               signal that an approved permission prompt has been
#               answered, so it is the only event that can flip
#               waiting → running.
#
# Behaviour by current status (irrespective of which hook called):
#   waiting → flip to running in place (ts/reason refreshed, tmux
#             coords preserved). Only PostToolUse reaches this branch
#             for permission_prompt; PreToolUse fires before the prompt
#             and lands on running. **Exception**: waiting_kind=
#             elicitation_dialog is sticky against PostToolUse /
#             PreToolUse — Grok fires PostToolUse while the Ask dialog
#             is still on screen (~150–250 ms after Notification). Pass
#             force=1 (watcher) to clear elicitation waiting when the
#             dialog actually leaves the pane.
#   done    → flip to running in place (Monitor wake-up: a streamed
#             event resumed the agent after a prior Stop; Claude is
#             mid-turn again). Both PreToolUse and PostToolUse can
#             reach this branch — PreToolUse usually wins the race.
#   missing → upsert a fresh running entry using the caller-supplied
#             metadata. This covers the focus-ack path: when the user
#             focused the pane, maybe_ack_focused forgets the entry
#             within one tick, so by the time the next hook fires
#             there is nothing to flip — but "running" still has to
#             be reflected on the counter, so we recreate the entry.
#   running → no-op (already reflected; do not spam OSC on every tool
#             call). PreToolUse hits this on every auto-allowed tool
#             call; PostToolUse hits it whenever PreToolUse already
#             flipped a done → running before it fired.
#
# Optional 8th arg `force`: when `1`, allow flipping elicitation_dialog
# waiting (used by attention-prompt-watcher.sh). Default / empty keeps
# elicitation sticky so premature PostToolUse cannot clear the badge.
#
# Returns 0 if the state file changed, 1 on no-op. Callers use the
# return code to skip the OSC tick / log emit on no-op so PreToolUse /
# PostToolUse (which fire on every tool call, auto-allowed or not) do
# not flood wezterm with spurious reload nudges.
#
# See docs/agent-attention.md "Limitation: no signal for permission
# approval" for why we cannot do better than PostToolUse for the
# approve → tool-completion window, and "Grok elicitation vs PostToolUse"
# for the elicitation sticky rule.
attention_state_transition_to_running() {
  local session_id="$1" wezterm_pane="$2" tmux_socket="$3" tmux_session="$4"
  local tmux_window="$5" tmux_pane="$6" git_branch="${7:-}"
  local force="${8:-0}"
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
  # Elicitation waiting is also not short-circuited here — the locked
  # section below decides whether force=1 may clear it.
  local current_status="" current_waiting_kind=""
  if [[ -f "$path" ]]; then
    current_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' "$path" 2>/dev/null || printf '')"
    current_waiting_kind="$(jq -r --arg sid "$session_id" '.entries[$sid].waiting_kind // ""' "$path" 2>/dev/null || printf '')"
  fi
  if [[ "$current_status" == "running" ]]; then
    return 1
  fi
  if [[ "$current_status" == "waiting" \
        && "$current_waiting_kind" == "elicitation_dialog" \
        && "$force" != "1" ]]; then
    return 1
  fi
  local lock
  lock="$(attention_state_lock_path)"
  local changed_flag
  changed_flag="$(mktemp 2>/dev/null || printf '')"
  local ts; ts="$(attention_state_now_ms)"
  (
    flock -x 9
    local current next locked_status locked_waiting_kind
    current="$(attention_state_read)"
    # Re-check under the lock so a concurrent running upsert from another
    # hook is respected instead of stomped on by this delayed transition.
    # `done` is eligible for transition here — see docstring's `done` branch.
    locked_status="$(jq -r --arg sid "$session_id" '.entries[$sid].status // ""' <<<"$current")"
    locked_waiting_kind="$(jq -r --arg sid "$session_id" '.entries[$sid].waiting_kind // ""' <<<"$current")"
    if [[ "$locked_status" == "running" ]]; then
      exit 0
    fi
    if [[ "$locked_status" == "waiting" \
          && "$locked_waiting_kind" == "elicitation_dialog" \
          && "$force" != "1" ]]; then
      exit 0
    fi
    if [[ "$locked_status" == "waiting" || "$locked_status" == "done" ]]; then
      next="$(jq --arg sid "$session_id" --argjson ts "$ts" \
        '.entries[$sid].status = "running"
         | .entries[$sid].reason = ""
         | .entries[$sid].ts = $ts
         | del(.entries[$sid].waiting_kind)' <<<"$current")"
    else
      # Missing: upsert a fresh running entry. Mirror attention_state_upsert's
      # (tmux_socket, tmux_session, tmux_pane) dedup (and its archive-on-
      # eviction) so a prior tenant of the same pane neither double-counts
      # nor vanishes. Falls back to session_id-only dedup when tmux_pane is
      # empty (non-tmux contexts).
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
                    .key != $sid and $tsk != "" and $tses != "" and $tp != ""
                    and (.value.tmux_socket  // "") == $tsk
                    and (.value.tmux_session // "") == $tses
                    and (.value.tmux_pane    // "") == $tp
                  ))
                | map(.value)) as $evicted
             | .entries = (
                 ($orig.entries // {}) | to_entries
                 | map(select(
                     .key == $sid
                     or $tsk == "" or $tses == "" or $tp == ""
                     or (.value.tmux_socket  // "") != $tsk
                     or (.value.tmux_session // "") != $tses
                     or (.value.tmux_pane    // "") != $tp
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

# Remove every entry on a given (tmux_socket, tmux_session, tmux_pane),
# optionally preserving one session_id. Used by the SessionStart
# `source=clear` hook to clean up stale entries when the user runs
# `/clear` and the prior turn's Stop hook never fired (e.g. the turn was
# still in flight). The new session's session_id is unknown to the old
# entries, so the standard same-session eviction in
# attention_state_upsert does not trigger until the next UserPromptSubmit
# — which can be many minutes away. A no-op when tmux coords are empty,
# since we cannot identify the session.
#
# Pane-scoped: a 4th positional `tmux_pane` arg restricts the sweep to
# entries that share that pane id. Multi-pane tmux sessions hosting more
# than one Claude (e.g. user splits a worktree pane to keep two agents
# side by side) need this — without it, /clear in pane B silently
# archives pane A's still-live entry, erasing it from the picker and
# the right-status counter even though pane A's session was untouched.
# Empty tmux_pane (legacy callers / non-tmux contexts) preserves the
# pre-fix (socket, session) sweep behavior.
attention_state_evict_session() {
  local tmux_socket="$1" tmux_session="$2" except_session_id="${3:-}"
  local tmux_pane="${4:-}"
  if [[ -z "$tmux_socket" || -z "$tmux_session" ]]; then
    return 0
  fi
  local now; now="$(attention_state_now_ms)"
  attention_state_init
  local lock
  lock="$(attention_state_lock_path)"
  # Pane-scoped eviction: when the caller hands us a tmux_pane, only
  # evict entries that share (socket, session, pane). This is the
  # `/clear` case on a multi-pane tmux session — pane B's /clear must
  # not silently archive pane A's still-live entry. Empty tmux_pane
  # falls back to (socket, session) eviction so legacy callers (and
  # any future caller without a pane handle) keep their old behavior.
  (
    flock -x 9
    local current next
    current="$(attention_state_read)"
    next="$(jq --arg tsk "$tmux_socket" \
               --arg tses "$tmux_session" \
               --arg ex "$except_session_id" \
               --arg tp "$tmux_pane" \
               --argjson now "$now" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      . as $orig
      | (($orig.entries // {}) | to_entries
         | map(select(
             .key != $ex
             and (.value.tmux_socket  // "") == $tsk
             and (.value.tmux_session // "") == $tses
             and ($tp == "" or (.value.tmux_pane // "") == $tp)
           ))
         | map(.value)) as $evicted
      | .entries = (
          ($orig.entries // {}) | to_entries
          | map(select(
              .key == $ex
              or (.value.tmux_socket  // "") != $tsk
              or (.value.tmux_session // "") != $tses
              or ($tp != "" and (.value.tmux_pane // "") != $tp)
            ))
          | from_entries
        )
      | archive_into_recent($evicted; $now; $cap; $ttl)
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Archive every entry whose tmux_session matches and remove it from
# .entries. Used by the tmux `session-closed` hook (and the wezterm-side
# `forget_by_tmux_session` Lua helper, which spawns this via attention-
# jump.sh --forget-session). Zero-latency replacement for the reachability
# sweep when tmux can tell us the session is gone outright. A no-op when
# tmux_session is empty.
attention_state_forget_session() {
  local tmux_session="$1"
  if [[ -z "$tmux_session" ]]; then
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
    next="$(jq --arg tses "$tmux_session" \
               --argjson now "$now" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      . as $orig
      | (($orig.entries // {}) | to_entries
         | map(select((.value.tmux_session // "") == $tses))
         | map(.value)) as $evicted
      | .entries = (
          ($orig.entries // {}) | to_entries
          | map(select((.value.tmux_session // "") != $tses))
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
#
# Optional second arg: a JSON map `{<tmux_socket>: ["<pane_id>", ...], ...}`
# describing the live tmux pane set per socket. When provided, entries
# whose `(tmux_socket, tmux_pane)` is missing from the corresponding
# socket's pane list are also archived (reachability sweep). Sockets
# absent from the map are treated as "unknown" — entries on those
# sockets are kept (we only archive when we have positive evidence
# that the pane is gone, never when the tmux server is just
# unreachable). Empty / missing arg disables the sweep entirely.
#
# This is what catches "agent crashed / pane killed without firing
# Stop" cases that would otherwise sit in entries[] until the 30min
# TTL: tmux already removed the pane from list-panes, so the
# reachability check archives the dead row at the next periodic
# prune. The TTL prune still runs for the conservative case (entry's
# socket is unknown to us, e.g. tmux server died).
attention_state_prune() {
  local ttl_ms="${1:-1800000}"
  local alive_panes_json="${2:-}"
  # Empty / missing arg → no-op for the reachability sweep. The empty-
  # brace default has to come from a separate assignment because the
  # `${2:-{}}` parameter-expansion form does not parse the closing `}`
  # cleanly (bash treats it as the param-expansion terminator).
  if [[ -z "$alive_panes_json" ]]; then
    alive_panes_json='{}'
  fi
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
               --argjson alive "$alive_panes_json" \
               --argjson cap "$ATTENTION_RECENT_CAP" \
               --argjson ttl "$ATTENTION_RECENT_TTL_MS" \
               "$__ATTENTION_RECENT_DEF"'
      # TTL pass: anything older than $cutoff is unconditionally pruned.
      # Reachability pass (after TTL): archive entries whose
      # (tmux_socket, tmux_pane) is positively gone, i.e. the entry
      # socket is a known key in $alive AND the entry pane is not
      # listed under it. Sockets absent from $alive are treated as
      # unknown and the entries on them are kept; without that branch a
      # tmux server we cannot reach (started later, dropped, restarted)
      # would falsely look like every pane is dead and we would archive
      # the lot. Empty $alive ({}) makes the entire pass a no-op so the
      # hot-path TTL-only callers keep their behavior. Field reads
      # guard with `// ""` so an entry missing tmux_socket / tmux_pane
      # never reaches has(null) (jq rejects null keys outright). Note:
      # apostrophes are intentionally avoided in this comment block —
      # the entire filter is single-quoted in bash, so a stray
      # apostrophe would terminate the quote and let bash try to
      # consume the in-filter `$alive` reference itself.
      # The inner predicate binds $sock and $pane via `as $sock` / `as
      # $pane` before referencing them, instead of reading
      # `.value.tmux_socket` again inside an `or`-chain branch. jq does
      # not always short-circuit `or` cleanly when the right operand
      # re-pipes through `index(...)` on an array context — the inner
      # `.value.tmux_pane` would re-evaluate on the array we just
      # produced, error out, and the surrounding `or` would coerce it
      # to true, keeping every entry alive in the reachability sweep.
      def is_unreachable($alive):
        (.tmux_socket // "") as $sock
        | (.tmux_pane // "") as $pane
        | $sock != ""
          and $pane != ""
          and ($alive | has($sock))
          and ((($alive[$sock]) // []) | index($pane)) == null;
      ((.entries // {}) | to_entries | map(.value) | map(select(.ts < $cutoff))) as $pruned_ttl
      | ((.entries // {}) | with_entries(select(.value.ts >= $cutoff))) as $kept_ttl
      | ($kept_ttl | to_entries | map(.value)
         | map(select(is_unreachable($alive)))) as $pruned_dead
      | .entries = ($kept_ttl | with_entries(select((.value | is_unreachable($alive)) | not)))
      | archive_into_recent($pruned_ttl + $pruned_dead; $now; $cap; $ttl)
    ' <<<"$current")"
    attention_state_write "$next"
  ) 9>"$lock"
}

# Build the alive-panes map needed by attention_state_prune's reachability
# sweep. Reads tmux sockets from current entries[], runs `tmux list-panes
# -a` per socket, and emits `{socket: [pane_id, ...]}` JSON. Sockets that
# fail the query (server gone, file missing) are dropped from the map so
# the prune's "unknown socket → keep" branch protects entries on them.
#
# Cost: one tmux fork per distinct socket in entries[] (typically 1, at
# most 2 in practice). Cheap enough to run on every periodic prune; not
# called from emit-agent-status.sh's hot-path prune.
attention_state_collect_alive_panes() {
  attention_state_init
  local path
  path="$(attention_state_path)"
  local sockets
  sockets="$(jq -r '.entries // {} | [.[].tmux_socket // empty] | map(select(length > 0)) | unique | .[]' "$path" 2>/dev/null || printf '')"
  if [[ -z "$sockets" ]]; then
    printf '{}'
    return 0
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    printf '{}'
    return 0
  fi
  local pieces=()
  while IFS= read -r sock; do
    [[ -z "$sock" ]] && continue
    [[ -S "$sock" ]] || continue
    local panes_raw
    panes_raw="$(tmux -S "$sock" list-panes -a -F '#{pane_id}' 2>/dev/null || printf '')"
    [[ -z "$panes_raw" ]] && continue
    pieces+=("$(jq -n --arg s "$sock" --arg p "$panes_raw" \
      '{($s): ($p | split("\n") | map(select(length > 0)))}' 2>/dev/null || printf '{}')")
  done <<<"$sockets"
  if (( ${#pieces[@]} == 0 )); then
    printf '{}'
    return 0
  fi
  printf '%s\n' "${pieces[@]}" | jq -s 'add' 2>/dev/null || printf '{}'
}
