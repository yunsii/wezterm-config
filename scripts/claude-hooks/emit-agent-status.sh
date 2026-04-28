#!/usr/bin/env bash
# Claude Code hook emitter. Writes the current agent's state into the shared
# attention state file and nudges WezTerm with an OSC 1337 attention_tick so
# attention.lua re-reads the file and refreshes badges / status counters.
#
# Usage:
#   emit-agent-status.sh running     # UserPromptSubmit hook (agent turn begins)
#   emit-agent-status.sh waiting     # Notification hook
#   emit-agent-status.sh done        # Stop hook
#   emit-agent-status.sh resolved    # PreToolUse + PostToolUse hooks.
#                                    # PostToolUse: waiting → running when an
#                                    #   approved tool completes (the only
#                                    #   signal we get; Claude Code fires no
#                                    #   hook on the approval keystroke).
#                                    # PreToolUse: done → running on Monitor
#                                    #   wake-up only (fires once before the
#                                    #   permission prompt — see
#                                    #   docs/agent-attention.md "Limitation:
#                                    #   no signal for permission approval").
#                                    # Both: running is a no-op.
#   emit-agent-status.sh cleared     # explicit remove (drops the entry)
#   emit-agent-status.sh pane-evict  # SessionStart source=clear hook — drop every
#                                    # entry on the current (tmux_socket, tmux_pane)
#                                    # except the new session_id in the payload.
#
# Optional stdin: the hook JSON payload. When jq is available and stdin
# carries JSON, the script extracts .session_id for keying and
# .message / .stop_reason / .prompt for the human-readable reason.
#
# Fails open: any step that fails is silently skipped so hook execution
# never breaks the agent flow.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/attention-state-lib.sh"
# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/runtime-log-lib.sh"
WEZTERM_RUNTIME_LOG_SOURCE="emit-agent-status.sh"

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

session_id=""
reason="$default_reason"
notification_type=""
if [[ ! -t 0 ]] && command -v jq >/dev/null 2>&1; then
  stdin_payload="$(cat || true)"
  if [[ -n "$stdin_payload" ]]; then
    session_id="$(printf '%s' "$stdin_payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
    # .prompt carries the user's new prompt on UserPromptSubmit. Take the
    # first line and cap it so the Alt+/ overlay label stays readable.
    extracted="$(printf '%s' "$stdin_payload" \
      | jq -r '.message // .stop_reason // (.prompt | if . == null then empty else (split("\n")[0] | .[0:80]) end) // empty' \
      2>/dev/null || true)"
    if [[ -n "$extracted" ]]; then
      reason="$extracted"
    fi
    notification_type="$(printf '%s' "$stdin_payload" | jq -r '.notification_type // empty' 2>/dev/null || true)"
  fi
fi

# Notification hook disambiguation: only permission_prompt / elicitation_dialog
# actually require user action. idle_prompt fires whenever Claude has been
# idle for a while — which is not the same as "turn finished" (Stop owns that
# signal) and not the same as "user must act" (waiting). In particular, a
# persistent Monitor subscription can hold the agent idle mid-turn, so
# writing done here would silently flip a still-running entry to done and
# PostToolUse could not recover it (see attention_state_transition_to_running).
# Exit without touching state, leaving the existing running / waiting / done
# unchanged. auth_success is one-shot UI confirmation, not a transition.
if [[ "$status" == "waiting" && -n "$notification_type" ]]; then
  case "$notification_type" in
    permission_prompt|elicitation_dialog) ;;
    idle_prompt|auth_success)
      runtime_log_info attention "notification ignored" \
        "status=$status" \
        "notification_type=$notification_type" \
        "session_id=${session_id:-}" \
        "wezterm_pane=${WEZTERM_PANE:-}" \
        "tmux_pane=${TMUX_PANE:-}" \
        "entry_ts_ms=$entry_ts_ms" 2>/dev/null || true
      exit 0
      ;;
  esac
fi

# Fallback key when hooks run outside Claude's piped payload (e.g. test
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
if [[ -n "${TMUX-}" ]] && command -v tmux >/dev/null 2>&1; then
  # Target our own pane explicitly. Without -t, tmux returns the client's
  # currently active pane regardless of which hook fired, so every entry
  # would collapse onto whichever pane the user is looking at.
  target_pane="${TMUX_PANE:-}"
  if [[ -n "$target_pane" ]]; then
    tmux_meta="$(tmux display-message -p -t "$target_pane" -F '#{socket_path}|#{session_name}|#{window_id}|#{pane_id}' 2>/dev/null || true)"
  fi
  if [[ -z "${tmux_meta:-}" ]]; then
    tmux_meta="$(tmux display-message -p -F '#{socket_path}|#{session_name}|#{window_id}|#{pane_id}' 2>/dev/null || true)"
  fi
  if [[ -n "${tmux_meta:-}" ]]; then
    IFS='|' read -r tmux_socket tmux_session tmux_window tmux_pane <<<"$tmux_meta"
  fi
fi

# Resolve the git branch from the best available cwd. CLAUDE_PROJECT_DIR
# is set by Claude Code for hook subprocesses; fall back to the tmux pane's
# current_path, then the hook's own $PWD.
git_branch=""
if command -v git >/dev/null 2>&1; then
  git_dir="${CLAUDE_PROJECT_DIR:-}"
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
  # fresh post-/clear session; any entries still parked on this tmux
  # pane belong to the discarded pre-/clear session and will never get
  # their own Stop. Evict them all, but preserve the new session_id
  # defensively in case a race re-creates it before we hold the lock.
  attention_state_evict_pane "$tmux_socket" "$tmux_pane" "$session_id" \
    2>/dev/null || true
elif [[ "$status" == "resolved" ]]; then
  # Wired to BOTH PreToolUse and PostToolUse. The two hooks fire at
  # different lifecycle points and cover different transitions; they
  # share this branch only because the helper handles every case.
  #
  #   PreToolUse  fires once when the agent decides to call a tool —
  #     BEFORE any permission_prompt and BEFORE the tool starts. Claude
  #     Code does not fire it again when the user approves the prompt.
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
        . "$script_dir/../runtime/wezterm-event-lib.sh"
        wezterm_event_send "attention.tick" \
          "$(attention_state_now_ms)" 2>/dev/null || true
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
    2>/dev/null || true

  # Spawn the prompt-watcher when a permission_prompt raises waiting.
  # Claude Code does not fire any hook when the user clicks Yes/No, so
  # absent the watcher the badge would sit on `⚠ waiting` for the entire
  # tool-execution window — even if the user already approved and the
  # bash is now running in the background via ctrl+b ctrl+b. The watcher
  # tails the pane content for the prompt anchor and flips waiting →
  # running once the prompt is no longer on screen. See
  # docs/agent-attention.md "Limitation: no signal for permission
  # approval" for full rationale and failure modes.
  #
  # Sticky waiting (a second permission_prompt while we're already
  # waiting) is fine: the watcher's per-pane flock makes the second
  # spawn a no-op, and the original watcher is still polling.
  if [[ "$status" == "waiting" \
        && "$notification_type" == "permission_prompt" \
        && -n "$tmux_socket" \
        && -n "$tmux_pane" \
        && "${WEZTERM_ATTENTION_WATCHER_DISABLED:-0}" != "1" ]]; then
    watcher="$repo_root/scripts/runtime/attention-prompt-watcher.sh"
    if [[ -x "$watcher" ]] && command -v setsid >/dev/null 2>&1; then
      # safe key: stable per-pane identifier for the watcher's lockfile.
      # sha1 over (socket, pane) is overkill but cheap and avoids
      # collisions across tmux servers / pane-id reuse across sessions.
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
. "$script_dir/../runtime/wezterm-event-lib.sh"
osc_emitted=0
tick_ms=''
event_transport=''
if [[ -e /dev/tty ]]; then
  tick_ms="$(attention_state_now_ms)"
  if wezterm_event_send "attention.tick" "$tick_ms" 2>/dev/null; then
    osc_emitted=1
  fi
  event_transport="$(wezterm_event_pick_transport)"
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
  "event_transport=$event_transport" \
  "tick_ms=$tick_ms" \
  "entry_ts_ms=$entry_ts_ms" \
  "elapsed_ms=$elapsed_ms" 2>/dev/null || true

exit 0
