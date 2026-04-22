#!/usr/bin/env bash
# Orchestrate a jump to an agent attention target.
#
# Invoked from tmux user-key bindings (kind-based):
#   run-shell -b "bash .../attention-jump.sh next-waiting"
#   run-shell -b "bash .../attention-jump.sh next-done"
#
# Invoked from the WezTerm Alt+/ InputSelector (explicit target):
#   bash .../attention-jump.sh --session <session_id>
#
# Resolution:
#   1. Prune stale entries (30 min TTL).
#   2. Pick target — by explicit session id, or the next entry matching
#      the requested kind (preferring a wezterm pane different from the
#      caller's so kind-based keys cycle).
#   3. Run `tmux -S <socket> select-window/select-pane` against the
#      target's tmux (same socket path works cross-session as long as the
#      tmux servers share $UID — /tmp/tmux-*).
#   4. Run `wezterm.exe cli activate-pane --pane-id <N>` so WezTerm
#      focuses the right pane. tmux-first ordering means the WezTerm pane
#      already shows the correct tmux window when it becomes active.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$script_dir/attention-state-lib.sh"

want_status=''
explicit_session=''

clear_all=0

case "${1:-next-waiting}" in
  next-waiting) want_status='waiting' ;;
  next-done)    want_status='done' ;;
  --session)
    explicit_session="${2:-}"
    if [[ -z "$explicit_session" ]]; then
      printf 'usage: %s --session <session_id>\n' "$0" >&2
      exit 1
    fi
    ;;
  --clear-all) clear_all=1 ;;
  -h|--help)
    sed -n '3,19p' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s next-waiting|next-done|--session <id>|--clear-all\n' "$0" >&2
    exit 1
    ;;
esac

notify_tmux() {
  local message="$1" socket="${2:-}" target="${3:-}"
  command -v tmux >/dev/null 2>&1 || return 0
  # Prefer the target tmux (on its own socket) when we have one: if the
  # jump activated the target WezTerm pane the user's eyes are now there.
  if [[ -n "$socket" && -n "$target" ]]; then
    if tmux -S "$socket" display-message -t "$target" -d 2000 "$message" 2>/dev/null; then
      return 0
    fi
  fi
  # Fall back to the caller's tmux client when run via `tmux run-shell`.
  if [[ -n "${TMUX-}" ]]; then
    tmux display-message -d 2000 "$message" 2>/dev/null || true
  fi
}

if (( clear_all )); then
  attention_state_truncate
  notify_tmux 'agent-attention: cleared all' '' ''
  exit 0
fi

attention_state_prune 1800000 2>/dev/null || true

current_wezterm_pane="${WEZTERM_PANE:-}"
state_json="$(attention_state_read)"

if [[ -n "$explicit_session" ]]; then
  target_json="$(jq -c --arg sid "$explicit_session" \
    '.entries[$sid] // empty' <<<"$state_json" 2>/dev/null || true)"
else
  target_json="$(jq -c \
    --arg status "$want_status" \
    --arg cur_pane "$current_wezterm_pane" \
    '
      (.entries | to_entries | map(.value) | map(select(.status == $status))) as $all
      | ($all | map(select(.wezterm_pane_id != $cur_pane)) | sort_by(.ts)) as $others
      | ($all | sort_by(.ts)) as $allsorted
      | ($others[0] // $allsorted[0] // empty)
    ' <<<"$state_json" 2>/dev/null || true)"
fi

if [[ -z "$target_json" || "$target_json" == "null" ]]; then
  if [[ -n "$explicit_session" ]]; then
    notify_tmux "agent-attention: no entry for $explicit_session" '' ''
  else
    case "$want_status" in
      waiting) notify_tmux 'agent-attention: no waiting panes' '' '' ;;
      done)    notify_tmux 'agent-attention: no done panes' '' '' ;;
    esac
  fi
  exit 0
fi

read_field() {
  printf '%s' "$target_json" | jq -r --arg k "$1" '.[$k] // empty'
}

target_wezterm_pane="$(read_field wezterm_pane_id)"
target_tmux_socket="$(read_field tmux_socket)"
target_tmux_session="$(read_field tmux_session)"
target_tmux_window="$(read_field tmux_window)"
target_tmux_pane="$(read_field tmux_pane)"
target_reason="$(read_field reason)"
target_status="$(read_field status)"

# Fallback: entries written before WEZTERM_PANE was propagated through tmux
# have an empty wezterm_pane_id. If the target tmux session carries the
# variable in its environment (populated either by update-environment on
# attach or by open-project-session.sh on bootstrap), recover the pane id
# from there so we can still activate the correct WezTerm pane.
if [[ -z "$target_wezterm_pane" && -n "$target_tmux_socket" && -n "$target_tmux_session" ]]; then
  env_line="$(tmux -S "$target_tmux_socket" show-environment -t "$target_tmux_session" WEZTERM_PANE 2>/dev/null || true)"
  if [[ "$env_line" =~ ^WEZTERM_PANE=(.+)$ ]]; then
    target_wezterm_pane="${BASH_REMATCH[1]}"
  fi
fi

if [[ -n "$target_tmux_socket" && -n "$target_tmux_window" ]]; then
  tmux -S "$target_tmux_socket" select-window -t "$target_tmux_window" 2>/dev/null || true
  if [[ -n "$target_tmux_pane" ]]; then
    tmux -S "$target_tmux_socket" select-pane -t "$target_tmux_pane" 2>/dev/null || true
  fi
fi

wezterm_activated=0
if [[ -n "$target_wezterm_pane" ]] && command -v wezterm.exe >/dev/null 2>&1; then
  if wezterm.exe cli activate-pane --pane-id "$target_wezterm_pane" >/dev/null 2>&1; then
    wezterm_activated=1
  fi
fi

if (( wezterm_activated )); then
  exit 0
fi

if [[ -n "$target_tmux_socket" && -n "$target_tmux_window" ]]; then
  notify_tmux 'agent-attention: tmux-only jump (WezTerm pane unknown)' \
    "$target_tmux_socket" "$target_tmux_window"
else
  notify_tmux 'agent-attention: target incomplete, no jump performed' '' ''
fi
exit 0
