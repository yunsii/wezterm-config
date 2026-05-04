#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

expose_fnm_default_if_needed() {
  if command -v node >/dev/null 2>&1; then
    return
  fi

  local fnm_default_bin="$HOME/.local/share/fnm/aliases/default/bin"
  if [[ -d "$fnm_default_bin" ]]; then
    PATH="$fnm_default_bin:$PATH"
  fi
}

expose_fnm_default_if_needed

if ! command -v node >/dev/null 2>&1; then
  style 'fg=#7f7a72' 'Node unavailable'
  exit 0
fi

node_version="$(node -v 2>/dev/null || true)"

if [[ -n "$node_version" ]]; then
  style 'fg=#3f7a4a' "⬢ ${node_version}"
else
  style 'fg=#7f7a72' 'Node unavailable'
fi
