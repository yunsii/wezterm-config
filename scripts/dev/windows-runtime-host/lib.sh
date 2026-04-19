#!/usr/bin/env bash

WINDOWS_RUNTIME_HOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_RUNTIME_HOST_REPO_ROOT="$(cd "$WINDOWS_RUNTIME_HOST_LIB_DIR/../../.." && pwd)"
WINDOWS_SHELL_LIB="$WINDOWS_RUNTIME_HOST_REPO_ROOT/scripts/runtime/windows-shell-lib.sh"
WINDOWS_RUNTIME_PATHS_LIB="$WINDOWS_RUNTIME_HOST_REPO_ROOT/scripts/runtime/windows-runtime-paths-lib.sh"

# shellcheck disable=SC1091
source "$WINDOWS_SHELL_LIB"
# shellcheck disable=SC1091
source "$WINDOWS_RUNTIME_PATHS_LIB"

host_check_usage() {
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

host_check_json_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

host_check_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

host_check_pass() {
  printf 'PASS %s\n' "$*"
}

host_check_warn() {
  printf 'WARN %s\n' "$*" >&2
}

host_check_trace() {
  printf '[host-check] %s\n' "$*"
}

host_check_init_environment() {
  local repo_root="${1:?missing repo root}"

  command -v powershell.exe >/dev/null 2>&1 || host_check_die "powershell.exe not found in PATH"
  command -v cmd.exe >/dev/null 2>&1 || host_check_die "cmd.exe not found in PATH"
  command -v wslpath >/dev/null 2>&1 || host_check_die "wslpath not found in PATH"
  windows_runtime_detect_paths || host_check_die "failed to resolve Windows LOCALAPPDATA/USERPROFILE"

  HOST_CHECK_REPO_ROOT="$repo_root"
  HOST_CHECK_HELPER_LOG_WSL="$WINDOWS_HELPER_LOG_WSL"
  HOST_CHECK_HELPER_ENSURE_WSL="$WINDOWS_HELPER_ENSURE_SCRIPT_WSL"
  HOST_CHECK_HELPER_STATE_WIN="$WINDOWS_HELPER_STATE_WIN"
  HOST_CHECK_HELPER_STATE_WSL="$WINDOWS_HELPER_STATE_WSL"
  HOST_CHECK_HELPER_WINDOW_CACHE_WSL="$WINDOWS_HELPER_WINDOW_CACHE_WSL"
  HOST_CHECK_HELPER_CLIENT_WSL="$WINDOWS_HELPER_CLIENT_WSL"
  HOST_CHECK_HELPER_IPC_ENDPOINT="$WINDOWS_HELPER_IPC_ENDPOINT"
  HOST_CHECK_CLIPBOARD_OUTPUT_WIN="$WINDOWS_CLIPBOARD_OUTPUT_WIN"
  HOST_CHECK_RUNTIME_STATE_WIN="$WINDOWS_RUNTIME_STATE_WIN"
  HOST_CHECK_RUNTIME_HOME_WSL="$WINDOWS_RUNTIME_HOME_WSL"

  HOST_CHECK_DISTRO="${WSL_DISTRO_NAME:-}"
  [[ -n "$HOST_CHECK_DISTRO" ]] || HOST_CHECK_DISTRO="Ubuntu-22.04"
}

host_check_helper_state_fresh() {
  windows_runtime_helper_state_is_fresh "$HOST_CHECK_HELPER_STATE_WSL" 5000
}

host_check_wait_for_log_match() {
  local pattern="$1"
  local limit=$((HOST_CHECK_TIMEOUT_SECONDS * 10))
  local i
  for ((i=0; i<limit; i+=1)); do
    if rg -n "$pattern" "$HOST_CHECK_HELPER_LOG_WSL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

host_check_wait_for_trace_event() {
  local trace_id="$1"
  local event_pattern="$2"
  host_check_wait_for_log_match "trace_id=\"${trace_id}\".*${event_pattern}" \
    || host_check_wait_for_log_match "${event_pattern}.*trace_id=\"${trace_id}\""
}

host_check_ensure_helper() {
  local helper_ensure_win=""
  helper_ensure_win="$(wslpath -w "$HOST_CHECK_HELPER_ENSURE_WSL")"
  host_check_trace "step=ensure-helper helper_ensure_win=$helper_ensure_win state_path=$HOST_CHECK_HELPER_STATE_WIN"
  windows_run_powershell_script_utf8 "$helper_ensure_win" \
    -StatePath "$HOST_CHECK_HELPER_STATE_WIN" \
    -ClipboardOutputDir "$HOST_CHECK_CLIPBOARD_OUTPUT_WIN" \
    -ClipboardWslDistro "$HOST_CHECK_DISTRO" \
    -ClipboardImageReadRetryCount 12 \
    -ClipboardImageReadRetryDelayMs 100 \
    -ClipboardCleanupMaxAgeHours 48 \
    -ClipboardCleanupMaxFiles 32 \
    -HeartbeatTimeoutSeconds 5 \
    -HeartbeatIntervalMs 1000 \
    -DiagnosticsEnabled 1 \
    -DiagnosticsCategoryEnabled 1 \
    -DiagnosticsLevel info \
    -DiagnosticsFile "${HOST_CHECK_RUNTIME_STATE_WIN}\\logs\\helper.log" \
    -DiagnosticsMaxBytes 5242880 \
    -DiagnosticsMaxFiles 5 >/dev/null
}

host_check_invoke_helper_request() {
  local request_body="$1"
  local request_b64=""
  request_b64="$(printf '%s' "$request_body" | base64 | tr -d '\r\n')"
  "$HOST_CHECK_HELPER_CLIENT_WSL" request --pipe "$HOST_CHECK_HELPER_IPC_ENDPOINT" --payload-base64 "$request_b64" --timeout-ms $((HOST_CHECK_TIMEOUT_SECONDS * 1000)) >/dev/null 2>&1
}

host_check_invoke_helper_request_capture() {
  local request_body="$1"
  local request_b64=""
  request_b64="$(printf '%s' "$request_body" | base64 | tr -d '\r\n')"
  "$HOST_CHECK_HELPER_CLIENT_WSL" request --pipe "$HOST_CHECK_HELPER_IPC_ENDPOINT" --payload-base64 "$request_b64" --timeout-ms $((HOST_CHECK_TIMEOUT_SECONDS * 1000))
}

host_check_env_value_from_text() {
  local key="$1"
  local text="$2"
  awk -F= -v wanted="$key" '$1==wanted {print $2; exit}' <<<"$text" | tr -d '\r'
}

host_check_detect_vscode_exe() {
  local user_install_wsl="${WINDOWS_LOCALAPPDATA_WSL}/Programs/Microsoft VS Code/Code.exe"
  if [[ -f "$user_install_wsl" ]]; then
    printf '%s\n' "${WINDOWS_LOCALAPPDATA_WIN}\\Programs\\Microsoft VS Code\\Code.exe"
    return 0
  fi
  printf 'C:\\Program Files\\Microsoft VS Code\\Code.exe\n'
}

host_check_detect_chrome_profile_dir() {
  local constants_file="${HOST_CHECK_REPO_ROOT}/wezterm-x/local/constants.lua"
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

host_check_chrome_registry_has_entry() {
  [[ -f "$HOST_CHECK_HELPER_WINDOW_CACHE_WSL" ]] || return 1
  perl -0ne '
    if (
      /"Chrome"\s*:\s*\{\s*"[^"]+"/s ||
      /"Entries"\s*:\s*\{.*?"chrome"\s*:\s*\{\s*"[^"]+"/s
    ) {
      exit 0;
    }
    exit 1;
  ' "$HOST_CHECK_HELPER_WINDOW_CACHE_WSL"
}

host_check_chrome_process_exists() {
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
