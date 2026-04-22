#!/usr/bin/env bash
# Record the active tmux pane for a (socket, session) so attention.lua
# can require tmux-pane-level focus, not just WezTerm pane focus, before
# auto-acking a `done` entry whose wezterm_pane_id matches.
#
# Invoked from tmux hooks in tmux.conf:
#   set-hook -g pane-focus-in     'run-shell -b "bash .../tmux-focus-emit.sh \
#     #{q:socket_path} #{q:session_id} #{q:pane_id}"'
#   set-hook -g after-select-pane 'run-shell -b "bash .../tmux-focus-emit.sh \
#     #{q:socket_path} #{q:session_id} #{q:pane_id}"'
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

# attention_state_path resolves to .../agent-attention/attention.json; peel
# off the filename to co-locate the per-session focus files under the
# same feature directory.
state_path="$(attention_state_path 2>/dev/null || true)"
if [[ -z "$state_path" ]]; then
  exit 0
fi
focus_dir="${state_path%/*}/tmux-focus"
mkdir -p "$focus_dir" 2>/dev/null || exit 0

# Filename-safe key. Socket paths contain slashes; session ids look like
# "$0". The Lua reader applies the same transform so both sides agree on
# the path without having to parse the full socket string.
safe_socket="${socket//\//_}"
safe_session="${session#\$}"
file="$focus_dir/${safe_socket}__${safe_session}.txt"
tmp="${file}.tmp.$$"

printf '%s\n' "$pane" > "$tmp" 2>/dev/null && mv "$tmp" "$file" 2>/dev/null
exit 0
