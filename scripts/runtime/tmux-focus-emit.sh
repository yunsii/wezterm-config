#!/usr/bin/env bash
# Record the active tmux pane for a (socket, session) so attention.lua
# can require tmux-pane-level focus, not just WezTerm pane focus, before
# auto-acking a `done` entry whose wezterm_pane_id matches.
#
# Invoked from tmux hooks in tmux.conf:
#   set-hook -g  after-select-pane "run-shell -b 'bash .../tmux-focus-emit.sh \
#     #{q:socket_path} #{q:session_name} #{q:pane_id}'"
#   set-hook -ga client-focus-in   "run-shell -b 'bash .../tmux-focus-emit.sh \
#     #{q:socket_path} #{q:session_name} #{q:pane_id}'"
#
# after-select-pane covers in-tmux pane switches. client-focus-in covers
# wezterm-side tab / workspace switches: when wezterm gives a tab focus
# it sends OSC focus-in (CSI I) to that pane's tmux client, which fires
# client-focus-in with #{pane_id} resolving to the client's currently-
# active pane — exactly the value the focus file should hold.
#
# Why not pane-focus-in: tmux 3.4 silently ignores `set-hook -g
# pane-focus-in` because the hook only exists in pane scope, so a global
# binding never lands on the server. We rely on after-select-pane plus
# client-focus-in to cover both axes (intra-tmux and wezterm-side).
#
# `session_name` (not `session_id`) is intentional: state entries written
# by emit-agent-status.sh record `tmux_session` from `#{session_name}`,
# and attention.lua's is_entry_focused resolves the focus file path from
# that same value. Using `#{session_id}` here would produce a filename
# like `..._default__1.txt` that Lua never looks up, breaking click-to-
# ack — the keyboard jump path still works because it bypasses the
# focus-file lookup entirely.
#
# State layout (one small file per tmux session, no flock needed since
# each hook writes its own path and Lua only reads):
#   <state>/agent-attention/tmux-focus/<safe_socket>__<safe_session>.txt
#     -> single line containing the active tmux pane id (e.g. "%12").
#
# Fails open: any step that fails is silently skipped so the tmux hook
# never observes an error.

set -u

socket="${1:-}"
session="${2:-}"
pane="${3:-}"

if [[ -z "$socket" || -z "$session" || -z "$pane" ]]; then
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/attention-state-lib.sh"
# shellcheck disable=SC1091
. "$script_dir/runtime-log-lib.sh"

# attention_state_path resolves to .../agent-attention/attention.json; peel
# off the filename to co-locate the per-session focus files under the
# same feature directory.
state_path="$(attention_state_path 2>/dev/null || true)"
if [[ -z "$state_path" ]]; then
  exit 0
fi
focus_dir="${state_path%/*}/tmux-focus"
mkdir -p "$focus_dir" 2>/dev/null || exit 0

# Filename-safe key. Socket paths contain slashes; session names are
# already safe characters in this repo (workspaces.lua enforces it), but
# we keep the legacy `$`-strip in case a caller ever passes a raw id.
# The Lua reader applies the same transform so both sides agree on the
# path without having to parse the full socket string.
safe_socket="${socket//\//_}"
safe_session="${session#\$}"
file="$focus_dir/${safe_socket}__${safe_session}.txt"
tmp="${file}.tmp.$$"

write_ok=0
if printf '%s\n' "$pane" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null; then
  write_ok=1
fi

if command -v runtime_log_info >/dev/null 2>&1; then
  runtime_log_info attention "tmux focus hook fired" \
    "socket=$socket" \
    "session=$session" \
    "pane=$pane" \
    "file=$file" \
    "write_ok=$write_ok"
fi

exit 0
