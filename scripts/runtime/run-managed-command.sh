#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"

if [[ $# -lt 1 ]]; then
  cat <<'EOF' >&2
usage:
  run-managed-command.sh <command> [args...]
EOF
  exit 1
fi

start_ms="$(runtime_log_now_ms)"

command_name="$1"
runtime_log_info managed_command "run-managed-command invoked" "command=$command_name" "arg_count=$#"
runtime_log_info managed_command "executing managed command" "command=$command_name"

if "$@"; then
  runtime_log_info managed_command "managed command completed" "command=$command_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

status=$?
runtime_log_error managed_command "managed command failed" "command=$command_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")" "exit_code=$status"
exit "$status"
