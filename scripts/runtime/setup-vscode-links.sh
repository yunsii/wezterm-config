#!/usr/bin/env bash
# Reconcile native/vscode-links/bin/vscode-links with what
# native/vscode-links/release-manifest.json pins.
#
# Modes (mutually exclusive):
#   default     auto-install if the binary is missing; ADVISORY (no
#               auto-replace) when the binary is present at a
#               different version. Sync-runtime invokes us in this
#               default mode so first-time clones become picker-ready
#               without user action, while updates remain explicit.
#   --install   force download + install regardless of current state.
#   --check     read-only: exit 0 in sync, exit 7 if missing/behind.
#               Also passes --advisory semantics to its own logging.
#
# Set WEZTERM_VSCODE_LINKS_INSTALL_SOURCE=local to suppress all
# automatic action — useful when the user is hand-building from a
# vscode-links checkout and pointing VSCODE_LINKS_BIN at it.

set -euo pipefail

mode="default"
case "${1:-}" in
  ""|--default) mode="default" ;;
  --install)    mode="install" ;;
  --check)      mode="check" ;;
  -h|--help)
    sed -n '1,30p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    printf 'setup-vscode-links: unknown mode %q\n' "$1" >&2
    exit 2
    ;;
esac

if [[ "${WEZTERM_VSCODE_LINKS_INSTALL_SOURCE:-auto}" == "local" ]]; then
  exit 0
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
manifest="$repo_root/native/vscode-links/release-manifest.json"
bin_dir="$repo_root/native/vscode-links/bin"
bin="$bin_dir/vscode-links"

if [[ ! -f "$manifest" ]]; then
  printf 'setup-vscode-links: manifest missing at %s\n' "$manifest" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'setup-vscode-links: jq is required\n' >&2
  exit 2
fi

pinned_version="$(jq -r '.version // ""' "$manifest")"
[[ -n "$pinned_version" ]] || { printf 'setup-vscode-links: manifest missing .version\n' >&2; exit 2; }

local_version=""
if [[ -x "$bin" ]]; then
  local_version="$("$bin" --version 2>/dev/null | awk '{print $2}' || true)"
fi

# Detect host triple matching the keys in release-manifest.json.
detect_triple() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Linux)
      case "$arch" in
        x86_64|amd64)  echo linux-x64-gnu ;;
        aarch64|arm64) echo linux-arm64-gnu ;;
        *) return 1 ;;
      esac
      ;;
    Darwin)
      case "$arch" in
        x86_64) echo darwin-x64 ;;
        arm64)  echo darwin-arm64 ;;
        *) return 1 ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo win32-x64-msvc
      ;;
    *) return 1 ;;
  esac
}
triple="$(detect_triple)" || {
  printf 'setup-vscode-links: unsupported host (%s/%s)\n' "$(uname -s)" "$(uname -m)" >&2
  exit 1
}

asset="$(jq -r --arg t "$triple" '.assets[$t] // ""' "$manifest")"
if [[ -z "$asset" ]] || [[ "$asset" == "null" ]]; then
  printf 'setup-vscode-links: manifest has no asset for %s\n' "$triple" >&2
  exit 2
fi
asset_url="$(jq -r --arg t "$triple" '.assets[$t].downloadUrl' "$manifest")"
asset_sha="$(jq -r --arg t "$triple" '.assets[$t].sha256' "$manifest")"
asset_name="$(jq -r --arg t "$triple" '.assets[$t].assetName' "$manifest")"

up_to_date=0
[[ "$local_version" == "$pinned_version" ]] && up_to_date=1

if (( up_to_date )); then
  exit 0
fi

advisory_line() {
  if [[ -z "$local_version" ]]; then
    printf 'vscode-links not installed; pinned version %s — install with: bash scripts/runtime/setup-vscode-links.sh --install\n' "$pinned_version"
  else
    printf 'vscode-links %s installed; pinned version %s — update with: bash scripts/runtime/setup-vscode-links.sh --install\n' "$local_version" "$pinned_version"
  fi
}

case "$mode" in
  check)
    advisory_line >&2
    exit 7
    ;;
  default)
    # First-time install runs auto; updates only advise.
    if [[ -z "$local_version" ]]; then
      :  # fall through to install
    else
      advisory_line >&2
      exit 0
    fi
    ;;
  install)
    : # always install
    ;;
esac

# ── Install path ──────────────────────────────────────────────────────────

mkdir -p "$bin_dir"
tmp="$(mktemp -d -t vscl-install.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

archive="$tmp/$asset_name"
printf 'setup-vscode-links: fetching %s\n' "$asset_url" >&2
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$asset_url" -o "$archive"
elif command -v wget >/dev/null 2>&1; then
  wget -q "$asset_url" -O "$archive"
else
  printf 'setup-vscode-links: neither curl nor wget available\n' >&2
  exit 1
fi

# Verify SHA256.
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$archive" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
else
  printf 'setup-vscode-links: no sha256 tool found\n' >&2
  exit 1
fi
if [[ "$actual" != "$asset_sha" ]]; then
  printf 'setup-vscode-links: sha256 mismatch (expected %s, got %s)\n' "$asset_sha" "$actual" >&2
  exit 1
fi

# Extract.
case "$asset_name" in
  *.tar.gz)
    tar -xzf "$archive" -C "$tmp"
    ;;
  *.zip)
    if command -v unzip >/dev/null 2>&1; then
      unzip -q -o "$archive" -d "$tmp"
    else
      printf 'setup-vscode-links: unzip required for windows asset\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'setup-vscode-links: unknown archive type %s\n' "$asset_name" >&2
    exit 1
    ;;
esac

# Locate the binary inside the extracted tree.
bin_inside="vscode-links"
[[ "$triple" == win32-* ]] && bin_inside="vscode-links.exe"
extracted="$(find "$tmp" -type f -name "$bin_inside" -print -quit)"
[[ -n "$extracted" ]] || { printf 'setup-vscode-links: %s not found in archive\n' "$bin_inside" >&2; exit 1; }

dst="$bin_dir/$bin_inside"
cp "$extracted" "$dst.tmp"
chmod +x "$dst.tmp"
mv "$dst.tmp" "$dst"

new_version="$("$dst" --version 2>/dev/null | awk '{print $2}' || true)"
printf 'setup-vscode-links: installed vscode-links %s at %s\n' "$new_version" "$dst" >&2
