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
# Invoked from the tmux `session-closed` hook to archive every active
# entry on a tmux session that just died. Zero-latency replacement for
# the wezterm-side reachability sweep when tmux can tell us outright:
#   bash .../attention-jump.sh --forget-session <tmux_session_name>
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

# Force the landed session's status line to recompute when a jump's
# select-window / select-pane were no-ops (target already active — you
# left the session parked there). In that case tmux's
# session-window-changed / window-pane-changed hooks never fire and the
# branch/worktree segment would lag until client-focus-in or the 30s
# poll — the "Alt+. jump but status is stale" symptom. --no-debounce
# bypasses the force-refresh debounce so this one-shot is never
# collapsed into an unrelated recent refresh. Callers that already
# moved the window/pane must NOT call this: the hooks refresh with the
# normal 2s debounce, and stacking --no-debounce on every Alt+l
# stampeded ~300ms git/status probes. All wezterm-managed sessions
# share the default tmux server, so tmux-status-refresh.sh's bare
# `tmux` calls resolve the session named here (matching the hook path).
refresh_jump_target_status() {
  local socket="$1" window="$2"
  [[ -n "$socket" && -n "$window" ]] || return 0
  local session=''
  session="$(tmux -S "$socket" display-message -p -t "$window" '#{session_name}' 2>/dev/null || true)"
  [[ -n "$session" ]] || return 0
  bash "$script_dir/tmux-status-refresh.sh" \
    --session "$session" --window "$window" \
    --force --no-debounce --refresh-client >/dev/null 2>&1 || true
}

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
    # Detect no-op selects BEFORE changing anything. When select-window /
    # select-pane actually move focus, session-window-changed /
    # window-pane-changed already run tmux-status-refresh.sh --force
    # (with the 2s debounce). Forcing --no-debounce here on every Alt+l
    # stampeded git/status probes (~300ms) and made rapid cycling feel
    # dead. Only pay the forced refresh when both selects are no-ops —
    # the original "parked on target, hooks never fire" case.
    win_was_active="$(tmux -S "$direct_socket" display-message -p -t "$direct_window" '#{window_active}' 2>/dev/null || true)"
    pane_was_active=''
    if [[ -n "$direct_pane" ]]; then
      pane_was_active="$(tmux -S "$direct_socket" display-message -p -t "$direct_pane" '#{pane_active}' 2>/dev/null || true)"
    fi

    tmux -S "$direct_socket" select-window -t "$direct_window" 2>/dev/null || true
    pane_ok=0
    if [[ -n "$direct_pane" ]]; then
      if tmux -S "$direct_socket" list-panes -t "$direct_window" -F '#{pane_id}' 2>/dev/null \
           | grep -Fxq "$direct_pane"; then
        tmux -S "$direct_socket" select-pane -t "$direct_pane" 2>/dev/null || true
        pane_ok=1
      fi
    fi
    if (( ! pane_ok )); then
      live_pane="$(tmux -S "$direct_socket" list-panes -t "$direct_window" -F '#{pane_id}' 2>/dev/null | head -n1 || true)"
      if [[ -n "$live_pane" ]]; then
        tmux -S "$direct_socket" select-pane -t "$live_pane" 2>/dev/null || true
      fi
      # Fell back to a different pane than requested — treat as a real
      # change so we don't force-refresh on top of the hook path.
      pane_was_active='0'
    fi

    need_forced_refresh=0
    if [[ "$win_was_active" == "1" ]]; then
      if [[ -z "$direct_pane" || "$pane_was_active" == "1" ]]; then
        need_forced_refresh=1
      fi
    fi
    if (( need_forced_refresh )); then
      refresh_jump_target_status "$direct_socket" "$direct_window"
    fi
  fi
  exit 0
fi

# shellcheck disable=SC1091
. "$script_dir/attention-state-lib.sh"
# shellcheck disable=SC1091
. "$script_dir/wezterm-event-lib.sh"

# After a state-mutating call (truncate, remove, prune, recent-remove),
# push an attention.tick event so the wezterm side reloads `state.json`
# and re-renders the right-status counter immediately. Without this the
# counter only catches up on the next 250 ms update-status tick — fine
# for most cases but visibly laggy for `--clear-all` (the doc previously
# called this out as a ~1s catch-up window). The bus picks the
# transport automatically: foreground hooks land on OSC (sub-frame),
# `tmux run-shell -b` and other detached callers land on file (≤250 ms,
# but still better than waiting for the next periodic reload). See
# docs/event-bus.md "Why event-driven, not polling".
nudge_wezterm_tick() {
  wezterm_event_send "attention.tick" "$(attention_state_now_ms)" 2>/dev/null || true
}

want_status=''
explicit_session=''

clear_all=0
forget=0
forget_delay=0
forget_if_ts=''
forget_session_only=0
forget_session_name=''
prune_only=0
prune_ttl=1800000
recent_jump=0
recent_archived_ts=''

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
  --forget-session)
    forget_session_name="${2:-}"
    if [[ -z "$forget_session_name" ]]; then
      printf 'usage: %s --forget-session <tmux_session_name>\n' "$0" >&2
      exit 1
    fi
    forget_session_only=1
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
    printf 'usage: %s next-waiting|next-done|--session <id>|--forget <id> [--delay N] [--only-if-ts TS]|--forget-session <tmux_session>|--prune [--ttl MS]|--clear-all|--recent --session <id> [--archived-ts MS]|--direct ...\n' "$0" >&2
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
  nudge_wezterm_tick
  notify_tmux 'agent-attention: cleared all' '' ''
  exit 0
fi

if (( prune_only )); then
  # Periodic prune does both jobs: TTL sweep (entries idle past 30 min)
  # plus reachability sweep (entries whose tmux pane is gone — pane
  # killed, agent crashed, /clear didn't reach the right session, etc.
  # Without this the entry sits in entries[] until the 30 min TTL even
  # though the pane vanished minutes ago). The alive map is collected
  # here, not in emit-agent-status.sh, so the hook hot path never pays
  # the per-socket `tmux list-panes -a` fork cost — only the once-per-
  # minute background prune that titles.lua schedules does.
  alive_panes_json="$(attention_state_collect_alive_panes 2>/dev/null || printf '{}')"
  attention_state_prune "$prune_ttl" "$alive_panes_json" 2>/dev/null || true
  nudge_wezterm_tick
  exit 0
fi

if (( forget_session_only )); then
  attention_state_forget_session "$forget_session_name" 2>/dev/null || true
  nudge_wezterm_tick
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
  nudge_wezterm_tick
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

  # Window-existence probe. Archived pane ids are routinely recycled
  # after split/kill; as long as the worktree window still exists we
  # can select-window and land on a live pane inside it. Only drop the
  # recent row when the window (or session) itself is gone.
  window_alive=0
  if [[ -n "$target_tmux_socket" && -n "$target_tmux_session" && -n "$target_tmux_window" ]]; then
    if tmux -S "$target_tmux_socket" has-session -t "$target_tmux_session" 2>/dev/null; then
      if tmux -S "$target_tmux_socket" list-windows -t "$target_tmux_session" -F '#{window_id}' 2>/dev/null \
           | grep -Fxq "$target_tmux_window"; then
        window_alive=1
      fi
    fi
  fi

  if (( ! window_alive )); then
    attention_state_recent_remove "$explicit_session" "${target_archived_ts:-0}" 2>/dev/null || true
    nudge_wezterm_tick
    notify_tmux 'agent-attention: window no longer exists, removed from recent' '' ''
    exit 0
  fi

  if [[ -n "$target_tmux_window" ]]; then
    tmux -S "$target_tmux_socket" select-window -t "$target_tmux_window" 2>/dev/null || true
    pane_ok=0
    if [[ -n "$target_tmux_pane" ]]; then
      if tmux -S "$target_tmux_socket" list-panes -t "$target_tmux_window" -F '#{pane_id}' 2>/dev/null \
           | grep -Fxq "$target_tmux_pane"; then
        tmux -S "$target_tmux_socket" select-pane -t "$target_tmux_pane" 2>/dev/null || true
        pane_ok=1
      fi
    fi
    if (( ! pane_ok )); then
      live_pane="$(tmux -S "$target_tmux_socket" list-panes -t "$target_tmux_window" -F '#{pane_id}' 2>/dev/null | head -n1 || true)"
      if [[ -n "$live_pane" ]]; then
        tmux -S "$target_tmux_socket" select-pane -t "$live_pane" 2>/dev/null || true
      fi
    fi
    refresh_jump_target_status "$target_tmux_socket" "$target_tmux_window"
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
  pane_ok=0
  if [[ -n "$target_tmux_pane" ]]; then
    if tmux -S "$target_tmux_socket" list-panes -t "$target_tmux_window" -F '#{pane_id}' 2>/dev/null \
         | grep -Fxq "$target_tmux_pane"; then
      tmux -S "$target_tmux_socket" select-pane -t "$target_tmux_pane" 2>/dev/null || true
      pane_ok=1
    fi
  fi
  if (( ! pane_ok )); then
    live_pane="$(tmux -S "$target_tmux_socket" list-panes -t "$target_tmux_window" -F '#{pane_id}' 2>/dev/null | head -n1 || true)"
    if [[ -n "$live_pane" ]]; then
      tmux -S "$target_tmux_socket" select-pane -t "$live_pane" 2>/dev/null || true
    fi
  fi
  refresh_jump_target_status "$target_tmux_socket" "$target_tmux_window"
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
