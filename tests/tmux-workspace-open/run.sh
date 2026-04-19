#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASES_DIR="$SCRIPT_DIR/cases"

case_count=0

for case_script in "$CASES_DIR"/*.sh; do
  [[ -f "$case_script" ]] || continue
  ((case_count += 1))
  printf '==> %s\n' "$(basename "$case_script")"
  bash "$case_script"
done

if (( case_count == 0 )); then
  printf 'no tmux-workspace-open test cases found in %s\n' "$CASES_DIR" >&2
  exit 1
fi

printf 'PASS tmux-workspace-open test suite (%d cases)\n' "$case_count"
