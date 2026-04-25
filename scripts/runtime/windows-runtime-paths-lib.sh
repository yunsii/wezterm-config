#!/usr/bin/env bash

windows_runtime_trim_cr() {
  printf '%s' "${1-}" | tr -d '\r'
}

windows_runtime_detect_paths() {
  # Fast path 1: in-process memoization. Multiple call sites in one
  # bash invocation (e.g. attention_state_path called by both _init and
  # _read) skip the second cmd.exe round-trip.
  if [[ -n "${WINDOWS_RUNTIME_STATE_WSL:-}" && -n "${WINDOWS_LOCALAPPDATA_WSL:-}" && -n "${WINDOWS_USERPROFILE_WSL:-}" ]]; then
    return 0
  fi

  # Fast path 2: persistent disk cache. Each cmd.exe spawn from WSL
  # costs ~100-200ms (Windows process creation across WSL2 interop);
  # the menu.sh hot path triggers detection ~3 times → up to 600ms of
  # pure cmd.exe overhead per Alt+/. The values cached here
  # (LOCALAPPDATA, USERPROFILE) are stable per-machine — they only
  # change on user account rename or env edit, so a 24h TTL is
  # generous. Bypass with WEZTERM_NO_PATH_CACHE=1 (used by the bench
  # harness when measuring cold-start cost honestly).
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wezterm-runtime"
  local cache_file="$cache_dir/windows-paths.env"
  local cache_ttl_seconds="${WEZTERM_WINDOWS_PATHS_CACHE_TTL:-86400}"
  if [[ -z "${WEZTERM_NO_PATH_CACHE:-}" && -f "$cache_file" ]]; then
    local cache_age
    cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if (( cache_age >= 0 && cache_age < cache_ttl_seconds )); then
      # shellcheck disable=SC1090
      . "$cache_file" 2>/dev/null || true
      if [[ -n "${WINDOWS_RUNTIME_STATE_WSL:-}" && -n "${WINDOWS_LOCALAPPDATA_WSL:-}" && -n "${WINDOWS_USERPROFILE_WSL:-}" ]]; then
        return 0
      fi
    fi
  fi

  # Slow path: actual cmd.exe + wslpath detection. Runs at most once
  # per cache TTL window, or whenever the cache is missing / corrupt /
  # explicitly bypassed.
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

  # Persist for the next bash invocation. Atomic write so a concurrent
  # reader never sees a half-written file. Failure is non-fatal — the
  # next caller just re-runs cmd.exe.
  if [[ -z "${WEZTERM_NO_PATH_CACHE:-}" ]]; then
    mkdir -p "$cache_dir" 2>/dev/null || return 0
    local tmp="$cache_file.tmp.$$"
    {
      printf 'WINDOWS_LOCALAPPDATA_WIN=%q\n' "$WINDOWS_LOCALAPPDATA_WIN"
      printf 'WINDOWS_USERPROFILE_WIN=%q\n' "$WINDOWS_USERPROFILE_WIN"
      printf 'WINDOWS_LOCALAPPDATA_WSL=%q\n' "$WINDOWS_LOCALAPPDATA_WSL"
      printf 'WINDOWS_USERPROFILE_WSL=%q\n' "$WINDOWS_USERPROFILE_WSL"
      printf 'WINDOWS_RUNTIME_STATE_WIN=%q\n' "$WINDOWS_RUNTIME_STATE_WIN"
      printf 'WINDOWS_RUNTIME_STATE_WSL=%q\n' "$WINDOWS_RUNTIME_STATE_WSL"
      printf 'WINDOWS_RUNTIME_HOME_WIN=%q\n' "$WINDOWS_RUNTIME_HOME_WIN"
      printf 'WINDOWS_RUNTIME_HOME_WSL=%q\n' "$WINDOWS_RUNTIME_HOME_WSL"
      printf 'WINDOWS_HELPER_STATE_WIN=%q\n' "$WINDOWS_HELPER_STATE_WIN"
      printf 'WINDOWS_HELPER_STATE_WSL=%q\n' "$WINDOWS_HELPER_STATE_WSL"
      printf 'WINDOWS_HELPER_WINDOW_CACHE_WSL=%q\n' "$WINDOWS_HELPER_WINDOW_CACHE_WSL"
      printf 'WINDOWS_HELPER_CLIENT_WSL=%q\n' "$WINDOWS_HELPER_CLIENT_WSL"
      printf 'WINDOWS_HELPER_LOG_WSL=%q\n' "$WINDOWS_HELPER_LOG_WSL"
      printf 'WINDOWS_HELPER_ENSURE_SCRIPT_WIN=%q\n' "$WINDOWS_HELPER_ENSURE_SCRIPT_WIN"
      printf 'WINDOWS_HELPER_ENSURE_SCRIPT_WSL=%q\n' "$WINDOWS_HELPER_ENSURE_SCRIPT_WSL"
      printf 'WINDOWS_HELPER_IPC_ENDPOINT=%q\n' "$WINDOWS_HELPER_IPC_ENDPOINT"
      printf 'WINDOWS_CLIPBOARD_OUTPUT_WIN=%q\n' "$WINDOWS_CLIPBOARD_OUTPUT_WIN"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache_file" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
  fi
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
