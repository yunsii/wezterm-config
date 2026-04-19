#!/usr/bin/env bash
set -euo pipefail

CHECK_WINDOWS_RUNTIME_HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "$CHECK_WINDOWS_RUNTIME_HOST_DIR/windows-runtime-host/lib.sh"
# shellcheck disable=SC1091
source "$CHECK_WINDOWS_RUNTIME_HOST_DIR/windows-runtime-host/cases/vscode.sh"
# shellcheck disable=SC1091
source "$CHECK_WINDOWS_RUNTIME_HOST_DIR/windows-runtime-host/cases/chrome.sh"
# shellcheck disable=SC1091
source "$CHECK_WINDOWS_RUNTIME_HOST_DIR/windows-runtime-host/cases/clipboard.sh"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
target_dir="$PWD"
timeout_seconds=10
skip_vscode=0
skip_chrome=0
skip_clipboard=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      target_dir="${2:-}"
      shift 2
      ;;
    --skip-vscode)
      skip_vscode=1
      shift
      ;;
    --skip-chrome)
      skip_chrome=1
      shift
      ;;
    --skip-clipboard)
      skip_clipboard=1
      shift
      ;;
    --timeout-seconds)
      timeout_seconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      host_check_usage
      exit 0
      ;;
    *)
      host_check_usage >&2
      exit 1
      ;;
  esac
done

[[ "$target_dir" == /* ]] || host_check_die "--target-dir must be an absolute path"
[[ -d "$target_dir" ]] || host_check_die "target dir does not exist: $target_dir"
[[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || host_check_die "--timeout-seconds must be a positive integer"

HOST_CHECK_TARGET_DIR="$target_dir"
HOST_CHECK_TIMEOUT_SECONDS="$timeout_seconds"

host_check_init_environment "$repo_root"
host_check_ensure_helper
host_check_helper_state_fresh || host_check_die "helper state is not fresh after ensure"
host_check_pass "helper state is fresh"

if (( skip_vscode == 0 )); then
  vscode_trace="host-check-alt-o-$(date +%Y%m%dT%H%M%S)-$$"
  host_check_run_vscode_case "$vscode_trace" || host_check_die "VS Code request failed"
  host_check_pass "VS Code helper request processed"
fi

if (( skip_chrome == 0 )); then
  chrome_trace="host-check-alt-b-$(date +%Y%m%dT%H%M%S)-$$"
  host_check_run_chrome_case "$chrome_trace" || host_check_die "Chrome request failed"
  host_check_pass "Chrome helper request processed"
fi

if (( skip_clipboard == 0 )); then
  clipboard_trace="host-check-clipboard-$(date +%Y%m%dT%H%M%S)-$$"
  host_check_run_clipboard_case "$clipboard_trace" || host_check_die "clipboard request failed"
  host_check_pass "clipboard helper request processed"
fi

printf 'host smoke test completed\n'
