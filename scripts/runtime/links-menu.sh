#!/usr/bin/env bash
# Launcher for the `picker links` Go subcommand. Same shape as
# tmux-command-menu.sh / tmux-attention-menu.sh:
#   1. Probe deps and the cwd.
#   2. Run `vscode-links resolve --format tsv` into a tempfile (with
#      diagnostic comment lines prepended for the empty-list path).
#   3. Spawn `tmux display-popup -E "picker links <tsv> <dispatch>.sh
#      <cwd> <keypress_ts> <menu_start_ts> <menu_done_ts>"`.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_root="$(cd "$script_dir/.." && pwd)"

# Args are filled by the chord exec, in order: pane_current_path,
# optional keypress timestamp (epoch ms) injected by the chord
# wrapper. Defaults preserve manual invocation from a regular shell.
cwd="${1:-$PWD}"
keypress_ts="${2:-0}"

resolve_vscode_links_bin() {
  if [[ -n "${VSCODE_LINKS_BIN:-}" ]]; then
    printf '%s\n' "$VSCODE_LINKS_BIN"
    return 0
  fi
  # Prefer the version pinned by native/vscode-links/release-manifest.json
  # (managed by sync-runtime). Falls back to PATH for users who installed
  # via the upstream install.sh themselves.
  local managed="$runtime_root/../native/vscode-links/bin/vscode-links"
  if [[ -x "$managed" ]]; then
    printf '%s\n' "$managed"
    return 0
  fi
  command -v vscode-links 2>/dev/null && return 0
  return 1
}

bin="$(resolve_vscode_links_bin || true)"
if [[ -z "$bin" ]] || ! [[ -x "$bin" ]]; then
  printf 'links: vscode-links not found\n' >&2
  printf 'install with: bash %s/scripts/runtime/setup-vscode-links.sh --install\n' "$runtime_root/.." >&2
  printf 'or run sync-runtime; or set VSCODE_LINKS_BIN=/path/to/vscode-links\n' >&2
  printf 'press any key to close...' >&2
  IFS= read -rsn1 _ || true
  exit 1
fi

picker_bin="$runtime_root/../native/picker/bin/picker"
# tmux-command-menu.sh resolves picker via this same convention, so
# stay aligned: prefer the in-tree dev build, fall back to a release
# install path (left for the runtime-sync to populate later).
if [[ ! -x "$picker_bin" ]]; then
  picker_bin="$(command -v picker || true)"
fi
if [[ -z "$picker_bin" ]] || [[ ! -x "$picker_bin" ]]; then
  printf 'links: picker binary not found (built native/picker yet?)\n' >&2
  printf 'press any key to close...' >&2
  IFS= read -rsn1 _ || true
  exit 1
fi

menu_start_ts="$(date +%s%3N)"

prefetch="$(mktemp -t vscl-prefetch.XXXXXX)"
trap 'rm -f "$prefetch"' EXIT

# Resolve link list. TSV gives us exactly the four columns the picker
# expects. Diagnostics are read separately from the ndjson stream so
# the empty-list path can show *why* nothing matched.
ndjson="$("$bin" resolve --cwd "$cwd" --format ndjson 2>&1)" || {
  {
    printf '# vscode-links resolve failed:\n'
    printf '%s\n' "$ndjson" | sed 's/^/# /'
  } > "$prefetch"
  ndjson=""
}

if [[ -n "$ndjson" ]]; then
  diags="$(printf '%s\n' "$ndjson" | jq -r 'select(.kind == "diagnostic") | .data | "[\(.level)] \(.source): \(.message)"' 2>/dev/null || true)"
  links="$(printf '%s\n' "$ndjson" | jq -r 'select(.kind == "link") | .data | [.type, .source, .url, .title] | @tsv' 2>/dev/null || true)"
  {
    if [[ -n "$diags" ]]; then
      printf '%s\n' "$diags" | sed 's/^/# /'
    fi
    if [[ -n "$links" ]]; then
      printf '%s\n' "$links"
    fi
  } > "$prefetch"
fi

menu_done_ts="$(date +%s%3N)"

dispatch="$script_dir/links-dispatch.sh"

# Spawn the popup ourselves rather than relying on the chord exec to
# do it: `display-popup`'s shell-command argument does NOT expand
# tmux format strings (`#{@wezterm_runtime_root}` etc.), so the
# chord can only safely invoke `run-shell` (which DOES expand) and
# let this launcher run the popup with already-resolved paths.
exec tmux display-popup -E -h "60%" -w "80%" \
  "'$picker_bin' links '$prefetch' '$dispatch' '$cwd' '$keypress_ts' '$menu_start_ts' '$menu_done_ts'"
