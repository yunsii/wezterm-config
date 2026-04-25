#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/helpers.sh"

verb="${1:-}"

case "$verb" in
  validate|detect-context|launch|attach|cleanup)
    if [[ -n "${WT_RESULT_FILE:-}" ]]; then
      wt_write_kv_file "$WT_RESULT_FILE"
    fi
    exit 0
    ;;
  *)
    printf 'unsupported provider verb: %s\n' "$verb" >&2
    exit 20
    ;;
esac
