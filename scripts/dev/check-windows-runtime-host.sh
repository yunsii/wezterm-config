#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  scripts/dev/check-windows-runtime-host.sh [--target-dir PATH] [--skip-vscode] [--skip-chrome] [--skip-clipboard] [--timeout-seconds N]

Smoke-test the live Windows runtime host from WSL by:
  1. Ensuring the synced helper is healthy
  2. Enqueuing a VS Code focus/open request
  3. Enqueuing a Chrome focus/start request when chrome_debug_browser.user_data_dir is configured
  4. Verifying clipboard listener state is fresh
EOF
}

trim_cr() {
  printf '%s' "${1-}" | tr -d '\r'
}

json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS %s\n' "$*"
}

warn() {
  printf 'WARN %s\n' "$*" >&2
}

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
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

[[ "$target_dir" == /* ]] || die "--target-dir must be an absolute path"
[[ -d "$target_dir" ]] || die "target dir does not exist: $target_dir"
[[ "$timeout_seconds" =~ ^[0-9]+$ && "$timeout_seconds" -gt 0 ]] || die "--timeout-seconds must be a positive integer"

command -v powershell.exe >/dev/null 2>&1 || die "powershell.exe not found in PATH"
command -v cmd.exe >/dev/null 2>&1 || die "cmd.exe not found in PATH"
command -v wslpath >/dev/null 2>&1 || die "wslpath not found in PATH"

localappdata_win="$(trim_cr "$(cmd.exe /c echo %LOCALAPPDATA% 2>/dev/null || true)")"
userprofile_win="$(trim_cr "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null || true)")"
[[ -n "$localappdata_win" && -n "$userprofile_win" ]] || die "failed to resolve Windows LOCALAPPDATA/USERPROFILE"

localappdata_wsl="$(wslpath -u "$localappdata_win")"
userprofile_wsl="$(wslpath -u "$userprofile_win")"

runtime_home_win="${userprofile_win}\\.wezterm-x"
helper_ensure_win="${runtime_home_win}\\scripts\\ensure-windows-runtime-helper.ps1"
helper_worker_win="${runtime_home_win}\\scripts\\windows-runtime-helper.ps1"
helper_state_win="${localappdata_win}\\wezterm-runtime-helper\\state.env"
helper_request_dir_win="${localappdata_win}\\wezterm-runtime-helper\\requests"
helper_state_wsl="${localappdata_wsl}/wezterm-runtime-helper/state.env"
helper_request_dir_wsl="${localappdata_wsl}/wezterm-runtime-helper/requests"
debug_log_wsl="${userprofile_wsl}/.wezterm-x/wezterm-debug.log"

clipboard_state_win="${localappdata_win}\\wezterm-clipboard-cache\\state.env"
clipboard_log_win="${localappdata_win}\\wezterm-clipboard-cache\\listener.log"
clipboard_output_win="${localappdata_win}\\wezterm-clipboard-images"
clipboard_state_wsl="${localappdata_wsl}/wezterm-clipboard-cache/state.env"
clipboard_listener_win="${runtime_home_win}\\scripts\\clipboard-image-listener.ps1"

distro="${WSL_DISTRO_NAME:-}"
[[ -n "$distro" ]] || distro="Ubuntu-22.04"

state_value() {
  local key="$1"
  local file="$2"
  awk -F= -v wanted="$key" '$1==wanted {print $2; exit}' "$file" | tr -d '\r'
}

helper_state_fresh() {
  [[ -f "$helper_state_wsl" ]] || return 1
  local ready pid heartbeat now_ms
  ready="$(state_value ready "$helper_state_wsl")"
  pid="$(state_value pid "$helper_state_wsl")"
  heartbeat="$(state_value heartbeat_at_ms "$helper_state_wsl")"
  now_ms="$(date +%s%3N)"
  [[ "$ready" == "1" ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  [[ "$heartbeat" =~ ^[0-9]+$ && "$heartbeat" -gt 0 ]] || return 1
  (( now_ms - heartbeat <= 5000 )) || return 1
}

clipboard_state_fresh() {
  [[ -f "$clipboard_state_wsl" ]] || return 1
  local listener_pid heartbeat now_ms
  listener_pid="$(state_value listener_pid "$clipboard_state_wsl")"
  heartbeat="$(state_value heartbeat_at_ms "$clipboard_state_wsl")"
  now_ms="$(date +%s%3N)"
  [[ "$listener_pid" =~ ^[0-9]+$ && "$listener_pid" -gt 0 ]] || return 1
  [[ "$heartbeat" =~ ^[0-9]+$ && "$heartbeat" -gt 0 ]] || return 1
  (( now_ms - heartbeat <= 5000 )) || return 1
}

detect_vscode_exe() {
  local user_install_wsl="${localappdata_wsl}/Programs/Microsoft VS Code/Code.exe"
  if [[ -f "$user_install_wsl" ]]; then
    printf '%s\n' "${localappdata_win}\\Programs\\Microsoft VS Code\\Code.exe"
    return 0
  fi
  printf 'C:\\Program Files\\Microsoft VS Code\\Code.exe\n'
}

detect_chrome_profile_dir() {
  local constants_file="${repo_root}/wezterm-x/local/constants.lua"
  [[ -f "$constants_file" ]] || return 1
  perl -0ne "if (/chrome_debug_browser\\s*=\\s*\\{.*?user_data_dir\\s*=\\s*'([^']+)'/s) { print \$1 }" "$constants_file"
}

wait_for_request_consumed() {
  local path="$1"
  local limit=$((timeout_seconds * 20))
  local i
  for ((i=0; i<limit; i+=1)); do
    [[ -f "$path" ]] || return 0
    sleep 0.05
  done
  return 1
}

wait_for_log_match() {
  local pattern="$1"
  local limit=$((timeout_seconds * 10))
  local i
  for ((i=0; i<limit; i+=1)); do
    if rg -n "$pattern" "$debug_log_wsl" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

ensure_helper() {
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$helper_ensure_win" \
    -WorkerScriptPath "$helper_worker_win" \
    -StatePath "$helper_state_win" \
    -RequestDir "$helper_request_dir_win" \
    -ClipboardListenerScriptPath "$clipboard_listener_win" \
    -ClipboardStatePath "$clipboard_state_win" \
    -ClipboardLogPath "$clipboard_log_win" \
    -ClipboardOutputDir "$clipboard_output_win" \
    -ClipboardWslDistro "$distro" \
    -ClipboardHeartbeatIntervalSeconds 1 \
    -ClipboardHeartbeatTimeoutSeconds 3 \
    -ClipboardImageReadRetryCount 12 \
    -ClipboardImageReadRetryDelayMs 100 \
    -ClipboardCleanupMaxAgeHours 48 \
    -ClipboardCleanupMaxFiles 32 \
    -HeartbeatTimeoutSeconds 5 \
    -HeartbeatIntervalMs 1000 \
    -PollIntervalMs 25 \
    -DiagnosticsEnabled 1 \
    -DiagnosticsCategoryEnabled 1 \
    -DiagnosticsLevel info \
    -DiagnosticsFile "${runtime_home_win}\\wezterm-debug.log" \
    -DiagnosticsMaxBytes 5242880 \
    -DiagnosticsMaxFiles 5 >/dev/null
}

enqueue_vscode_request() {
  local trace_id="$1"
  local request_path="${helper_request_dir_wsl}/${trace_id}.json"
  local code_exe
  code_exe="$(detect_vscode_exe)"
  mkdir -p "$helper_request_dir_wsl"
  printf '{"kind":"vscode_focus_or_open","requested_dir":%s,"distro":%s,"trace_id":%s,"code_command":[%s]}' \
    "$(json_escape "$target_dir")" \
    "$(json_escape "$distro")" \
    "$(json_escape "$trace_id")" \
    "$(json_escape "$code_exe")" > "$request_path"
  wait_for_request_consumed "$request_path" || return 1
  wait_for_log_match "trace_id=\"${trace_id}\".*helper processed request" || return 1
  wait_for_log_match "trace_id=\"${trace_id}\".*(focused cached vscode window|launched vscode)" || return 1
}

enqueue_chrome_request() {
  local trace_id="$1"
  local chrome_profile
  chrome_profile="$(detect_chrome_profile_dir || true)"
  if [[ -z "$chrome_profile" ]]; then
    warn "chrome profile is not configured; skipping chrome request test"
    return 0
  fi

  local request_path="${helper_request_dir_wsl}/${trace_id}.json"
  mkdir -p "$helper_request_dir_wsl"
  printf '{"kind":"chrome_focus_or_start","trace_id":%s,"chrome_path":%s,"remote_debugging_port":9222,"user_data_dir":%s}' \
    "$(json_escape "$trace_id")" \
    "$(json_escape "chrome.exe")" \
    "$(json_escape "$chrome_profile")" > "$request_path"
  wait_for_request_consumed "$request_path" || return 1
  wait_for_log_match "trace_id=\"${trace_id}\".*helper processed request" || return 1
  wait_for_log_match "trace_id=\"${trace_id}\".*(focused cached debug chrome window|launched debug chrome)" || return 1
}

ensure_helper
helper_state_fresh || die "helper state is not fresh after ensure"
pass "helper state is fresh"

if (( skip_vscode == 0 )); then
  vscode_trace="host-check-alt-o-$(date +%Y%m%dT%H%M%S)-$$"
  enqueue_vscode_request "$vscode_trace" || die "VS Code request failed"
  pass "VS Code helper request processed"
fi

if (( skip_chrome == 0 )); then
  chrome_trace="host-check-alt-b-$(date +%Y%m%dT%H%M%S)-$$"
  enqueue_chrome_request "$chrome_trace" || die "Chrome request failed"
  pass "Chrome helper request processed"
fi

if (( skip_clipboard == 0 )); then
  clipboard_state_fresh || die "clipboard state is not fresh"
  pass "clipboard listener state is fresh"
fi

printf 'host smoke test completed\n'
