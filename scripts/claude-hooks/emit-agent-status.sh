#!/usr/bin/env bash
# Claude Code hook emitter. Writes the current agent's state into the shared
# attention state file and nudges WezTerm with an OSC 1337 attention_tick so
# attention.lua re-reads the file and refreshes badges / status counters.
#
# Usage:
#   emit-agent-status.sh running   # UserPromptSubmit hook (agent turn begins)
#   emit-agent-status.sh waiting   # Notification hook
#   emit-agent-status.sh done      # Stop hook
#   emit-agent-status.sh resolved  # PostToolUse hook (waiting → running, else no-op)
#   emit-agent-status.sh cleared   # explicit remove (drops the entry)
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

case "$status" in
  running)  default_reason="running…" ;;
  waiting)  default_reason="input required" ;;
  done)     default_reason="task done" ;;
  cleared)  default_reason="" ;;
  resolved) default_reason="" ;;
  *)        exit 0 ;;
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
# actually require user action. idle_prompt fires after Claude has been idle
# for a while and would otherwise overwrite the done that Stop just wrote,
# making Alt+, chase empty chats. auth_success is one-shot UI confirmation,
# not a per-session state transition.
if [[ "$status" == "waiting" && -n "$notification_type" ]]; then
  case "$notification_type" in
    permission_prompt|elicitation_dialog) ;;
    idle_prompt)
      status="done"
      reason="task done"
      ;;
    auth_success)
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
elif [[ "$status" == "resolved" ]]; then
  # PostToolUse. If the pane was `waiting` on a permission prompt, the
  # tool running to completion is evidence the user allowed it; flip
  # back to `running` so the counter reflects that Claude is still
  # mid-turn. When nothing is waiting (auto-allowed tools, or the entry
  # is already running/done), exit silent so we do not nudge wezterm or
  # log on every tool call.
  if ! attention_state_resolve_waiting "$session_id" 2>/dev/null; then
    exit 0
  fi
else
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
fi

# Nudge WezTerm. Value carries the timestamp so repeated emits produce
# distinct user-var-changed events.
osc_emitted=0
tick_ms=''
if [[ -e /dev/tty ]]; then
  tick_ms="$(attention_state_now_ms)"
  encoded="$(printf '%s' "$tick_ms" | base64 | tr -d '\n')"
  seq="$(printf '\033]1337;SetUserVar=attention_tick=%s\007' "$encoded")"
  if [[ -n "${TMUX-}" ]]; then
    escaped="${seq//$'\033'/$'\033\033'}"
    if printf '\033Ptmux;%s\033\\' "$escaped" >/dev/tty 2>/dev/null; then
      osc_emitted=1
    fi
  else
    if printf '%s' "$seq" >/dev/tty 2>/dev/null; then
      osc_emitted=1
    fi
  fi
fi

# Sender-side trace. Pair with attention category in wezterm.log (the
# `tick received` entry from attention.lua) to diagnose the OSC pipeline.
runtime_log_info attention "hook emitted agent status" \
  "status=$status" \
  "session_id=$session_id" \
  "wezterm_pane=${WEZTERM_PANE:-}" \
  "tmux_socket=$tmux_socket" \
  "tmux_pane=$tmux_pane" \
  "git_branch=$git_branch" \
  "inside_tmux=$([[ -n "${TMUX-}" ]] && echo 1 || echo 0)" \
  "dev_tty_writable=$([[ -e /dev/tty ]] && echo 1 || echo 0)" \
  "osc_emitted=$osc_emitted" \
  "tick_ms=$tick_ms" 2>/dev/null || true

exit 0
