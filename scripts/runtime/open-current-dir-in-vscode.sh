#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/windows-runtime-paths-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/windows-shell-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  open-current-dir-in-vscode.sh [--window WINDOW_ID] [--code-command ARG ... --] [target_dir]
EOF
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
  windows_runtime_detect_paths || return 1
  HELPER_STATE_WIN="$WINDOWS_HELPER_STATE_WIN"
  HELPER_STATE_WSL="$WINDOWS_HELPER_STATE_WSL"
  HELPER_CLIENT_WSL="$WINDOWS_HELPER_CLIENT_WSL"
  HELPER_IPC_ENDPOINT="$WINDOWS_HELPER_IPC_ENDPOINT"
  WINDOWS_DIAGNOSTICS_FILE_WIN="${WINDOWS_RUNTIME_STATE_WIN}\\logs\\helper.log"
}

load_vscode_profile_from_shared_env() {
  local shared_env_file="${WEZTERM_VSCODE_SHARED_ENV_FILE:-$SCRIPT_DIR/../../wezterm-x/local/shared.env}"
  if [[ -z "${WEZTERM_VSCODE_PROFILE+x}" && -f "$shared_env_file" ]]; then
    # shellcheck disable=SC1090
    source "$shared_env_file"
  fi
}

append_profile_arg() {
  if [[ -n "${WEZTERM_VSCODE_PROFILE:-}" ]]; then
    code_command+=(--profile "$WEZTERM_VSCODE_PROFILE")
  fi
}

detect_code_command() {
  if (( ${#code_command[@]} > 0 )); then
    return 0
  fi

  load_vscode_profile_from_shared_env

  local user_install_wsl="${WINDOWS_LOCALAPPDATA_WSL}/Programs/Microsoft VS Code/Code.exe"
  if [[ -f "$user_install_wsl" ]]; then
    code_command=("${WINDOWS_LOCALAPPDATA_WIN}\\Programs\\Microsoft VS Code\\Code.exe")
    append_profile_arg
    return 0
  fi

  code_command=('C:\Program Files\Microsoft VS Code\Code.exe')
  append_profile_arg
}

helper_state_is_fresh() {
  windows_runtime_helper_state_is_fresh "$HELPER_STATE_WSL" 5000
}

ensure_helper() {
  if helper_state_is_fresh; then
    runtime_log_info vscode "tmux Alt+v helper already healthy" \
      "state_path=$HELPER_STATE_WSL"
    return 0
  fi

  runtime_log_info vscode "tmux Alt+v ensuring windows helper" \
    "state_path=$HELPER_STATE_WSL"

  if ! windows_run_powershell_script_utf8 "$WINDOWS_HELPER_ENSURE_SCRIPT_WIN" \
    -StatePath "$HELPER_STATE_WIN" \
    -HeartbeatTimeoutSeconds 5 \
    -HeartbeatIntervalMs 1000 \
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

invoke_helper_request() {
  local trace_id="$1"
  local request_body=""
  local request_body_b64=""
  local code_part=""

  for code_arg in "${code_command[@]}"; do
    if [[ -n "$code_part" ]]; then
      code_part+=","
    fi
    code_part+="$(json_escape "$code_arg")"
  done

  request_body="{\"version\":2,\"trace_id\":$(json_escape "$trace_id"),\"message_type\":\"request\",\"domain\":\"vscode\",\"action\":\"focus_or_open\",\"payload\":{\"requested_dir\":$(json_escape "$target_dir"),\"distro\":$(json_escape "$WSL_DISTRO_NAME"),\"code_command\":[${code_part}]}}"
  request_body_b64="$(printf '%s' "$request_body" | base64 | tr -d '\r\n')"
  "$HELPER_CLIENT_WSL" request --pipe "$HELPER_IPC_ENDPOINT" --payload-base64 "$request_body_b64" --timeout-ms 5000 >/dev/null 2>&1
}

run_direct_windows_open() {
  local trace_id="$1"
  local folder_uri="vscode-remote://wsl+${WSL_DISTRO_NAME}${target_dir}"
  local code_exe="${code_command[0]}"
  local arg_list=""
  local i
  for (( i=1; i<${#code_command[@]}; i++ )); do
    if [[ -n "$arg_list" ]]; then
      arg_list+=", "
    fi
    arg_list+="$(windows_powershell_quote "${code_command[i]}")"
  done
  if [[ -n "$arg_list" ]]; then
    arg_list+=", "
  fi
  arg_list+="'--folder-uri', $(windows_powershell_quote "$folder_uri")"
  local command=""
  command="$(cat <<EOF
Start-Process -FilePath $(windows_powershell_quote "$code_exe") -ArgumentList @(${arg_list})
EOF
)"
  windows_run_powershell_command_utf8 "$command" >/dev/null 2>&1
}

code_command=()
tmux_window_id=""
window_root=""
start_ms="$(runtime_log_now_ms)"
trace_id="vscode-$(runtime_log_generate_trace_id)"
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
  runtime_log_error vscode "expected absolute path" "requested_dir=$target_dir"
  exit 1
fi

if [[ ! -d "$target_dir" ]]; then
  runtime_log_error vscode "directory does not exist" "requested_dir=$target_dir"
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
      runtime_log_error vscode "code binary was not found" "requested_dir=$requested_dir"
      exit 1
    fi
    code_command=("$code_bin")
  fi

  cd "$target_dir"
  "${code_command[@]}" .
  exit $?
fi

detect_code_command

if ensure_helper && invoke_helper_request "$trace_id"; then
  runtime_log_info vscode "tmux Alt+v sent helper ipc request" \
    "requested_dir=$requested_dir" \
    "effective_dir=$target_dir" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

runtime_log_warn vscode "tmux Alt+v helper path failed; falling back to direct windows open" \
  "requested_dir=$requested_dir" \
  "effective_dir=$target_dir" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")"

if run_direct_windows_open "$trace_id"; then
  runtime_log_info vscode "tmux Alt+v direct windows open completed" \
    "requested_dir=$requested_dir" \
    "effective_dir=$target_dir" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

status=$?
runtime_log_error vscode "tmux Alt+v direct windows open failed" \
  "requested_dir=$requested_dir" \
  "effective_dir=$target_dir" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")" \
  "exit_code=$status"
exit "$status"
