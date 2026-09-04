#!/usr/bin/env bash
# Provider-agnostic agent attention emitter. Writes the current agent's state
# into the shared attention state file and publishes an `attention.tick`
# event through the event bus (OSC `we_attention_tick` when /dev/tty is a
# regular pane; see docs/event-bus.md) so titles.lua reloads state and
# refreshes badges / status counters.
#
# Usage:
#   emit.sh --provider codex --session-id <id> --reason <text> running
#   emit.sh running                  # backwards-compatible shorthand
#
# Adapters normalize provider hook payloads before invoking this script. For
# backwards compatibility, this script still accepts a raw Claude-like JSON
# payload on stdin and extracts .session_id / .message / .stop_reason / .prompt.
#
# Fails open: any step that fails is silently skipped so hook execution
# never breaks the agent flow.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/attention-state-lib.sh"
# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/runtime-log-lib.sh"
WEZTERM_RUNTIME_LOG_SOURCE="agent-attention-emit.sh"

provider="${AGENT_ATTENTION_PROVIDER:-unknown}"
session_id="${AGENT_ATTENTION_SESSION_ID:-}"
reason_override="${AGENT_ATTENTION_REASON:-}"
notification_type="${AGENT_ATTENTION_NOTIFICATION_TYPE:-}"
raw_event="${AGENT_ATTENTION_RAW_EVENT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)
      provider="${2:-unknown}"; shift 2 ;;
    --provider=*)
      provider="${1#*=}"; shift ;;
    --session-id)
      session_id="${2:-}"; shift 2 ;;
    --session-id=*)
      session_id="${1#*=}"; shift ;;
    --reason)
      reason_override="${2:-}"; shift 2 ;;
    --reason=*)
      reason_override="${1#*=}"; shift ;;
    --notification-type|--wait-kind)
      notification_type="${2:-}"; shift 2 ;;
    --notification-type=*|--wait-kind=*)
      notification_type="${1#*=}"; shift ;;
    --raw-event)
      raw_event="${2:-}"; shift 2 ;;
    --raw-event=*)
      raw_event="${1#*=}"; shift ;;
    --)
      shift; break ;;
    -*)
      exit 0 ;;
    *)
      break ;;
  esac
done

status="${1:-}"
if [[ -z "$status" ]]; then
  exit 0
fi

# Earliest possible timestamp inside the hook. Pairs with emit-side
# `elapsed_ms` and the wezterm-side `tick received` log to attribute the
# wallclock gap between visible UI and rendered status counter.
entry_ts_ms="$(date +%s%3N 2>/dev/null || printf '')"

case "$status" in
  running)    default_reason="running…" ;;
  waiting)    default_reason="input required" ;;
  done)       default_reason="task done" ;;
  cleared)    default_reason="" ;;
  resolved)   default_reason="" ;;
  pane-evict) default_reason="" ;;
  *)          exit 0 ;;
esac

reason="$default_reason"
# Workday-playback fields for agent.user_input (summary only — never full body).
prompt_summary=""
prompt_chars=""
prompt_lines=""
if [[ ! -t 0 ]] && command -v jq >/dev/null 2>&1; then
  stdin_payload="$(cat || true)"
  if [[ -n "$stdin_payload" ]]; then
    if [[ -z "$session_id" ]]; then
      # Claude: session_id; Codex: thread_id/threadId; Grok compat: sessionId.
      session_id="$(printf '%s' "$stdin_payload" \
        | jq -r '.session_id // .sessionId // .thread_id // .threadId // empty' \
          2>/dev/null || true)"
    fi
    # .prompt carries the user's new prompt on UserPromptSubmit. Take the
    # first line and cap it so the Alt+/ overlay label stays readable.
    if [[ -z "$reason_override" ]]; then
      extracted="$(printf '%s' "$stdin_payload" \
        | jq -r '.message // .stop_reason // .stopReason // .reason // (.prompt | if . == null then empty else (split("\n")[0] | .[0:80]) end) // empty' \
        2>/dev/null || true)"
      if [[ -n "$extracted" ]]; then
        reason="$extracted"
      fi
    fi
    # Narrative summary: first line ≤80 + char/line counts (no full prompt).
    prompt_summary="$(printf '%s' "$stdin_payload" \
      | jq -r '(.prompt | if . == null then empty else (split("\n")[0] | .[0:80]) end) // empty' \
        2>/dev/null || true)"
    prompt_chars="$(printf '%s' "$stdin_payload" \
      | jq -r '(.prompt | if . == null then empty else (tostring | length) end) // empty' \
        2>/dev/null || true)"
    prompt_lines="$(printf '%s' "$stdin_payload" \
      | jq -r '(.prompt | if . == null then empty else (split("\n") | length) end) // empty' \
        2>/dev/null || true)"
    if [[ -z "$notification_type" ]]; then
      notification_type="$(printf '%s' "$stdin_payload" \
        | jq -r '.notification_type // .notificationType // .type // empty' \
          2>/dev/null || true)"
    fi
    if [[ -z "$raw_event" ]]; then
      raw_event="$(printf '%s' "$stdin_payload" \
        | jq -r '.hook_event_name // .hookEventName // .event // empty' \
          2>/dev/null || true)"
    fi
  fi
fi
if [[ -n "$reason_override" ]]; then
  reason="$reason_override"
fi

# ---------------------------------------------------------------------------
# Waiting gate (Notification path is a strict whitelist)
# ---------------------------------------------------------------------------
# Only permission / elicitation / approval signals may raise ⚠ waiting.
#
# Why whitelist (not blacklist): Grok loads Claude's Notification → waiting
# hook via compat, then fires Notification on *turn_complete* with message
# "Turn complete". Payload is often camelCase and/or leaves notification_type
# empty — the old "ignore only when type ∈ {idle_prompt,auth_success}" logic
# fell through on empty type and overwrote a correct Stop→done with waiting.
#
# Non-Notification waiting paths still work:
#   - Codex PermissionRequest (raw_event=PermissionRequest, type empty)
#   - scripts/dev/test-agent-attention.sh direct `waiting` (no Notification)
#   - manual emit.sh waiting for diagnosis
# ---------------------------------------------------------------------------
if [[ "$status" == "waiting" ]]; then
  # Normalize separators so approval-required / approval_required match.
  ntype="$(printf '%s' "$notification_type" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '-' '_')"
  rev="$(printf '%s' "$raw_event" | tr '[:upper:]' '[:lower:]')"
  reason_lc="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')"

  is_notification_path=0
  case "$rev" in
    notification|notification_*) is_notification_path=1 ;;
  esac
  # Any explicit notification_type means we are on the Notification path
  # (Claude always sets it; Grok may set turn_complete / approval_required).
  [[ -n "$ntype" ]] && is_notification_path=1

  allow_waiting=0
  if (( is_notification_path == 1 )); then
    case "$ntype" in
      permission_prompt|elicitation_dialog|approval_required)
        allow_waiting=1
        ;;
    esac
  else
    # Direct / Codex / diagnostic waiting: allow unless reason is clearly a
    # completion toast (Grok turn_complete with unparsed empty raw_event).
    allow_waiting=1
    case "$reason_lc" in
      *'turn complete'*|*'task complete'*|*'session ready'*)
        allow_waiting=0
        ;;
    esac
  fi

  if (( allow_waiting == 0 )); then
    runtime_log_info attention "notification ignored" \
      "provider=$provider" \
      "raw_event=$raw_event" \
      "status=$status" \
      "notification_type=${notification_type:-}" \
      "reason=${reason:-}" \
      "session_id=${session_id:-}" \
      "wezterm_pane=${WEZTERM_PANE:-}" \
      "tmux_pane=${TMUX_PANE:-}" \
      "entry_ts_ms=$entry_ts_ms" 2>/dev/null || true
    exit 0
  fi
fi

# Fallback key when hooks run without a stable provider session id (e.g. test
# script) — scope the entry to the WezTerm pane so repeated fires from the
# same pane reuse the same slot instead of accumulating.
if [[ -z "$session_id" ]]; then
  session_id="pane:${WEZTERM_PANE:-unknown}"
fi

# Best-effort tmux coordinates. Outside tmux these stay empty and the
# jump script will only have a WezTerm pane id to work with.
tmux_socket=""
tmux_session=""
tmux_window=""
tmux_pane=""
tmux_window_name=""
if [[ -n "${TMUX-}" ]] && command -v tmux >/dev/null 2>&1; then
  # Target our own pane explicitly. Without -t, tmux returns the client's
  # currently active pane regardless of which hook fired, so every entry
  # would collapse onto whichever pane the user is looking at.
  target_pane="${TMUX_PANE:-}"
  if [[ -n "$target_pane" ]]; then
    tmux_meta="$(tmux display-message -p -t "$target_pane" -F '#{socket_path}|#{session_name}|#{window_id}|#{pane_id}|#{window_name}' 2>/dev/null || true)"
  fi
  if [[ -z "${tmux_meta:-}" ]]; then
    tmux_meta="$(tmux display-message -p -F '#{socket_path}|#{session_name}|#{window_id}|#{pane_id}|#{window_name}' 2>/dev/null || true)"
  fi
  if [[ -n "${tmux_meta:-}" ]]; then
    IFS='|' read -r tmux_socket tmux_session tmux_window tmux_pane tmux_window_name <<<"$tmux_meta"
  fi
fi

# Race guard: inside tmux but display-message returned an empty pane id
# means the tmux server has not yet finished binding this pane (typical
# during respawn-pane after `session.refresh-current-session`). Writing a
# state entry now would persist `tmux_window=""`/`tmux_pane=""`, which
# the picker renders as `?` in the tmux_seg slot. The status mutation
# this hook would publish is recoverable: the next hook from this pane
# (within seconds) sees a fully-bound tmux pane and writes a clean
# entry. Skip the upsert for write-status calls; resolved/cleared/
# pane-evict are housekeeping that should still run.
case "$status" in
  running|waiting|done)
    if [[ -n "${TMUX-}" && -z "$tmux_pane" ]]; then
      runtime_log_info attention "hook skipped on tmux race" \
        "status=$status" \
        "session_id=${session_id:-}" \
        "wezterm_pane=${WEZTERM_PANE:-}" \
        "tmux_socket=${tmux_socket:-}" \
        "tmux_pane_env=${TMUX_PANE:-}" \
        "entry_ts_ms=$entry_ts_ms" 2>/dev/null || true
      exit 0
    fi
    # No jumpable target anywhere: neither a WezTerm pane id nor a tmux
    # pane. Happens when an agent hook fires outside any managed
    # WezTerm/tmux pane (e.g. an OpenClaw-spawned agent). Such an entry
    # can never be jumped (Alt+.) or focus-acked, so it would linger as
    # an orphan that inflates the right-status counter while staying
    # invisible in the Alt+/ picker (which filters unreachable rows via
    # entry_reachable). Persisting it is the write-side half of the
    # badge/picker desync; drop it here. The "WezTerm pane but no tmux"
    # case (WEZTERM_PANE set, tmux_pane empty) is a supported non-tmux
    # jump target and is intentionally NOT skipped. Housekeeping statuses
    # (resolved/cleared/pane-evict) are not in this case arm and still run.
    if [[ -z "${WEZTERM_PANE:-}" && -z "$tmux_pane" ]]; then
      runtime_log_info attention "hook skipped: no wezterm/tmux pane" \
        "status=$status" \
        "provider=${provider:-}" \
        "session_id=${session_id:-}" \
        "entry_ts_ms=$entry_ts_ms" 2>/dev/null || true
      exit 0
    fi
    ;;
esac

# Resolve the git branch from the best available cwd. Some providers expose a
# project dir to hook subprocesses; fall back to the tmux pane's current_path,
# then the hook's own $PWD.
git_branch=""
if command -v git >/dev/null 2>&1; then
  git_dir="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-}}"
  if [[ -z "$git_dir" && -n "${TMUX-}" && -n "${TMUX_PANE:-}" ]] \
      && command -v tmux >/dev/null 2>&1; then
    git_dir="$(tmux display-message -p -t "$TMUX_PANE" -F '#{pane_current_path}' 2>/dev/null || true)"
  fi
  if [[ -z "$git_dir" ]]; then
    git_dir="$PWD"
  fi
  if [[ -d "$git_dir" ]]; then
    git_branch="$(git -C "$git_dir" branch --show-current 2>/dev/null || true)"
  fi
fi

attention_state_prune 1800000 2>/dev/null || true

if [[ "$status" == "cleared" ]]; then
  attention_state_remove "$session_id" 2>/dev/null || true
elif [[ "$status" == "pane-evict" ]]; then
  # SessionStart source=clear: the new session_id in stdin is for the
  # fresh post-/clear session; any entry still parked on this tmux
  # PANE belongs to the discarded pre-/clear session and will never
  # get its own Stop. Evict it, but preserve the new session_id
  # defensively in case a race re-creates it before we hold the lock.
  #
  # Eviction key is (tmux_socket, tmux_session, tmux_pane): /clear
  # stays in the same tmux pane, and tmux pane ids (`%N`) are
  # server-internal monotonic identifiers that survive split-window /
  # swap-pane / break-pane (only true pane destruction recycles them,
  # which already invalidates the row). Earlier code keyed on (socket,
  # session) without pane on the rationale "pane id changes on
  # splits/rearranges" — but split-window allocates a *new* pane id
  # for the new pane, leaving the original's id untouched, so the
  # reasoning was wrong. Without pane in the key, /clear in pane B
  # silently archived pane A's still-live entry on the same tmux
  # session, leaving A invisible in both the picker and the counter.
  attention_state_evict_session "$tmux_socket" "$tmux_session" "$session_id" \
    "$tmux_pane" 2>/dev/null || true
elif [[ "$status" == "resolved" ]]; then
  # Wired to BOTH PreToolUse and PostToolUse. The two hooks fire at
  # different lifecycle points and cover different transitions; they
  # share this branch only because the helper handles every case.
  #
  #   PreToolUse  fires once when the agent decides to call a tool —
  #     BEFORE any permission prompt and BEFORE the tool starts. Providers do
  #     not necessarily fire it again when the user approves the prompt.
  #     Useful transition here is `done → running` for the Monitor
  #     wake-up case (a streamed event resumed the agent after a prior
  #     `Stop`). For the common path it lands on `running` and the
  #     transition helper short-circuits via the fast path.
  #
  #   PostToolUse fires AFTER the tool completes. This is the only
  #     signal we have that an approved permission prompt has actually
  #     been answered (the tool would not have completed otherwise).
  #     Useful transitions: `waiting → running` (the approve+execute
  #     window has finished — entire window is invisible to us), and
  #     `done → running` as belt-and-suspenders for the Monitor
  #     wake-up case.
  #
  # Missing entry: upsert a fresh `running` (covers focus-ack having
  # forgot the waiting row before the hook fired). `running` is a
  # no-op so we do not nudge wezterm or log on every auto-allowed
  # tool call. A single `resolved no-op` log line lets the diagnostics
  # trail still show the hook was invoked.
  #
  # See docs/agent-attention.md "Limitation: no signal for permission
  # approval" for why we cannot flip `waiting → running` at approval
  # time and why this branch never tries to.
  # Grok Ask / elicitation_dialog: PostToolUse often fires ~200 ms after
  # Notification while the dialog is still on screen. transition_to_running
  # refuses that flip unless force=1 (watcher). Log it distinctly so the
  # latency probe does not look like a plain auto-allowed no-op.
  _resolved_status=""
  _resolved_waiting_kind=""
  if [[ -f "$(attention_state_path)" ]]; then
    _resolved_status="$(jq -r --arg sid "$session_id" \
      '.entries[$sid].status // ""' "$(attention_state_path)" 2>/dev/null || printf '')"
    _resolved_waiting_kind="$(jq -r --arg sid "$session_id" \
      '.entries[$sid].waiting_kind // ""' "$(attention_state_path)" 2>/dev/null || printf '')"
  fi
  if [[ "$_resolved_status" == "waiting" \
        && "$_resolved_waiting_kind" == "elicitation_dialog" ]]; then
    runtime_log_info attention "resolved skipped elicitation waiting" \
      "provider=$provider" \
      "raw_event=$raw_event" \
      "session_id=$session_id" \
      "wezterm_pane=${WEZTERM_PANE:-}" \
      "tmux_pane=$tmux_pane" \
      "waiting_kind=elicitation_dialog" \
      "entry_ts_ms=$entry_ts_ms" 2>/dev/null || true
    exit 0
  fi

  if ! attention_state_transition_to_running \
      "$session_id" \
      "${WEZTERM_PANE:-}" \
      "$tmux_socket" \
      "$tmux_session" \
      "$tmux_window" \
      "$tmux_pane" \
      "$git_branch" \
      2>/dev/null; then
    noop_emit_ts_ms="$(date +%s%3N 2>/dev/null || printf '')"
    noop_elapsed_ms=''
    if [[ -n "$entry_ts_ms" && -n "$noop_emit_ts_ms" ]]; then
      noop_elapsed_ms=$(( noop_emit_ts_ms - entry_ts_ms ))
    fi
    runtime_log_info attention "hook resolved no-op" \
      "status=$status" \
      "session_id=$session_id" \
      "wezterm_pane=${WEZTERM_PANE:-}" \
      "tmux_pane=$tmux_pane" \
      "entry_ts_ms=$entry_ts_ms" \
      "elapsed_ms=$noop_elapsed_ms" 2>/dev/null || true
    exit 0
  fi
else
  # Focus-skip: when this firing pane IS the currently-focused tmux
  # pane in its session, suppress waiting / done upserts entirely.
  # Per user spec ("如果 focus 了的 tmux pane 不触发 waiting 和 done
  # 的加一操作"): the user is already looking at that pane, so the
  # badge would be noise — better to never +1 than to +1 then
  # immediately ack via the wezterm-side focus-ack mechanism.
  # `running` is informational and always upserts.
  if [[ ( "$status" == "waiting" || "$status" == "done" ) \
        && -n "$tmux_socket" && -n "$tmux_session" && -n "$tmux_pane" \
        && -n "${WEZTERM_PANE:-}" ]]; then
    attention_state_focus_path="$(attention_state_path)"
    attention_state_focus_dir="${attention_state_focus_path%/*}/tmux-focus"
    safe_socket="${tmux_socket//\//_}"
    safe_session="${tmux_session#\$}"
    focus_file="$attention_state_focus_dir/${safe_socket}__${safe_session}.txt"
    live_panes_file="${attention_state_focus_path%/*}/live-panes.json"

    tmux_focused_pane=""
    if [[ -f "$focus_file" ]]; then
      tmux_focused_pane="$(tr -d ' \n\r\t' < "$focus_file" 2>/dev/null || printf '')"
    fi
    wezterm_focused_pane_id=""
    if [[ -s "$live_panes_file" ]]; then
      wezterm_focused_pane_id="$(jq -r '.focused_wezterm_pane_id // "" | tostring' "$live_panes_file" 2>/dev/null || printf '')"
    fi

    # Both signals must agree:
    #   - tmux side: the firing tmux pane IS the active pane in its
    #     session (otherwise the user is looking at a different split
    #     within the same wezterm pane).
    #   - wezterm side: the wezterm pane hosting this session IS the
    #     pane the user is currently focused on across all gui windows
    #     (otherwise they are on a different workspace / tab and the
    #     badge is the only signal they get).
    # If either signal is missing or disagrees, fall through to the
    # normal upsert — over-noticing beats under-noticing.
    if [[ -n "$tmux_focused_pane" && "$tmux_focused_pane" == "$tmux_pane" \
          && -n "$wezterm_focused_pane_id" \
          && "$wezterm_focused_pane_id" == "${WEZTERM_PANE:-}" ]]; then
      # User is actually looking at this pane — treat as already
      # acknowledged. Remove any prior entry for this session (could
      # be `running` from an earlier transition that never got a
      # focused stop), otherwise the badge stays stuck on `running`.
      attention_state_remove "$session_id" 2>/dev/null || true
      # Fire the wezterm tick so Lua reloads state_cache from disk and
      # the badge actually drops the just-removed entry. Without this
      # the disk is correct but Lua keeps the cached running/done
      # entry until the next non-skipped hook fires — the user
      # observed `1 running` stuck on the focused pane even after the
      # focus-skip path successfully removed the entry on disk.
      if [[ -e /dev/tty ]]; then
        # shellcheck disable=SC1091
        . "$script_dir/../wezterm-event-lib.sh"
        fs_tick_ms="$(attention_state_now_ms)"
        wezterm_event_send "attention.tick" "$fs_tick_ms" 2>/dev/null || true
        # Diagnostic-only echo: when primary picked OSC, also drop a
        # file-transport copy so wezterm.log records receipt of both
        # paths and a missing OSC arrival is visible. See attention.tick
        # echo handler in titles.lua and docs/event-bus.md.
        if [[ "$(wezterm_event_pick_transport)" == "osc" ]]; then
          wezterm_event_send_file "attention.tick.echo" \
            "$fs_tick_ms" 2>/dev/null || true
        fi
      fi
      runtime_log_info attention "hook focus-skipped upsert" \
        "status=$status" \
        "session_id=$session_id" \
        "wezterm_pane=${WEZTERM_PANE:-}" \
        "tmux_pane=$tmux_pane" \
        "tmux_focused_pane=$tmux_focused_pane" \
        "wezterm_focused_pane_id=$wezterm_focused_pane_id" \
        "removed_existing=1" 2>/dev/null || true
      exit 0
    fi
  fi

  # Normalize waiting_kind the same way the waiting whitelist does so
  # stored values match transition_to_running's elicitation check.
  waiting_kind=""
  if [[ "$status" == "waiting" && -n "$notification_type" ]]; then
    waiting_kind="$(printf '%s' "$notification_type" \
      | tr '[:upper:]' '[:lower:]' \
      | tr '-' '_')"
  fi

  # Sticky display fields for Alt+/ : last real user prompt + provider
  # session name. Stop/waiting overwrite `reason` with end_turn / permission
  # copy; these two must survive so recent rows stay readable.
  last_user_prompt=""
  if [[ -n "$prompt_summary" ]]; then
    last_user_prompt="$prompt_summary"
  elif [[ "$status" == "running" && -n "$reason" \
          && "$reason" != "running…" && "$reason" != "running" ]]; then
    last_user_prompt="$reason"
  fi
  agent_name=""
  if [[ -n "$session_id" && "$session_id" != pane:* ]]; then
    existing_agent_name="$(jq -r --arg sid "$session_id" \
      '.entries[$sid].agent_name // empty' \
      "$(attention_state_path)" 2>/dev/null || true)"
    if [[ -n "$existing_agent_name" ]]; then
      agent_name="$existing_agent_name"
    else
      agent_name="$(attention_resolve_agent_name "$session_id" 2>/dev/null || true)"
    fi
  fi

  attention_state_upsert \
    "$session_id" \
    "${WEZTERM_PANE:-}" \
    "$tmux_socket" \
    "$tmux_session" \
    "$tmux_window" \
    "$tmux_pane" \
    "$status" \
    "$reason" \
    "$git_branch" \
    "$waiting_kind" \
    "$last_user_prompt" \
    "$agent_name" \
    "$tmux_window_name" \
    2>/dev/null || true

  # Spawn the prompt-watcher when a user-action waiting lands.
  # Covers:
  #   - Claude permission_prompt: no hook on Yes/No; without the watcher
  #     the badge sits on ⚠ for the whole tool-execution window.
  #   - Grok/Claude elicitation_dialog: PostToolUse fires while the Ask
  #     dialog is still up, so resolved must NOT clear waiting — the
  #     watcher is the path that flips waiting → running once the dialog
  #     leaves the pane.
  #   - Grok approval_required: same watcher anchors as permission.
  # See docs/agent-attention.md "Limitation: no signal for permission
  # approval" and "Grok elicitation vs PostToolUse".
  #
  # Sticky waiting (a second prompt while we're already waiting) is fine:
  # the watcher's per-pane flock makes the second spawn a no-op.
  _watcher_kind="$waiting_kind"
  if [[ "$status" == "waiting" \
        && -n "$tmux_socket" \
        && -n "$tmux_pane" \
        && "${WEZTERM_ATTENTION_WATCHER_DISABLED:-0}" != "1" ]]; then
    case "$_watcher_kind" in
      permission_prompt|elicitation_dialog|approval_required)
        watcher="$repo_root/scripts/runtime/attention-prompt-watcher.sh"
        if [[ -x "$watcher" ]] && command -v setsid >/dev/null 2>&1; then
          # safe key: stable per-pane identifier for the watcher's lockfile.
          watcher_safe="$(printf '%s|%s' "$tmux_socket" "$tmux_pane" \
                           | sha1sum 2>/dev/null \
                           | cut -c1-16)"
          if [[ -n "$watcher_safe" ]]; then
            setsid bash "$watcher" \
              "$session_id" \
              "${WEZTERM_PANE:-}" \
              "$tmux_socket" \
              "$tmux_session" \
              "$tmux_window" \
              "$tmux_pane" \
              "$git_branch" \
              "$watcher_safe" \
              </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null || true
          fi
        fi
        ;;
    esac
  fi
fi

# Nudge WezTerm. Value carries the timestamp so repeated emits produce
# distinct user-var-changed events. Routed through the unified event bus
# (scripts/runtime/wezterm-event-lib.sh): hook runs in a regular tmux
# pane with a writable /dev/tty, so transport selection lands on OSC
# (sub-frame latency); if /dev/tty is unavailable for some reason, the
# bus transparently falls back to a file event consumed within ~250 ms
# by wezterm's update-status tick. See docs/event-bus.md.
# shellcheck disable=SC1091
. "$script_dir/../wezterm-event-lib.sh"
osc_emitted=0
echo_emitted=0
tick_ms=''
event_transport=''
if [[ -e /dev/tty ]]; then
  tick_ms="$(attention_state_now_ms)"
  if wezterm_event_send "attention.tick" "$tick_ms" 2>/dev/null; then
    osc_emitted=1
  fi
  event_transport="$(wezterm_event_pick_transport)"
  # Diagnostic-only echo: when the primary tick picked OSC, also drop a
  # file-transport `attention.tick.echo` carrying the same tick_ms.
  # The Lua handler logs receipt without calling reload_state, so the
  # user-visible "stale state until next tick" symptom remains for OSC
  # drop investigations — pair `tick received transport=osc value=$ms`
  # against `tick echo received transport=file value=$ms` in wezterm.log
  # to spot a missing OSC arrival.
  if [[ "$event_transport" == "osc" && "$osc_emitted" == "1" ]]; then
    if wezterm_event_send_file "attention.tick.echo" "$tick_ms" 2>/dev/null; then
      echo_emitted=1
    fi
  fi
fi

# Sender-side trace. Pair with attention category in wezterm.log (the
# `tick received` entry from attention.lua) to diagnose the OSC pipeline.
# `entry_ts_ms` is captured at the very top of the script; `elapsed_ms` is
# the in-script latency (jq + flock + git + DCS write). Cross-clock latency
# (hook emit → wezterm tick received) is logged on the Lua side as
# `latency_ms` since both timestamps come from the same Windows clock there
# (tick_ms encodes the linux-side emit time, so this elapsed is also a
# rough WSL↔Windows clock-skew probe).
emit_ts_ms="$(date +%s%3N 2>/dev/null || printf '')"
elapsed_ms=''
if [[ -n "$entry_ts_ms" && -n "$emit_ts_ms" ]]; then
  elapsed_ms=$(( emit_ts_ms - entry_ts_ms ))
fi
runtime_log_info attention "hook emitted agent status" \
  "provider=$provider" \
  "raw_event=$raw_event" \
  "status=$status" \
  "session_id=$session_id" \
  "wezterm_pane=${WEZTERM_PANE:-}" \
  "tmux_socket=$tmux_socket" \
  "tmux_pane=$tmux_pane" \
  "git_branch=$git_branch" \
  "notification_type=${notification_type:-}" \
  "inside_tmux=$([[ -n "${TMUX-}" ]] && echo 1 || echo 0)" \
  "dev_tty_writable=$([[ -e /dev/tty ]] && echo 1 || echo 0)" \
  "osc_emitted=$osc_emitted" \
  "echo_emitted=$echo_emitted" \
  "event_transport=$event_transport" \
  "tick_ms=$tick_ms" \
  "entry_ts_ms=$entry_ts_ms" \
  "elapsed_ms=$elapsed_ms" 2>/dev/null || true

# Workday playback narrative (fail-open).
rev_lc="$(printf '%s' "$raw_event" | tr '[:upper:]' '[:lower:]')"
# shellcheck disable=SC1091
. "$script_dir/../narrative-lib.sh" 2>/dev/null || true
if declare -F narrative_append_event >/dev/null 2>&1; then
  if [[ "$status" == "running" \
        && ( "$rev_lc" == "userpromptsubmit" || -n "$prompt_summary" ) ]]; then
    summary_out="${prompt_summary:-$reason}"
    [[ -z "$summary_out" ]] && summary_out="(user message)"
    summary_out="$(printf '%s' "$summary_out" | tr '\n\r\t|=' '    ' | cut -c1-80)"
    narr_fields=(
      "summary=$summary_out"
      "provider=$provider"
    )
    [[ -n "$session_id" ]] && narr_fields+=("session_id=$session_id")
    [[ -n "$prompt_chars" ]] && narr_fields+=("chars=$prompt_chars")
    [[ -n "$prompt_lines" ]] && narr_fields+=("lines=$prompt_lines")
    [[ -n "${WEZTERM_PANE:-}" ]] && narr_fields+=("pane_id=$WEZTERM_PANE")
    narrative_append_event agent.user_input "${narr_fields[@]}" || true
  fi
  # agent.reply: animation-only signal on Stop/done — no reply body stored.
  if [[ "$status" == "done" ]]; then
    narr_fields=("provider=$provider")
    [[ -n "$session_id" ]] && narr_fields+=("session_id=$session_id")
    [[ -n "${WEZTERM_PANE:-}" ]] && narr_fields+=("pane_id=$WEZTERM_PANE")
    narrative_append_event agent.reply "${narr_fields[@]}" || true
  fi
fi

exit 0
