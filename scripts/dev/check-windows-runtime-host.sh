#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_SHELL_LIB="$SCRIPT_DIR/../runtime/windows-shell-lib.sh"

# shellcheck disable=SC1091
source "$WINDOWS_SHELL_LIB"

usage() {
  cat <<'EOF'
usage:
  scripts/dev/check-windows-runtime-host.sh [--target-dir PATH] [--skip-vscode] [--skip-chrome] [--skip-clipboard] [--timeout-seconds N]

Smoke-test the live Windows runtime host from WSL by:
  1. Ensuring the synced helper is healthy
  2. Sending a VS Code focus/open IPC request
  3. Sending a Chrome focus/start IPC request when chrome_debug_browser.user_data_dir is configured
  4. Verifying clipboard read/write IPC requests for text and image
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

trace() {
  printf '[host-check] %s\n' "$*"
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

runtime_state_win="${localappdata_win}\\wezterm-runtime"
runtime_state_wsl="${localappdata_wsl}/wezterm-runtime"
runtime_home_win="${userprofile_win}\\.wezterm-x"
runtime_home_wsl="${userprofile_wsl}/.wezterm-x"
helper_log_wsl="${runtime_state_wsl}/logs/helper.log"

helper_ensure_wsl="${runtime_home_wsl}/scripts/ensure-windows-runtime-helper.ps1"
helper_state_win="${runtime_state_win}\\state\\helper\\state.env"
helper_state_wsl="${runtime_state_wsl}/state/helper/state.env"
helper_window_cache_wsl="${runtime_state_wsl}/cache/helper/window-cache.json"
helper_client_wsl="${runtime_state_wsl}/bin/helperctl.exe"
helper_ipc_endpoint='\\.\pipe\wezterm-host-helper-v1'

clipboard_output_win="${runtime_state_win}\\state\\clipboard\\exports"

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
  perl -0ne '
    if (/chrome_debug_browser\s*=\s*\{.*?user_data_dir\s*=\s*'\''([^'\'']+)'\''/s) {
      my $value = $1;
      $value =~ s/\\\\/\\/g;
      $value =~ s/\\'\''/'\''/g;
      print $value;
    }
  ' "$constants_file"
}

chrome_registry_has_entry() {
  [[ -f "$helper_window_cache_wsl" ]] || return 1
  perl -0ne '
    if (
      /"Chrome"\s*:\s*\{\s*"[^"]+"/s ||
      /"Entries"\s*:\s*\{.*?"chrome"\s*:\s*\{\s*"[^"]+"/s
    ) {
      exit 0;
    }
    exit 1;
  ' "$helper_window_cache_wsl"
}

chrome_process_exists() {
  local chrome_profile="$1"
  local escaped_profile="${chrome_profile//\\/\\\\}"
  powershell.exe -NoProfile -NonInteractive -Command "
    \$profile = '$escaped_profile';
    \$matches = @(Get-CimInstance Win32_Process -Filter \"Name = 'chrome.exe'\" | Where-Object {
      \$_.CommandLine -and
      \$_.CommandLine.IndexOf('--remote-debugging-port=9222', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
      \$_.CommandLine.IndexOf(\$profile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    });
    if (\$matches.Count -gt 0) { exit 0 } else { exit 1 }
  " >/dev/null 2>&1
}

wait_for_log_match() {
  local pattern="$1"
  local limit=$((timeout_seconds * 10))
  local i
  for ((i=0; i<limit; i+=1)); do
    if rg -n "$pattern" "$helper_log_wsl" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_trace_event() {
  local trace_id="$1"
  local event_pattern="$2"
  wait_for_log_match "trace_id=\"${trace_id}\".*${event_pattern}" \
    || wait_for_log_match "${event_pattern}.*trace_id=\"${trace_id}\""
}

ensure_helper() {
  local helper_ensure_win=""
  helper_ensure_win="$(wslpath -w "$helper_ensure_wsl")"
  trace "step=ensure-helper helper_ensure_win=$helper_ensure_win state_path=$helper_state_win"
  windows_run_powershell_script_utf8 "$helper_ensure_win" \
    -StatePath "$helper_state_win" \
    -ClipboardOutputDir "$clipboard_output_win" \
    -ClipboardWslDistro "$distro" \
    -ClipboardImageReadRetryCount 12 \
    -ClipboardImageReadRetryDelayMs 100 \
    -ClipboardCleanupMaxAgeHours 48 \
    -ClipboardCleanupMaxFiles 32 \
    -HeartbeatTimeoutSeconds 5 \
    -HeartbeatIntervalMs 1000 \
    -DiagnosticsEnabled 1 \
    -DiagnosticsCategoryEnabled 1 \
    -DiagnosticsLevel info \
    -DiagnosticsFile "${runtime_state_win}\\logs\\helper.log" \
    -DiagnosticsMaxBytes 5242880 \
    -DiagnosticsMaxFiles 5 >/dev/null
}

invoke_helper_request() {
  local trace_id="$1"
  local request_body="$2"
  local request_b64=""
  request_b64="$(printf '%s' "$request_body" | base64 | tr -d '\r\n')"
  "$helper_client_wsl" request --pipe "$helper_ipc_endpoint" --payload-base64 "$request_b64" --timeout-ms $((timeout_seconds * 1000)) >/dev/null 2>&1
}

invoke_helper_request_capture() {
  local trace_id="$1"
  local request_body="$2"
  local request_b64=""
  request_b64="$(printf '%s' "$request_body" | base64 | tr -d '\r\n')"
  "$helper_client_wsl" request --pipe "$helper_ipc_endpoint" --payload-base64 "$request_b64" --timeout-ms $((timeout_seconds * 1000))
}

env_value_from_text() {
  local key="$1"
  local text="$2"
  awk -F= -v wanted="$key" '$1==wanted {print $2; exit}' <<<"$text" | tr -d '\r'
}

enqueue_vscode_request() {
  local trace_id="$1"
  local code_exe
  code_exe="$(detect_vscode_exe)"
  invoke_helper_request "$trace_id" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"vscode","action":"focus_or_open","payload":{"requested_dir":%s,"distro":%s,"code_command":[%s]}}' \
    "$(json_escape "$trace_id")" \
    "$(json_escape "$target_dir")" \
    "$(json_escape "$distro")" \
    "$(json_escape "$code_exe")")" || return 1
  wait_for_trace_event "$trace_id" "helper completed request.*status=\"(reused|launched)\"" || return 1
}

enqueue_chrome_request() {
  local trace_id="$1"
  local chrome_profile
  chrome_profile="$(detect_chrome_profile_dir || true)"
  if [[ -z "$chrome_profile" ]]; then
    warn "chrome profile is not configured; skipping chrome request test"
    return 0
  fi

  local expect_reuse=0
  if chrome_registry_has_entry || chrome_process_exists "$chrome_profile"; then
    expect_reuse=1
  fi
  invoke_helper_request "$trace_id" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"chrome","action":"focus_or_start","payload":{"chrome_path":%s,"remote_debugging_port":9222,"user_data_dir":%s}}' \
    "$(json_escape "$trace_id")" \
    "$(json_escape "chrome.exe")" \
    "$(json_escape "$chrome_profile")")" || return 1
  if (( expect_reuse == 1 )); then
    wait_for_trace_event "$trace_id" "helper completed request.*status=\"reused\"" || return 1
    wait_for_trace_event "$trace_id" "(focused cached debug chrome window|rebound existing debug chrome window)" || return 1
    return 0
  fi

  wait_for_trace_event "$trace_id" "helper completed request.*status=\"(reused|launched|launch_handoff_existing)\"" || return 1
  wait_for_trace_event "$trace_id" "(focused cached debug chrome window|rebound existing debug chrome window|bound launched debug chrome window|launched debug chrome)" || return 1
  if wait_for_trace_event "$trace_id" "launched debug chrome but did not bind a reusable window"; then
    return 1
  fi
  return 0
}

enqueue_clipboard_request() {
  local trace_id="$1"
  local test_png="${repo_root}/assets/copy-test.png"
  local text_payload=""
  local write_text_response=""
  local resolve_text_response=""
  local write_image_response=""
  local resolve_image_response=""

  [[ -f "$test_png" ]] || return 1
  text_payload="clipboard-smoke $(date '+%Y-%m-%d %H:%M:%S %z')"

  write_text_response="$(invoke_helper_request_capture "${trace_id}-write-text" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"write_text","payload":{"text":%s}}' \
    "$(json_escape "${trace_id}-write-text")" \
    "$(json_escape "$text_payload")")")" || return 1
  [[ "$(env_value_from_text status "$write_text_response")" == "clipboard_written_text" ]] || return 1

  resolve_text_response="$(invoke_helper_request_capture "${trace_id}-resolve-text" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"resolve_for_paste","payload":{}}' \
    "$(json_escape "${trace_id}-resolve-text")")")" || return 1
  [[ "$(env_value_from_text result_type "$resolve_text_response")" == "clipboard_text" ]] || return 1
  [[ "$(env_value_from_text result_text "$resolve_text_response")" == "$text_payload" ]] || return 1

  # Leave a small gap between the text and image writes so clipboard history
  # tools like Ditto do not coalesce/ignore the second update as "too fast".
  sleep 1

  write_image_response="$(invoke_helper_request_capture "${trace_id}-write-image" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"write_image_file","payload":{"image_path":%s}}' \
    "$(json_escape "${trace_id}-write-image")" \
    "$(json_escape "$(wslpath -w "$test_png")")")")" || return 1
  [[ "$(env_value_from_text status "$write_image_response")" == "clipboard_written_image" ]] || return 1

  resolve_image_response="$(invoke_helper_request_capture "${trace_id}-resolve-image" "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"resolve_for_paste","payload":{}}' \
    "$(json_escape "${trace_id}-resolve-image")")")" || return 1
  [[ "$(env_value_from_text result_type "$resolve_image_response")" == "clipboard_image" ]] || return 1
  [[ -n "$(env_value_from_text result_formats "$resolve_image_response")" ]] || return 1
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
  clipboard_trace="host-check-clipboard-$(date +%Y%m%dT%H%M%S)-$$"
  enqueue_clipboard_request "$clipboard_trace" || die "clipboard request failed"
  pass "clipboard helper request processed"
fi

printf 'host smoke test completed\n'
