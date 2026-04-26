#!/usr/bin/env bash
# Open the vscode-links picker for the current pane's working
# directory. Backed by the standalone `vscode-links` CLI binary
# (https://github.com/yunsii/vscode-links — install via the cli-v*
# release's install.sh, or set VSCODE_LINKS_BIN to a local build path).
#
# Wired in via wezterm-x/commands/manifest.json as `links.picker`,
# bound to Ctrl+k l. Spawned inside `tmux display-popup -E`.
#
# Phase 1: bash + fzf TUI (fzf required, jq required). Phase 2 will
# fold this into the Go picker for sub-100ms cold start.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/windows-shell-lib.sh"

cwd="${1:-$PWD}"
bin="${VSCODE_LINKS_BIN:-vscode-links}"

if ! command -v "$bin" >/dev/null 2>&1; then
  printf 'links: %s not on PATH\n' "$bin" >&2
  printf 'install via: curl -fsSL https://github.com/yunsii/vscode-links/releases/latest/download/install.sh | sh\n' >&2
  printf 'press any key to close...\n' >&2
  IFS= read -rsn1 _ || true
  exit 1
fi
if ! command -v fzf >/dev/null 2>&1; then
  printf 'links: fzf not on PATH (required for the picker UI)\n' >&2
  printf 'install via: sudo apt install fzf  (or your distro equivalent)\n' >&2
  printf 'press any key to close...\n' >&2
  IFS= read -rsn1 _ || true
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'links: jq not on PATH\n' >&2
  IFS= read -rsn1 _ || true
  exit 1
fi

# Resolve links. NDJSON gives us one record per line tagged by kind
# so a future streaming consumer can render incrementally; here we
# just slurp the whole thing into memory.
ndjson=$("$bin" resolve --cwd "$cwd" --format ndjson 2>&1) || {
  printf 'links: vscode-links resolve failed:\n%s\n' "$ndjson" >&2
  printf 'press any key to close...\n' >&2
  IFS= read -rsn1 _ || true
  exit 1
}

# Lines: <type>\t<source>\t<url>\t<title>
rows=$(printf '%s\n' "$ndjson" | jq -r 'select(.kind == "link") | .data | "\(.type)\t\(.source)\t\(.url)\t\(.title)"')

if [[ -z "$rows" ]]; then
  printf 'links: no resolved links for %s\n' "$cwd" >&2
  # Surface diagnostics so the user can see why (bad config etc.)
  diags=$(printf '%s\n' "$ndjson" | jq -r 'select(.kind == "diagnostic") | .data | "[\(.level)] \(.source): \(.message)"')
  if [[ -n "$diags" ]]; then
    printf 'diagnostics:\n%s\n' "$diags" >&2
  fi
  printf 'press any key to close...\n' >&2
  IFS= read -rsn1 _ || true
  exit 0
fi

# fzf shows: title (col 4), then dim type/source (cols 1-2), then URL.
# Enter accepts; Ctrl+Y copies URL via host helper instead of opening.
selected=$(printf '%s\n' "$rows" | fzf \
  --prompt="links> " \
  --delimiter=$'\t' \
  --with-nth=4,1,3 \
  --preview='echo "type:    {1}"; echo "source:  {2}"; echo "title:   {4}"; echo; echo "{3}"' \
  --preview-window=down:6 \
  --header="enter open · ctrl-y copy" \
  --bind='ctrl-y:execute-silent(printf "COPY\t%s\n" {3} > /tmp/.vscl-pick.$$)+abort' \
  --expect=ctrl-y) || true

if [[ -z "$selected" ]]; then
  exit 0
fi

# fzf with --expect prepends the matching key (or empty line) to its
# stdout. Two lines: first is the key, second is the row.
key=$(printf '%s\n' "$selected" | sed -n '1p')
row=$(printf '%s\n' "$selected" | sed -n '2p')
[[ -z "$row" ]] && exit 0

url=$(printf '%s\n' "$row" | cut -f3)
[[ -z "$url" ]] && exit 0

if [[ "$key" == "ctrl-y" ]]; then
  windows_run_powershell_command_utf8 "Set-Clipboard -Value '${url//\'/\'\'}'"
  printf 'copied: %s\n' "$url" >&2
else
  windows_run_powershell_command_utf8 "Start-Process '${url//\'/\'\'}'"
fi
