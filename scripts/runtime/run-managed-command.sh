#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  run-managed-command.sh [--bootstrap nvm] <command> [args...]
  run-managed-command.sh codex-github-theme [args...]
EOF
}

load_nvm_if_needed() {
  local command_name="${1:-}"

  if [[ -n "$command_name" ]] && command -v "$command_name" >/dev/null 2>&1; then
    runtime_log_debug managed_command "command already available on PATH" "command=$command_name"
    return
  fi

  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    runtime_log_info managed_command "loading nvm for command lookup" "command=${command_name:-unknown}" "nvm_dir=$NVM_DIR"
    # Load nvm so non-interactive tmux startup shells can resolve agent CLIs.
    # shellcheck disable=SC1090
    source "$NVM_DIR/nvm.sh"
  fi
}

apply_bootstrap() {
  local bootstrap="${1:-}"
  local command_name="${2:-}"

  case "$bootstrap" in
    ''|none)
      return 0
      ;;
    nvm)
      load_nvm_if_needed "$command_name"
      ;;
    *)
      runtime_log_error managed_command "unknown bootstrap" "bootstrap=$bootstrap"
      printf 'unknown bootstrap: %s\n' "$bootstrap" >&2
      exit 1
      ;;
  esac
}

translate_legacy_launcher() {
  local launcher="${1:-}"
  shift || true

  case "$launcher" in
    codex-github-theme)
      printf '%s\0' "nvm" "codex" "-c" 'tui.theme="github"'
      if [[ $# -gt 0 ]]; then
        printf '%s\0' "$@"
      fi
      ;;
    *)
      runtime_log_error managed_command "unknown launcher" "launcher=$launcher"
      printf 'unknown launcher: %s\n' "$launcher" >&2
      exit 1
      ;;
  esac
}

bootstrap=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootstrap)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      bootstrap="$2"
      shift 2
      ;;
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

if [[ -z "$bootstrap" && "$1" == "codex-github-theme" ]]; then
  runtime_log_info managed_command "translating legacy launcher" "launcher=$1" "arg_count=$#"
  command_parts=()
  while IFS= read -r -d '' part; do
    command_parts+=("$part")
  done < <(translate_legacy_launcher "$@")

  bootstrap="${command_parts[0]}"
  set -- "${command_parts[@]:1}"
fi

command_name="$1"
runtime_log_info managed_command "run-managed-command invoked" "bootstrap=${bootstrap:-none}" "command=$command_name" "arg_count=$#"

apply_bootstrap "$bootstrap" "$command_name"
exec "$@"
