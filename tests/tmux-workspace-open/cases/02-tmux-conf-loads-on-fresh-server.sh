#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../tmux-reset/lib.sh"

tmux_test_setup
trap tmux_test_teardown EXIT

tmux new-session -d -s smoke -c "$REPO_ROOT" /bin/sh -lc 'exec sleep 300' >/dev/null
tmux set-option -g @wezterm_runtime_root "$REPO_ROOT"
tmux source-file "$REPO_ROOT/tmux.conf"

printf 'PASS tmux-conf-loads-on-fresh-server\n'
