#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="$SCRIPT_DIR/../../tmux.conf"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

if git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$COMMON_DIR" ]]; then
    COMMON_DIR="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  fi
  if [[ -n "$COMMON_DIR" ]]; then
    if [[ "$COMMON_DIR" != /* ]]; then
      COMMON_DIR="$(
        cd "$REPO_ROOT"
        cd "$COMMON_DIR"
        pwd -P
      )"
    fi
    MAIN_ROOT="$(dirname "$COMMON_DIR")"
    if [[ -n "$MAIN_ROOT" && -d "$MAIN_ROOT" ]]; then
      REPO_ROOT="$MAIN_ROOT"
    fi
  fi
fi

tmux set-option -g @wezterm_runtime_root "$REPO_ROOT"
tmux source-file "$TMUX_CONF"
printf 'Reloaded tmux config: %s\n' "$TMUX_CONF"
