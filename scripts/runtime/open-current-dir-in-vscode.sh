#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  open-current-dir-in-vscode.sh [--window WINDOW_ID] [--code-command ARG ... --] [target_dir]
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

detect_windows_paths() {
  local localappdata_win="" userprofile_win=""
  localappdata_win="$(trim_cr "$(cmd.exe /c echo %LOCALAPPDATA% 2>/dev/null || true)")"
  userprofile_win="$(trim_cr "$(cmd.exe /c echo %USERPROFILE% 2>/dev/null || true)")"

  [[ -n "$localappdata_win" && -n "$userprofile_win" ]] || return 1

  WINDOWS_LOCALAPPDATA_WIN="$localappdata_win"
  WINDOWS_USERPROFILE_WIN="$userprofile_win"
  WINDOWS_LOCALAPPDATA_WSL="$(wslpath -u "$WINDOWS_LOCALAPPDATA_WIN")"
  WINDOWS_USERPROFILE_WSL="$(wslpath -u "$WINDOWS_USERPROFILE_WIN")"
  HELPER_STATE_WIN="${WINDOWS_LOCALAPPDATA_WIN}\\wezterm-runtime-helper\\state.env"
  HELPER_REQUEST_DIR_WIN="${WINDOWS_LOCALAPPDATA_WIN}\\wezterm-runtime-helper\\requests"
  HELPER_STATE_WSL="${WINDOWS_LOCALAPPDATA_WSL}/wezterm-runtime-helper/state.env"
  HELPER_REQUEST_DIR_WSL="${WINDOWS_LOCALAPPDATA_WSL}/wezterm-runtime-helper/requests"
  WINDOWS_RUNTIME_HOME_WIN="${WINDOWS_USERPROFILE_WIN}\\.wezterm-x"
  WINDOWS_RUNTIME_HOME_WSL="${WINDOWS_USERPROFILE_WSL}/.wezterm-x"
  WINDOWS_HELPER_ENSURE_SCRIPT_WIN="${WINDOWS_RUNTIME_HOME_WIN}\\scripts\\ensure-windows-runtime-helper.ps1"
  WINDOWS_HELPER_WORKER_SCRIPT_WIN="${WINDOWS_RUNTIME_HOME_WIN}\\scripts\\windows-runtime-helper.ps1"
  WINDOWS_VSCODE_SCRIPT_WIN="${WINDOWS_RUNTIME_HOME_WIN}\\scripts\\focus-or-open-vscode.ps1"
  WINDOWS_DIAGNOSTICS_FILE_WIN="${WINDOWS_RUNTIME_HOME_WIN}\\wezterm-debug.log"
}

detect_code_command() {
  if (( ${#code_command[@]} > 0 )); then
    return 0
  fi

  local user_install_wsl="${WINDOWS_LOCALAPPDATA_WSL}/Programs/Microsoft VS Code/Code.exe"
  if [[ -f "$user_install_wsl" ]]; then
    code_command=("${WINDOWS_LOCALAPPDATA_WIN}\\Programs\\Microsoft VS Code\\Code.exe")
    return 0
  fi

  code_command=('C:\Program Files\Microsoft VS Code\Code.exe')
}

helper_state_is_fresh() {
  [[ -f "$HELPER_STATE_WSL" ]] || return 1

  local ready="" pid="" heartbeat_at_ms="" line key value now_ms
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    value="$(trim_cr "${line#*=}")"
    case "$key" in
      ready) ready="$value" ;;
      pid) pid="$value" ;;
      heartbeat_at_ms) heartbeat_at_ms="$value" ;;
    esac
  done < "$HELPER_STATE_WSL"

  [[ "$ready" == "1" ]] || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  [[ "$heartbeat_at_ms" =~ ^[0-9]+$ && "$heartbeat_at_ms" -gt 0 ]] || return 1

  now_ms="$(runtime_log_now_ms)"
  [[ "$now_ms" =~ ^[0-9]+$ ]] || return 1
  (( now_ms - heartbeat_at_ms <= 5000 )) || return 1
  return 0
}

ensure_helper() {
  if helper_state_is_fresh; then
    runtime_log_info alt_o "tmux Alt+o helper already healthy" \
      "state_path=$HELPER_STATE_WSL" \
      "request_dir=$HELPER_REQUEST_DIR_WSL"
    return 0
  fi

  runtime_log_info alt_o "tmux Alt+o ensuring windows helper" \
    "state_path=$HELPER_STATE_WSL" \
    "request_dir=$HELPER_REQUEST_DIR_WSL"

  if ! powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$WINDOWS_HELPER_ENSURE_SCRIPT_WIN" \
    -WorkerScriptPath "$WINDOWS_HELPER_WORKER_SCRIPT_WIN" \
    -StatePath "$HELPER_STATE_WIN" \
    -RequestDir "$HELPER_REQUEST_DIR_WIN" \
    -HeartbeatTimeoutSeconds 5 \
    -HeartbeatIntervalMs 1000 \
    -PollIntervalMs 25 \
    -DiagnosticsEnabled 1 \
    -DiagnosticsCategoryEnabled 1 \
    -DiagnosticsLevel info \
    -DiagnosticsFile "$WINDOWS_DIAGNOSTICS_FILE_WIN" \
    -DiagnosticsMaxBytes 5242880 \
    -DiagnosticsMaxFiles 5 >/dev/null 2>&1; then
    return 1
  fi

  helper_state_is_fresh
}

enqueue_helper_request() {
  local trace_id="$1"
  local request_path=""
  local request_body=""
  local code_part=""
  local wait_i=0

  mkdir -p "$HELPER_REQUEST_DIR_WSL"
  request_path="$HELPER_REQUEST_DIR_WSL/$trace_id.json"

  for code_arg in "${code_command[@]}"; do
    if [[ -n "$code_part" ]]; then
      code_part+=","
    fi
    code_part+="$(json_escape "$code_arg")"
  done

  request_body="{\"kind\":\"vscode_focus_or_open\",\"requested_dir\":$(json_escape "$target_dir"),\"distro\":$(json_escape "$WSL_DISTRO_NAME"),\"trace_id\":$(json_escape "$trace_id"),\"code_command\":[${code_part}]}"
  printf '%s' "$request_body" > "$request_path"

  for (( wait_i=0; wait_i<20; wait_i+=1 )); do
    [[ -f "$request_path" ]] || return 0
    sleep 0.05
  done

  [[ ! -f "$request_path" ]]
}

run_direct_windows_open() {
  local trace_id="$1"
  local command=(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
    -File "$WINDOWS_VSCODE_SCRIPT_WIN"
    -RequestedDir "$target_dir"
    -Distro "$WSL_DISTRO_NAME"
    -TraceId "$trace_id"
    -DiagnosticsEnabled 1
    -DiagnosticsCategoryEnabled 1
    -DiagnosticsLevel info
    -DiagnosticsFile "$WINDOWS_DIAGNOSTICS_FILE_WIN"
    -DiagnosticsMaxBytes 5242880
    -DiagnosticsMaxFiles 5)

  for arg in "${code_command[@]}"; do
    command+=(-CodeArg "$arg")
  done

  "${command[@]}"
}

code_command=()
tmux_window_id=""
window_root=""
start_ms="$(runtime_log_now_ms)"
trace_id="alt_o-$(runtime_log_generate_trace_id)"
export WEZTERM_RUNTIME_TRACE_ID="$trace_id"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)
      tmux_window_id="${2:-}"
      shift 2
      ;;
    --code-command)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
          shift
          break
        fi
        code_command+=("$1")
        shift
      done
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
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

target_dir="${1:-$PWD}"
requested_dir="$target_dir"

if [[ "$target_dir" != /* ]]; then
  runtime_log_error alt_o "expected absolute path" "requested_dir=$target_dir"
  exit 1
fi

if [[ ! -d "$target_dir" ]]; then
  runtime_log_error alt_o "directory does not exist" "requested_dir=$target_dir"
  exit 1
fi

if [[ -n "$tmux_window_id" ]]; then
  window_root="$(tmux_worktree_current_root_for_window "$tmux_window_id" || true)"
  if [[ -n "$window_root" ]]; then
    target_dir="$window_root"
  fi
fi

if [[ -z "$target_dir" ]]; then
  target_dir="$requested_dir"
fi

if [[ -z "$window_root" ]] && repo_root="$(tmux_worktree_repo_root "$target_dir" 2>/dev/null || true)" && [[ -n "$repo_root" ]]; then
  target_dir="$repo_root"
fi

if [[ -z "${WSL_DISTRO_NAME:-}" ]] || ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1 || ! detect_windows_paths; then
  if (( ${#code_command[@]} == 0 )); then
    code_bin="$(command -v code || true)"
    if [[ -z "$code_bin" ]]; then
      runtime_log_error alt_o "code binary was not found" "requested_dir=$requested_dir"
      exit 1
    fi
    code_command=("$code_bin")
  fi

  cd "$target_dir"
  "${code_command[@]}" .
  exit $?
fi

detect_code_command

if ensure_helper && enqueue_helper_request "$trace_id"; then
  runtime_log_info alt_o "tmux Alt+o enqueued helper request" \
    "requested_dir=$requested_dir" \
    "effective_dir=$target_dir" \
    "request_dir=$HELPER_REQUEST_DIR_WSL" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

runtime_log_warn alt_o "tmux Alt+o helper path failed; falling back to direct windows open" \
  "requested_dir=$requested_dir" \
  "effective_dir=$target_dir" \
  "request_dir=$HELPER_REQUEST_DIR_WSL" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")"

if run_direct_windows_open "$trace_id"; then
  runtime_log_info alt_o "tmux Alt+o direct windows open completed" \
    "requested_dir=$requested_dir" \
    "effective_dir=$target_dir" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

status=$?
runtime_log_error alt_o "tmux Alt+o direct windows open failed" \
  "requested_dir=$requested_dir" \
  "effective_dir=$target_dir" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")" \
  "exit_code=$status"
exit "$status"
