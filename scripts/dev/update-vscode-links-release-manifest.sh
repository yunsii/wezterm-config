#!/usr/bin/env bash
# Pin native/vscode-links/release-manifest.json to a published cli-v*
# tag from yunsii/vscode-links. Fetches each per-arch *.sha256 from
# the GitHub Release and writes the manifest in the schema the
# setup-vscode-links.sh runtime script expects.
#
# Usage:
#   scripts/dev/update-vscode-links-release-manifest.sh --tag cli-v0.1.2
#
# Mirrors update-picker-release-manifest.sh in shape; only the asset
# enumeration differs (picker keys by os-arch like linux-amd64;
# vscode-links keys by Rust target triple).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_MANIFEST_PATH="$REPO_ROOT/native/vscode-links/release-manifest.json"
DEFAULT_REPO="yunsii/vscode-links"

TRIPLES=(linux-x64-gnu linux-arm64-gnu darwin-x64 darwin-arm64 win32-x64-msvc)

usage() {
  cat <<'EOF'
Usage:
  scripts/dev/update-vscode-links-release-manifest.sh --tag TAG [options]

Options:
  --tag TAG          Release tag, e.g. cli-v0.1.2
  --repo OWNER/REPO  Source repo (default: yunsii/vscode-links)
  --output PATH      Output manifest path (default:
                     native/vscode-links/release-manifest.json)
  -h, --help         Show this help

Notes:
  - Reads <release>/vscode-links-<triple>.{tar.gz,zip}.sha256 from the
    cli-v* GitHub Release and assembles the asset map.
  - Strips the leading `cli-v` from the tag to fill the .version field;
    the tag itself is preserved under .tag for traceability.
  - Requires `jq`, `curl`.
EOF
}

tag=""
repo="$DEFAULT_REPO"
output="$DEFAULT_MANIFEST_PATH"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)    tag="${2:-}"; shift 2 ;;
    --repo)   repo="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$tag" ]] || { printf '%s\n' "--tag is required" >&2; usage >&2; exit 2; }
[[ "$tag" == cli-v* ]] || { printf 'expected --tag to start with cli-v, got %q\n' "$tag" >&2; exit 2; }

command -v jq   >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { printf 'curl is required\n' >&2; exit 2; }

version="${tag#cli-v}"
base_url="https://github.com/${repo}/releases/download/${tag}"

asset_for_triple() {
  local triple="$1"
  if [[ "$triple" == win32-* ]]; then
    printf 'vscode-links-%s.zip\n' "$triple"
  else
    printf 'vscode-links-%s.tar.gz\n' "$triple"
  fi
}

assets_json='{}'
for triple in "${TRIPLES[@]}"; do
  asset="$(asset_for_triple "$triple")"
  url="$base_url/$asset"
  sha_url="$url.sha256"
  printf '> fetching %s\n' "$sha_url" >&2
  sha="$(curl -fsSL "$sha_url" | awk '{print $1}')"
  [[ -n "$sha" ]] || { printf 'empty sha for %s\n' "$triple" >&2; exit 1; }
  assets_json="$(jq \
    --arg t "$triple" --arg n "$asset" --arg u "$url" --arg s "$sha" \
    '. + { ($t): { assetName: $n, downloadUrl: $u, sha256: $s } }' \
    <<<"$assets_json")"
done

mkdir -p "$(dirname "$output")"
jq --arg version "$version" --arg tag "$tag" --arg repo "$repo" --argjson assets "$assets_json" \
  '{ schemaVersion: 1, enabled: true, version: $version, tag: $tag, repo: $repo, assets: $assets }' \
  > "$output" <<<"{}"

printf '> wrote %s (version %s)\n' "$output" "$version" >&2
