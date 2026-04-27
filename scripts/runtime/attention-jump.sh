#!/usr/bin/env bash
# Orchestrate a jump to an agent attention target.
#
# Invoked from tmux user-key bindings (kind-based):
#   run-shell -b "bash .../attention-jump.sh next-waiting"
#   run-shell -b "bash .../attention-jump.sh next-done"
#
# Invoked from the WezTerm Alt+,/Alt+./Alt+/ fast path (Lua already
# activated the WezTerm pane via mux, so we just sync tmux):
#   bash .../attention-jump.sh --direct \
#     --tmux-socket <path> --tmux-window <id> [--tmux-pane <id>]
#
# Invoked from tooling or recovery flows that still need a state lookup:
#   bash .../attention-jump.sh --session <session_id>
#
# Invoked from Alt+./Alt+/ after a successful jump to a `done` entry, to
# drop the entry after a short grace window:
#   bash .../attention-jump.sh --forget <session_id> \
#     [--delay <seconds>] [--only-if-ts <epoch_ms>]
# The --only-if-ts guard is what keeps the delayed forget from eating a
# fresher `done` that the same session_id produced during the grace window.
#
# Invoked periodically by attention.lua from WezTerm's update-status tick
# to clean up entries that have aged past the TTL when no hook has fired:
#   bash .../attention-jump.sh --prune [--ttl <ms>]
#
# Invoked by the Alt+/ picker when the user selects a recent (archived)
# entry. Probes pane existence first; if alive, jumps as usual; if the
# tmux pane is gone, removes the row from .recent[] and toasts:
#   bash .../attention-jump.sh --recent --session <id> --archived-ts <ms>
#
# Resolution (slow path):
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
#
# The fast `--direct` path skips steps 1, 2, and 4 entirely: the caller
# is responsible for WezTerm pane activation and already has the tmux
# coordinates, so this script just issues the two tmux commands.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Fast path: caller already has the tmux coordinates (Lua looked them up
# from the in-process state cache) and has already activated the WezTerm
# pane. We only need to sync tmux's selection. Skip the state lib, jq,
# and wezterm.exe invocations entirely so this returns in one tmux
# round-trip.
if [[ "${1:-}" == "--direct" ]]; then
  shift
  direct_socket=''
  direct_window=''
  direct_pane=''
  while (( $# )); do
    case "$1" in
      --tmux-socket) direct_socket="${2:-}"; shift 2 ;;
      --tmux-window) direct_window="${2:-}"; shift 2 ;;
      --tmux-pane)   direct_pane="${2:-}";   shift 2 ;;
      *) printf 'unknown --direct arg: %s\n' "$1" >&2; exit 1 ;;
    esac
  done
  if [[ -n "$direct_socket" && -n "$direct_window" ]]; then
    tmux -S "$direct_socket" select-window -t "$direct_window" 2>/dev/null || true
    if [[ -n "$direct_pane" ]]; then
      tmux -S "$direct_socket" select-pane -t "$direct_pane" 2>/dev/null || true
    fi
  fi
  exit 0
fi

# shellcheck disable=SC1091
. "$script_dir/attention-state-lib.sh"

want_status=''
explicit_session=''

clear_all=0
forget=0
forget_delay=0
forget_if_ts=''
prune_only=0
prune_ttl=1800000
recent_jump=0
recent_archived_ts=''

case "${1:-next-waiting}" in
  --print-trigger-path)
    # Picker calls this to learn where to write its jump-trigger.json.
    # Centralising the path here means picker doesn't need to redo the
    # WSL/Windows path detection in attention-state-lib.
    . "$script_dir/attention-state-lib.sh"
    state_path="$(attention_state_path)"
    printf '%s/jump-trigger.json' "${state_path%/*}"
    exit 0
    ;;
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
  --forget)
    explicit_session="${2:-}"
    if [[ -z "$explicit_session" ]]; then
      printf 'usage: %s --forget <session_id> [--delay <seconds>] [--only-if-ts <epoch_ms>]\n' "$0" >&2
      exit 1
    fi
    forget=1
    shift 2
    while (( $# )); do
      case "$1" in
        --delay)       forget_delay="${2:-0}";    shift 2 ;;
        --only-if-ts)  forget_if_ts="${2:-}";     shift 2 ;;
        *) printf 'unknown --forget arg: %s\n' "$1" >&2; exit 1 ;;
      esac
    done
    ;;
  --prune)
    prune_only=1
    shift
    while (( $# )); do
      case "$1" in
        --ttl) prune_ttl="${2:-1800000}"; shift 2 ;;
        *) printf 'unknown --prune arg: %s\n' "$1" >&2; exit 1 ;;
      esac
    done
    ;;
  --recent)
    recent_jump=1
    shift
    while (( $# )); do
      case "$1" in
        --session)      explicit_session="${2:-}";   shift 2 ;;
        --archived-ts)  recent_archived_ts="${2:-}"; shift 2 ;;
        *) printf 'unknown --recent arg: %s\n' "$1" >&2; exit 1 ;;
      esac
    done
    if [[ -z "$explicit_session" ]]; then
      printf 'usage: %s --recent --session <id> [--archived-ts <ms>]\n' "$0" >&2
      exit 1
    fi
    ;;
  -h|--help)
    sed -n '3,42p' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s next-waiting|next-done|--session <id>|--forget <id> [--delay N] [--only-if-ts TS]|--prune [--ttl MS]|--clear-all|--recent --session <id> [--archived-ts MS]|--direct ...\n' "$0" >&2
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

if (( prune_only )); then
  attention_state_prune "$prune_ttl" 2>/dev/null || true
  exit 0
fi

if (( forget )); then
  if [[ "$forget_delay" =~ ^[0-9]+$ ]] && (( forget_delay > 0 )); then
    sleep "$forget_delay"
  fi
  # Guard against wiping a fresher entry that reused this session_id during
  # the grace window: the caller passes the ts observed at jump time, and we
  # skip the remove when the current ts no longer matches.
  if [[ -n "$forget_if_ts" ]]; then
    state_path="$(attention_state_path)"
    current_ts=''
    if [[ -f "$state_path" ]]; then
      current_ts="$(jq -r --arg sid "$explicit_session" \
        '.entries[$sid].ts // empty' <"$state_path" 2>/dev/null || true)"
    fi
    if [[ "$current_ts" != "$forget_if_ts" ]]; then
      exit 0
    fi
  fi
  attention_state_remove "$explicit_session" 2>/dev/null || true
  exit 0
fi

if (( recent_jump )); then
  state_json="$(attention_state_read)"
  # Pick the matching recent entry. When --archived-ts is supplied the
  # picker has disambiguated multiple recent rows for the same session
  # (same agent on different panes); without it, fall back to the most-
  # recently archived row for the session.
  if [[ -n "$recent_archived_ts" ]]; then
    target_json="$(jq -c --arg sid "$explicit_session" --argjson ats "$recent_archived_ts" \
      '(.recent // []) | map(select(.session_id == $sid and (.archived_ts // 0) == $ats)) | .[0] // empty' \
      <<<"$state_json" 2>/dev/null || true)"
  else
    target_json="$(jq -c --arg sid "$explicit_session" \
      '(.recent // []) | map(select(.session_id == $sid)) | sort_by(-(.archived_ts // 0)) | .[0] // empty' \
      <<<"$state_json" 2>/dev/null || true)"
  fi
  if [[ -z "$target_json" || "$target_json" == "null" ]]; then
    notify_tmux "agent-attention: recent entry $explicit_session not found" '' ''
    exit 0
  fi
  read_field() { printf '%s' "$target_json" | jq -r --arg k "$1" '.[$k] // empty'; }
  target_wezterm_pane="$(read_field wezterm_pane_id)"
  target_tmux_socket="$(read_field tmux_socket)"
  target_tmux_session="$(read_field tmux_session)"
  target_tmux_window="$(read_field tmux_window)"
  target_tmux_pane="$(read_field tmux_pane)"
  target_archived_ts="$(read_field archived_ts)"

  # Pane-existence probe. Both checks are scoped to the recorded socket
  # so we never accidentally jump to a different agent pane that reused
  # the same `%N` id under a different tmux server.
  pane_alive=0
  if [[ -n "$target_tmux_socket" && -n "$target_tmux_session" && -n "$target_tmux_pane" ]]; then
    if tmux -S "$target_tmux_socket" has-session -t "$target_tmux_session" 2>/dev/null; then
      if tmux -S "$target_tmux_socket" list-panes -s -t "$target_tmux_session" -F '#{pane_id}' 2>/dev/null \
           | grep -Fxq "$target_tmux_pane"; then
        pane_alive=1
      fi
    fi
  fi

  if (( ! pane_alive )); then
    attention_state_recent_remove "$explicit_session" "${target_archived_ts:-0}" 2>/dev/null || true
    notify_tmux 'agent-attention: pane no longer exists, removed from recent' '' ''
    exit 0
  fi

  if [[ -n "$target_tmux_window" ]]; then
    tmux -S "$target_tmux_socket" select-window -t "$target_tmux_window" 2>/dev/null || true
    tmux -S "$target_tmux_socket" select-pane -t "$target_tmux_pane" 2>/dev/null || true
  fi

  # Recent entries' wezterm_pane_id is whatever was live at archive time.
  # WezTerm assigns fresh pane ids on every restart (mux state is in-process,
  # tmux survives), so for any recent entry that pre-dates the latest
  # WezTerm boot the stored id points at nothing — wezterm.exe activate-pane
  # would silently rc=0 on a phantom pane and the user sees "tmux moved
  # but the GUI didn't follow". The session-env WEZTERM_PANE is refreshed
  # by tmux.conf's update-environment + client-focus-in / open-project-
  # session.sh seeding, so it tracks the LIVE pane that hosts this tmux
  # session — prefer it, and only fall back to the stored id when the env
  # is missing (older sessions whose attach predates the propagation chain).
  live_wezterm_pane=''
  env_line="$(tmux -S "$target_tmux_socket" show-environment -t "$target_tmux_session" WEZTERM_PANE 2>/dev/null || true)"
  if [[ "$env_line" =~ ^WEZTERM_PANE=(.+)$ ]]; then
    live_wezterm_pane="${BASH_REMATCH[1]}"
  fi
  effective_wezterm_pane="${live_wezterm_pane:-$target_wezterm_pane}"

  wezterm_activated=0
  if [[ -n "$effective_wezterm_pane" ]] && command -v wezterm.exe >/dev/null 2>&1; then
    if wezterm.exe cli activate-pane --pane-id "$effective_wezterm_pane" >/dev/null 2>&1; then
      wezterm_activated=1
    fi
  fi

  if (( ! wezterm_activated )); then
    notify_tmux 'agent-attention: tmux-only recent jump (WezTerm pane unknown)' \
      "$target_tmux_socket" "$target_tmux_window"
  fi
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
