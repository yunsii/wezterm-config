#!/usr/bin/env bash
# wezterm-event-lib.sh — unified producer for wezterm-bound events.
#
# Two transports:
#   - OSC 1337 SetUserVar=we_<name>=<base64(payload)>, DCS-wrapped under tmux.
#     Sub-frame latency. Requires the caller to have a controlling tty
#     whose DCS pass-through reaches WezTerm — i.e. a regular tmux pane,
#     NOT a popup pty (tmux's `display-popup -E` does not forward
#     popup output's DCS up to the parent client tty).
#   - File trigger at <state>/wezterm-events/<name>.json, atomic
#     temp+rename. Up to 250 ms latency (one update-status tick on the
#     wezterm side). Works from any context, including popup pty and
#     fully detached background processes.
#
# Auto transport selection (override-able):
#   ① $WEZTERM_EVENT_TRANSPORT=osc|file (explicit override; bypasses 2/3)
#   ② $WEZTERM_EVENT_FORCE_FILE=1 (popup wrappers inject this)
#   ③ /dev/tty writable → osc, otherwise file
#
# Usage:
#   . "$repo/scripts/runtime/wezterm-event-lib.sh"
#   wezterm_event_send "attention.tick" "$tick_ms"
#   wezterm_event_send "attention.jump" "v1|jump|<sid>|..."
#
# Event names use dotted hierarchy `<area>.<verb>[.<qualifier>]` and are
# restricted to [a-zA-Z0-9_.]. The on-wire OSC user-var name replaces
# `.` with `_` (so `attention.tick` becomes `we_attention_tick`); the
# file-trigger filename keeps the dot (`<dir>/attention.tick.json`).
# Both directions are reversible by the wezterm-side dispatcher.
#
# See docs/event-bus.md for the full design rationale and the table of
# registered events.

set -u

__WEZTERM_EVENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$__WEZTERM_EVENT_LIB_DIR/windows-runtime-paths-lib.sh"

__WEZTERM_EVENT_DIR_CACHED=""

# Resolve the file-trigger directory once. Same wezterm-runtime path
# detection used everywhere else, so all transports share one state root.
wezterm_event_dir() {
  if [[ -n "$__WEZTERM_EVENT_DIR_CACHED" ]]; then
    printf '%s' "$__WEZTERM_EVENT_DIR_CACHED"
    return 0
  fi
  if [[ -n "${WEZBUS_EVENT_DIR:-}" ]]; then
    __WEZTERM_EVENT_DIR_CACHED="$WEZBUS_EVENT_DIR"
  elif windows_runtime_detect_paths 2>/dev/null; then
    __WEZTERM_EVENT_DIR_CACHED="$WINDOWS_RUNTIME_STATE_WSL/state/wezterm-events"
  else
    local state_root="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
    __WEZTERM_EVENT_DIR_CACHED="$state_root/state/wezterm-events"
  fi
  printf '%s' "$__WEZTERM_EVENT_DIR_CACHED"
}

# Transport picker. Returns "osc" or "file" on stdout.
wezterm_event_pick_transport() {
  case "${WEZTERM_EVENT_TRANSPORT:-auto}" in
    osc)  printf 'osc';  return 0 ;;
    file) printf 'file'; return 0 ;;
  esac
  if [[ -n "${WEZTERM_EVENT_FORCE_FILE:-}" ]]; then
    printf 'file'
    return 0
  fi
  # /dev/tty writability is the cheapest, most reliable signal of "I have
  # a controlling terminal whose output stream tmux will pass through".
  # Hooks invoked from regular panes pass; `tmux run-shell -b` and popup
  # subprocesses fail, falling through to file.
  if { : >/dev/tty; } 2>/dev/null; then
    printf 'osc'
  else
    printf 'file'
  fi
}

wezterm_event_user_var() {
  local name="$1"
  printf 'we_%s' "${name//./_}"
}

# Emit OSC 1337 SetUserVar to /dev/tty. Caller already passed the
# transport check, so /dev/tty is writable.
wezterm_event_send_osc() {
  local name="$1" payload="$2" var encoded seq escaped
  var="$(wezterm_event_user_var "$name")"
  encoded="$(printf '%s' "$payload" | base64 | tr -d '\n')"
  seq="$(printf '\033]1337;SetUserVar=%s=%s\007' "$var" "$encoded")"
  if [[ -n "${TMUX-}" ]]; then
    escaped="${seq//$'\033'/$'\033\033'}"
    printf '\033Ptmux;%s\033\\' "$escaped" > /dev/tty 2>/dev/null
  else
    printf '%s' "$seq" > /dev/tty 2>/dev/null
  fi
}

# Drop a JSON envelope at <event_dir>/<name>.json via tmp+rename so the
# wezterm-side reader never sees a partial write. Multiple events may
# coexist in the directory; each filename is its own event slot.
wezterm_event_send_file() {
  local name="$1" payload="$2" dir target tmp ts esc
  dir="$(wezterm_event_dir)"
  mkdir -p "$dir" 2>/dev/null || return 1
  target="$dir/${name}.json"
  tmp="${target}.tmp.$$"
  ts="$(date +%s%3N 2>/dev/null || printf '0')"
  esc="${payload//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  printf '{"version":1,"name":"%s","payload":"%s","ts":%s}\n' "$name" "$esc" "$ts" > "$tmp" 2>/dev/null || return 1
  mv "$tmp" "$target" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Public producer entry point. Returns 0 on success, non-zero on
# transport failure (bad name, write failure, etc.).
wezterm_event_send() {
  local name="$1" payload="${2-}"
  if [[ -z "$name" ]]; then
    return 1
  fi
  case "$(wezterm_event_pick_transport)" in
    osc)  wezterm_event_send_osc  "$name" "$payload" ;;
    file) wezterm_event_send_file "$name" "$payload" ;;
    *)    return 1 ;;
  esac
}
