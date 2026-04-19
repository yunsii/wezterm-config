#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  run-managed-command.sh <command> [args...]
EOF
}

resolve_login_shell() {
  if [[ -n "${WEZTERM_MANAGED_SHELL:-}" && -x "${WEZTERM_MANAGED_SHELL:-}" ]]; then
    printf '%s\n' "$WEZTERM_MANAGED_SHELL"
    return 0
  fi

  if [[ -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
    printf '%s\n' "$SHELL"
    return 0
  fi

  local candidate
  for candidate in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '/bin/sh\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

start_ms="$(runtime_log_now_ms)"

command_name="$1"
login_shell="$(resolve_login_shell)"
printf -v command_string '%q ' "$@"
command_string="${command_string% }"
runtime_log_info managed_command "run-managed-command invoked" "command=$command_name" "arg_count=$#" "login_shell=$login_shell"
runtime_log_info managed_command "executing managed command" "command=$command_name" "login_shell=$login_shell"

if "$login_shell" -ilc "$command_string"; then
  runtime_log_info managed_command "managed command completed" "command=$command_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
else
  status=$?
  runtime_log_error managed_command "managed command failed" "command=$command_name" "duration_ms=$(runtime_log_duration_ms "$start_ms")" "exit_code=$status"
  exit "$status"
fi
