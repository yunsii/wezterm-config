#!/usr/bin/env bash

windows_runtime_trim_cr() {
  printf '%s' "${1-}" | tr -d '\r'
}

windows_runtime_detect_paths() {
  local localappdata_win="" userprofile_win=""

  command -v cmd.exe >/dev/null 2>&1 || return 1
  command -v wslpath >/dev/null 2>&1 || return 1

  localappdata_win="$(windows_runtime_trim_cr "$(cmd.exe /c echo %LOCALAPPDATA% 2>/dev/null || true)")"
  userprofile_win="$(windows_runtime_trim_cr "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null || true)")"

  [[ -n "$localappdata_win" && -n "$userprofile_win" ]] || return 1

  WINDOWS_LOCALAPPDATA_WIN="$localappdata_win"
  WINDOWS_USERPROFILE_WIN="$userprofile_win"
  WINDOWS_LOCALAPPDATA_WSL="$(wslpath -u "$WINDOWS_LOCALAPPDATA_WIN")"
  WINDOWS_USERPROFILE_WSL="$(wslpath -u "$WINDOWS_USERPROFILE_WIN")"

  WINDOWS_RUNTIME_STATE_WIN="${WINDOWS_LOCALAPPDATA_WIN}\\wezterm-runtime"
  WINDOWS_RUNTIME_STATE_WSL="${WINDOWS_LOCALAPPDATA_WSL}/wezterm-runtime"
  WINDOWS_RUNTIME_HOME_WIN="${WINDOWS_USERPROFILE_WIN}\\.wezterm-x"
  WINDOWS_RUNTIME_HOME_WSL="${WINDOWS_USERPROFILE_WSL}/.wezterm-x"

  WINDOWS_HELPER_STATE_WIN="${WINDOWS_RUNTIME_STATE_WIN}\\state\\helper\\state.env"
  WINDOWS_HELPER_STATE_WSL="${WINDOWS_RUNTIME_STATE_WSL}/state/helper/state.env"
  WINDOWS_HELPER_WINDOW_CACHE_WSL="${WINDOWS_RUNTIME_STATE_WSL}/cache/helper/window-cache.json"
  WINDOWS_HELPER_CLIENT_WSL="${WINDOWS_RUNTIME_STATE_WSL}/bin/helperctl.exe"
  WINDOWS_HELPER_LOG_WSL="${WINDOWS_RUNTIME_STATE_WSL}/logs/helper.log"
  WINDOWS_HELPER_ENSURE_SCRIPT_WIN="${WINDOWS_RUNTIME_HOME_WIN}\\scripts\\ensure-windows-runtime-helper.ps1"
  WINDOWS_HELPER_ENSURE_SCRIPT_WSL="${WINDOWS_RUNTIME_HOME_WSL}/scripts/ensure-windows-runtime-helper.ps1"
  WINDOWS_HELPER_IPC_ENDPOINT='\\.\pipe\wezterm-host-helper-v1'

  WINDOWS_CLIPBOARD_OUTPUT_WIN="${WINDOWS_RUNTIME_STATE_WIN}\\state\\clipboard\\exports"
}

windows_runtime_state_value() {
  local key="${1:?missing key}"
  local file="${2:?missing file}"
  awk -F= -v wanted="$key" '$1==wanted {print $2; exit}' "$file" | tr -d '\r'
}

windows_runtime_now_ms() {
  if declare -F runtime_log_now_ms >/dev/null 2>&1; then
    runtime_log_now_ms
    return 0
  fi

  date +%s%3N
}

windows_runtime_helper_state_is_fresh() {
  local state_file="${1:-${WINDOWS_HELPER_STATE_WSL:-}}"
  local max_age_ms="${2:-5000}"
  local ready="" pid="" heartbeat="" now_ms=""

  [[ -n "$state_file" && -f "$state_file" ]] || return 1

  ready="$(windows_runtime_state_value ready "$state_file")"
  pid="$(windows_runtime_state_value pid "$state_file")"
  heartbeat="$(windows_runtime_state_value heartbeat_at_ms "$state_file")"
  now_ms="$(windows_runtime_now_ms)"

  [[ "$ready" == "1" ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  [[ "$heartbeat" =~ ^[0-9]+$ && "$heartbeat" -gt 0 ]] || return 1
  [[ "$now_ms" =~ ^[0-9]+$ ]] || return 1
  (( now_ms - heartbeat <= max_age_ms )) || return 1
}
