#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_PROMPT_LIB="$SCRIPT_DIR/sync-prompt-lib.sh"
RUNTIME_LOG_LIB="$SCRIPT_DIR/../../../scripts/runtime/runtime-log-lib.sh"
WINDOWS_SHELL_LIB="$SCRIPT_DIR/../../../scripts/runtime/windows-shell-lib.sh"

# Shared with the prompt test script so output regressions are easy to verify.
source "$SYNC_PROMPT_LIB"
# shellcheck disable=SC1091
source "$RUNTIME_LOG_LIB"
# shellcheck disable=SC1091
source "$WINDOWS_SHELL_LIB"
export WEZTERM_RUNTIME_LOG_SOURCE="sync-runtime"

sync_trace() {
  printf '[sync] %s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  skills/wezterm-runtime-sync/scripts/sync-runtime.sh
  skills/wezterm-runtime-sync/scripts/sync-runtime.sh --list-targets
  skills/wezterm-runtime-sync/scripts/sync-runtime.sh --target-home /absolute/path

Options:
  --list-targets        Print candidate user home directories and exit.
  --target-home PATH    Sync directly to PATH and cache it in .sync-target.
  -h, --help            Show this help text.

Environment:
  WEZTERM_CONFIG_REPO   Repository root. Defaults to the current working directory.
EOF
}

install_windows_helper_manager() {
  local target_runtime_dir="${1:?missing target runtime dir}"
  local install_script="$target_runtime_dir/scripts/install-windows-runtime-helper-manager.ps1"
  local install_script_win="" runtime_dir_win="" install_output="" manager_path=""
  local target_home="" target_home_win="" diagnostics_file_win=""
  local install_source="${WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE:-auto}"

  [[ "$target_runtime_dir" =~ ^/mnt/[A-Za-z]/Users/ ]] || return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0
  [[ -f "$install_script" ]] || return 0
  case "$install_source" in
    auto|local|release) ;;
    *)
      printf 'Unsupported WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE: %s\n' "$install_source" >&2
      return 1
      ;;
  esac

  install_script_win="$(wslpath -w "$install_script" 2>/dev/null || true)"
  runtime_dir_win="$(wslpath -w "$target_runtime_dir" 2>/dev/null || true)"
  target_home="$(dirname "$target_runtime_dir")"
  target_home_win="$(wslpath -w "$target_home" 2>/dev/null || true)"
  [[ -n "$target_home_win" ]] && diagnostics_file_win="${target_home_win}\\AppData\\Local\\wezterm-runtime\\logs\\helper.log"
  [[ -n "$install_script_win" && -n "$runtime_dir_win" && -n "$diagnostics_file_win" ]] || return 0

  sync_trace "step=helper-install status=starting target_runtime_dir=$target_runtime_dir runtime_dir_win=$runtime_dir_win install_script_win=$install_script_win install_source=$install_source"
  if ! install_output="$(
    windows_run_powershell_script_utf8 "$install_script_win" \
      -RuntimeDir "$runtime_dir_win" \
      -InstallSource "$install_source" \
      -Trigger runtime_sync \
      -DiagnosticsEnabled 1 \
      -DiagnosticsCategoryEnabled 1 \
      -DiagnosticsLevel info \
      -DiagnosticsFile "$diagnostics_file_win" \
      -DiagnosticsMaxBytes 5242880 \
      -DiagnosticsMaxFiles 5 2>&1 | tr -d '\r'
  )"; then
    [[ -n "$install_output" ]] && printf '%s\n' "$install_output" >&2
    sync_trace "step=helper-install status=failed target_runtime_dir=$target_runtime_dir install_source=$install_source"
    runtime_log_error sync "failed to install windows helper manager after sync" \
      "target_runtime_dir=$target_runtime_dir" \
      "install_source=$install_source"
    return 1
  fi

  [[ -n "$install_output" ]] && printf '%s\n' "$install_output"
  manager_path="$(printf '%s\n' "$install_output" | tail -n 1)"
  sync_trace "step=helper-install status=completed manager_path=${manager_path:-unknown} install_source=$install_source"
  runtime_log_info sync "installed windows helper manager after sync" \
    "target_runtime_dir=$target_runtime_dir" \
    "manager_path=${manager_path:-unknown}" \
    "install_source=$install_source"
  return 0
}

ensure_windows_helper_running() {
  local target_runtime_dir="${1:?missing target runtime dir}"
  local ensure_script="$target_runtime_dir/scripts/ensure-windows-runtime-helper.ps1"
  local ensure_script_win="" target_home="" target_home_win=""
  local state_path_win="" diagnostics_file_win="" ensure_output=""

  [[ "$target_runtime_dir" =~ ^/mnt/[A-Za-z]/Users/ ]] || return 0
  command -v powershell.exe >/dev/null 2>&1 || return 0
  command -v wslpath >/dev/null 2>&1 || return 0
  [[ -f "$ensure_script" ]] || return 0

  ensure_script_win="$(wslpath -w "$ensure_script" 2>/dev/null || true)"
  target_home="$(dirname "$target_runtime_dir")"
  target_home_win="$(wslpath -w "$target_home" 2>/dev/null || true)"
  [[ -n "$ensure_script_win" && -n "$target_home_win" ]] || return 0

  state_path_win="${target_home_win}\\AppData\\Local\\wezterm-runtime\\state\\helper\\state.env"
  diagnostics_file_win="${target_home_win}\\AppData\\Local\\wezterm-runtime\\logs\\helper.log"

  sync_trace "step=helper-ensure status=starting target_runtime_dir=$target_runtime_dir ensure_script_win=$ensure_script_win"
  if ! ensure_output="$(
    windows_run_powershell_script_utf8 "$ensure_script_win" \
      -StatePath "$state_path_win" \
      -HeartbeatIntervalMs 250 \
      -HeartbeatTimeoutSeconds 5 \
      -DiagnosticsEnabled 1 \
      -DiagnosticsCategoryEnabled 1 \
      -DiagnosticsLevel info \
      -DiagnosticsFile "$diagnostics_file_win" \
      -DiagnosticsMaxBytes 5242880 \
      -DiagnosticsMaxFiles 5 2>&1 | tr -d '\r'
  )"; then
    [[ -n "$ensure_output" ]] && printf '%s\n' "$ensure_output" >&2
    sync_trace "step=helper-ensure status=failed target_runtime_dir=$target_runtime_dir"
    runtime_log_warn sync "failed to ensure windows helper running after install" \
      "target_runtime_dir=$target_runtime_dir"
    return 0
  fi

  sync_trace "step=helper-ensure status=completed target_runtime_dir=$target_runtime_dir"
  runtime_log_info sync "ensured windows helper running after install" \
    "target_runtime_dir=$target_runtime_dir"
  return 0
}

write_text_file_atomic() {
  local target_path="${1:?missing target path}"
  local temp_path="${target_path}.tmp.$$"
  cat > "$temp_path"
  mv -f "$temp_path" "$target_path"
}

copy_file_atomic() {
  local source_path="${1:?missing source path}"
  local target_path="${2:?missing target path}"
  if [[ -f "$target_path" ]] && cmp -s "$source_path" "$target_path"; then
    return 0
  fi
  local temp_path="${target_path}.tmp.$$"
  cp "$source_path" "$temp_path"
  mv -f "$temp_path" "$target_path"
}

write_agent_tools_file() {
  local target_runtime_dir="${1:?missing target runtime dir}"
  local repo_root_path="${2:?missing repo root path}"
  local target_file="$target_runtime_dir/agent-tools.env"
  local clipboard_wrapper="$repo_root_path/scripts/runtime/agent-clipboard.sh"

  write_text_file_atomic "$target_file" <<EOF
version=1
repo_root=$repo_root_path
agent_clipboard=$clipboard_wrapper
EOF
}

wait_for_flow() {
  local flow_name="${1:?missing flow name}"
  local pid="${2:-}"

  if [[ -z "$pid" ]]; then
    return 0
  fi

  sync_trace "flow=$flow_name status=waiting pid=$pid"
  wait "$pid"
}

lua_quote() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "$value"
}

lua_runtime_path() {
  local path="${1:?missing path}"
  if [[ "$path" =~ ^/mnt/[A-Za-z]/ ]]; then
    wslpath -w "$path"
    return 0
  fi

  printf '%s\n' "$path"
}

maybe_reload_tmux() {
  local repo_root="${1:?missing repo root}"
  local reload_script="$repo_root/scripts/dev/reload-tmux.sh"
  sync_trace "step=tmux-reload status=checking reload_script=$reload_script"

  if [[ ! -f "$reload_script" ]]; then
    runtime_log_info sync "skipped tmux reload after sync" "reason=reload_script_missing" "reload_script=$reload_script"
    sync_trace "step=tmux-reload status=skipped reason=reload_script_missing"
    printf 'Skipped tmux reload: missing reload script %s\n' "$reload_script"
    return 0
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    runtime_log_info sync "skipped tmux reload after sync" "reason=tmux_not_installed"
    sync_trace "step=tmux-reload status=skipped reason=tmux_not_installed"
    printf 'Skipped tmux reload: tmux is not installed\n'
    return 0
  fi

  if ! tmux list-sessions >/dev/null 2>&1; then
    runtime_log_info sync "skipped tmux reload after sync" "reason=no_accessible_tmux_server"
    sync_trace "step=tmux-reload status=skipped reason=no_accessible_tmux_server"
    printf 'Skipped tmux reload: no accessible tmux server\n'
    return 0
  fi

  if bash "$reload_script"; then
    runtime_log_info sync "reloaded tmux config after sync" "reload_script=$reload_script"
    sync_trace "step=tmux-reload status=completed reload_script=$reload_script"
    return 0
  fi

  runtime_log_error sync "tmux reload after sync failed" "reload_script=$reload_script"
  sync_trace "step=tmux-reload status=failed reload_script=$reload_script"
  printf 'Warning: synced runtime files, but tmux reload failed: %s\n' "$reload_script" >&2
}

resolve_repo_root() {
  local repo_root="${WEZTERM_CONFIG_REPO:-$PWD}"
  [[ -d "$repo_root" ]] || { printf 'Repository root does not exist: %s\n' "$repo_root" >&2; return 1; }
  repo_root="$(cd "$repo_root" && pwd -P)"
  [[ -f "$repo_root/wezterm.lua" ]] || { printf 'Expected %s/wezterm.lua. Run from the repo root or set WEZTERM_CONFIG_REPO.\n' "$repo_root" >&2; return 1; }
  [[ -d "$repo_root/wezterm-x" ]] || { printf 'Expected %s/wezterm-x. Run from the repo root or set WEZTERM_CONFIG_REPO.\n' "$repo_root" >&2; return 1; }
  printf '%s\n' "$repo_root"
}

resolve_main_repo_root() {
  local repo_root="${1:?missing repo root}"
  local common_dir=""

  common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null || true)"
  fi

  if [[ -z "$common_dir" ]]; then
    printf '%s\n' "$repo_root"
    return 0
  fi

  if [[ "$common_dir" != /* ]]; then
    common_dir="$(
      cd "$repo_root"
      cd "$common_dir"
      pwd -P
    )"
  fi

  dirname "$common_dir"
}

target_runtime_state_dir() {
  local target_home="${1:?missing target home}"

  if [[ "$target_home" =~ ^/mnt/[A-Za-z]/Users/[^/]+$ ]]; then
    printf '%s/AppData/Local/wezterm-runtime\n' "$target_home"
    return 0
  fi

  printf '%s/.local/state/wezterm-runtime\n' "$target_home"
}

append_unique_candidate() {
  local entry="$1"
  local existing

  for existing in "${DETECTED_CANDIDATES[@]:-}"; do
    if [[ "$existing" == "$entry" ]]; then
      return 0
    fi
  done

  DETECTED_CANDIDATES+=("$entry")
}

DETECTED_CANDIDATES=()

detect_candidate_homes() {
  DETECTED_CANDIDATES=()
  local roots=()
  local uname
  uname="$(uname -s)"
  [[ -n "$HOME" ]] && roots+=("$(dirname "$HOME")")
  case "$uname" in
    Linux)
      roots+=("/home" "/root")
      [[ -d /mnt/c/Users ]] && roots+=("/mnt/c/Users")
      ;;
    Darwin)
      roots+=("/Users")
      ;;
    *)
      roots+=("/home" "/Users")
      ;;
  esac

  local base
  for base in "${roots[@]}"; do
    [[ -d "$base" ]] || continue
    local entry
    for entry in "$base"/*; do
      [[ -d "$entry" ]] || continue
      local name
      name="$(basename "$entry")"
      [[ -n "$name" ]] || continue
      if [[ "$base" == "/mnt/c/Users" ]] && is_system_windows_profile "$name"; then
        continue
      fi
      append_unique_candidate "$entry"
    done
  done
}

is_system_windows_profile() {
  local name="$1"
  case "$name" in
    "All Users"|"Default"|"Default User"|"Public"|"desktop.ini"|"defaultuser0"|"WDAGUtilityAccount")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_candidate_homes() {
  local lang
  lang="$(sync_prompt_language)"

  detect_candidate_homes
  [[ ${#DETECTED_CANDIDATES[@]} -gt 0 ]] || { sync_prompt_no_dir_message "$lang" >&2; return 1; }
  runtime_log_info sync "listed sync target candidates" "candidate_count=${#DETECTED_CANDIDATES[@]}"

  printf '%s\n' "${DETECTED_CANDIDATES[@]}"
}

validate_explicit_target_home() {
  local target="$1"
  local lang
  lang="$(sync_prompt_language)"

  [[ "$target" =~ ^/ ]] || { sync_prompt_abs_message "$lang" >&2; return 1; }
  [[ -d "$target" ]] || { sync_prompt_missing_message "$lang" >&2; return 1; }
}

load_cached_target() {
  if [[ -n "${WEZTERM_SYNC_TARGET:-}" ]]; then
    runtime_log_info sync "using sync target from environment" "target_home=$WEZTERM_SYNC_TARGET"
    printf '%s\n' "$WEZTERM_SYNC_TARGET"
    return 0
  fi
  if [[ -f "$SYNC_CACHE_FILE" ]]; then
    local cached
    cached="$(< "$SYNC_CACHE_FILE")"
    if [[ -n "$cached" ]]; then
      runtime_log_info sync "using cached sync target" "target_home=$cached" "cache_file=$SYNC_CACHE_FILE"
      printf '%s\n' "$cached"
      return 0
    fi
  fi
  return 1
}

prompt_user_for_target() {
  local lang
  lang="$(sync_prompt_language)"

  detect_candidate_homes
  local candidates=("${DETECTED_CANDIDATES[@]}")
  [[ ${#candidates[@]} -gt 0 ]] || { sync_prompt_no_dir_message "$lang" >&2; return 1; }

  if [[ ! -t 0 ]]; then
    render_sync_prompt_output non-tty "$lang" "${candidates[@]}" >&2
    return 1
  fi
  render_sync_prompt_output tty "$lang" "${candidates[@]}" >&2

  while true; do
    read -r choice
    case "$choice" in
      '' ) continue ;;
      *[!0-9]* )
        [[ "$choice" =~ ^/ ]] || { sync_prompt_abs_message "$lang"; continue; }
        [[ -d "$choice" ]] || { sync_prompt_missing_message "$lang"; continue; }
        printf '%s\n' "$choice"
        return 0
        ;;
      *)
        if (( choice >= 1 && choice <= ${#candidates[@]} )); then
          printf '%s\n' "${candidates[choice-1]}"
          return 0
        fi
        sync_prompt_range_message "$lang"
        ;;
    esac
  done
}

choose_target_home() {
  if [[ -n "${TARGET_HOME_OVERRIDE:-}" ]]; then
    validate_explicit_target_home "$TARGET_HOME_OVERRIDE" || return 1
    printf '%s\n' "$TARGET_HOME_OVERRIDE" > "$SYNC_CACHE_FILE"
    runtime_log_info sync "using explicit sync target" "target_home=$TARGET_HOME_OVERRIDE" "cache_file=$SYNC_CACHE_FILE"
    printf '%s\n' "$TARGET_HOME_OVERRIDE"
    return 0
  fi

  local target
  if target="$(load_cached_target)"; then
    [[ -d "$target" ]] && printf '%s\n' "$target" && return 0
  fi
  target="$(prompt_user_for_target)" || return 1
  printf '%s\n' "$target" > "$SYNC_CACHE_FILE"
  runtime_log_info sync "selected sync target interactively" "target_home=$target" "cache_file=$SYNC_CACHE_FILE"
  printf '%s\n' "$target"
}

LIST_TARGETS=0
TARGET_HOME_OVERRIDE=""
start_ms="$(runtime_log_now_ms)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-targets)
      LIST_TARGETS=1
      shift
      ;;
    --target-home)
      [[ $# -ge 2 ]] || { printf 'Missing value for --target-home.\n' >&2; usage >&2; exit 1; }
      TARGET_HOME_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if (( LIST_TARGETS )) && [[ -n "$TARGET_HOME_OVERRIDE" ]]; then
  printf 'Use either --list-targets or --target-home, not both.\n' >&2
  exit 1
fi

if (( LIST_TARGETS )); then
  list_candidate_homes
  exit 0
fi

REPO_ROOT="$(resolve_repo_root)"
SOURCE_FILE="$REPO_ROOT/wezterm.lua"
RUNTIME_SOURCE_DIR="$REPO_ROOT/wezterm-x"
NATIVE_SOURCE_DIR="$REPO_ROOT/native"
SYNC_CACHE_FILE="$REPO_ROOT/.sync-target"
MAIN_REPO_ROOT="$(resolve_main_repo_root "$REPO_ROOT")"

TARGET_HOME="$(choose_target_home)"
TARGET_FILE="$TARGET_HOME/.wezterm.lua"
TARGET_RUNTIME_STATE_DIR="$(target_runtime_state_dir "$TARGET_HOME")"
TARGET_RUNTIME_DIR="$TARGET_HOME/.wezterm-x"
TARGET_NATIVE_DIR="$TARGET_HOME/.wezterm-native"
TEMP_RUNTIME_DIR="$TARGET_HOME/.wezterm-x.tmp.$$"
TEMP_NATIVE_DIR="$TARGET_HOME/.wezterm-native.tmp.$$"
TEMP_BOOTSTRAP_FILE="$TARGET_RUNTIME_STATE_DIR/.wezterm.lua.tmp.$$"
RUNTIME_NATIVE_FLOW_PID=""
BOOTSTRAP_FLOW_PID=""

runtime_log_info sync "sync-runtime invoked" \
  "repo_root=$REPO_ROOT" \
  "main_repo_root=$MAIN_REPO_ROOT" \
  "target_home=$TARGET_HOME" \
  "target_file=$TARGET_FILE" \
  "target_runtime_dir=$TARGET_RUNTIME_DIR"
sync_trace "step=init repo_root=$REPO_ROOT main_repo_root=$MAIN_REPO_ROOT"
sync_trace "step=target target_home=$TARGET_HOME target_file=$TARGET_FILE"
sync_trace "step=target target_runtime_dir=$TARGET_RUNTIME_DIR target_native_dir=$TARGET_NATIVE_DIR"

run_runtime_native_flow() {
  local repo_root_path=""

  sync_trace "flow=runtime-native status=starting target_runtime_dir=$TARGET_RUNTIME_DIR target_native_dir=$TARGET_NATIVE_DIR"

  mkdir -p "$TARGET_HOME"
  mkdir -p "$TARGET_RUNTIME_STATE_DIR"
  rm -rf "$TEMP_RUNTIME_DIR" "$TEMP_NATIVE_DIR"
  mkdir -p "$TEMP_RUNTIME_DIR"
  mkdir -p "$TEMP_NATIVE_DIR"
  sync_trace "step=prepare temp_runtime_dir=$TEMP_RUNTIME_DIR temp_native_dir=$TEMP_NATIVE_DIR"

  # Regenerate the tmux chord bindings from the manifest (+ overrides) so
  # the generated conf is fresh before we copy the runtime tree into place.
  # The file is gitignored but must exist for tmux.conf's `source-file -q`.
  if [[ -x "$REPO_ROOT/scripts/runtime/render-tmux-bindings.sh" ]]; then
    "$REPO_ROOT/scripts/runtime/render-tmux-bindings.sh"
    sync_trace "step=render-tmux-bindings status=completed"
  fi

  # Build the static Go picker binary used by tmux-attention-menu.sh
  # (and friends). Same gitignored-artifact pattern as the chord bindings:
  # rebuild every sync so source changes pick up; skip silently when `go`
  # is missing so machines without the toolchain still complete the sync
  # (the bash fallback in tmux-attention-menu.sh handles the absence).
  if [[ -x "$REPO_ROOT/scripts/runtime/picker/build.sh" ]]; then
    if "$REPO_ROOT/scripts/runtime/picker/build.sh"; then
      sync_trace "step=build-picker status=completed"
    else
      sync_trace "step=build-picker status=failed"
    fi
  fi

  cp -R "$RUNTIME_SOURCE_DIR"/. "$TEMP_RUNTIME_DIR"/
  if [[ -d "$NATIVE_SOURCE_DIR" ]]; then
    cp -R "$NATIVE_SOURCE_DIR"/. "$TEMP_NATIVE_DIR"/
  fi
  sync_trace "step=copy-source status=completed runtime_source=$RUNTIME_SOURCE_DIR native_source=$NATIVE_SOURCE_DIR"

  repo_root_path="${WEZTERM_REPO_ROOT:-}"
  if [[ -z "$repo_root_path" ]]; then
    repo_root_path="$(cd "$REPO_ROOT" && pwd -P)"
  fi
  printf '%s\n' "$repo_root_path" > "$TEMP_RUNTIME_DIR/repo-root.txt"
  printf '%s\n' "$MAIN_REPO_ROOT" > "$TEMP_RUNTIME_DIR/repo-main-root.txt"
  write_agent_tools_file "$TEMP_RUNTIME_DIR" "$repo_root_path"
  sync_trace "step=write-metadata repo_root_path=$repo_root_path repo_main_root=$MAIN_REPO_ROOT"

  rm -rf "$TARGET_RUNTIME_DIR" "$TARGET_NATIVE_DIR"
  mv "$TEMP_RUNTIME_DIR" "$TARGET_RUNTIME_DIR"
  mv "$TEMP_NATIVE_DIR" "$TARGET_NATIVE_DIR"
  sync_trace "step=publish-runtime status=completed target_runtime_dir=$TARGET_RUNTIME_DIR target_native_dir=$TARGET_NATIVE_DIR"

  install_windows_helper_manager "$TARGET_RUNTIME_DIR"
  ensure_windows_helper_running "$TARGET_RUNTIME_DIR"
  sync_trace "flow=runtime-native status=completed target_runtime_dir=$TARGET_RUNTIME_DIR target_native_dir=$TARGET_NATIVE_DIR"
}

run_bootstrap_prepare_flow() {
  sync_trace "flow=wezterm-config status=starting target_file=$TARGET_FILE temp_file=$TEMP_BOOTSTRAP_FILE"
  mkdir -p "$TARGET_HOME"
  mkdir -p "$TARGET_RUNTIME_STATE_DIR"
  cp "$SOURCE_FILE" "$TEMP_BOOTSTRAP_FILE"
  sync_trace "step=prepare-bootstrap status=completed temp_file=$TEMP_BOOTSTRAP_FILE"
  sync_trace "flow=wezterm-config status=prepared target_file=$TARGET_FILE temp_file=$TEMP_BOOTSTRAP_FILE"
}

finalize_bootstrap_refresh() {
  [[ -f "$TEMP_BOOTSTRAP_FILE" ]] || {
    printf 'Prepared bootstrap file is missing: %s\n' "$TEMP_BOOTSTRAP_FILE" >&2
    return 1
  }

  copy_file_atomic "$TEMP_BOOTSTRAP_FILE" "$TARGET_FILE"
  rm -f "$TEMP_BOOTSTRAP_FILE"
  touch "$TARGET_FILE"
  sync_trace "step=refresh-bootstrap status=completed target_file=$TARGET_FILE"
}

run_runtime_native_flow &
RUNTIME_NATIVE_FLOW_PID=$!
sync_trace "flow=runtime-native status=running async=1 pid=$RUNTIME_NATIVE_FLOW_PID"

run_bootstrap_prepare_flow &
BOOTSTRAP_FLOW_PID=$!
sync_trace "flow=wezterm-config status=running async=1 pid=$BOOTSTRAP_FLOW_PID"

wait_for_flow runtime-native "$RUNTIME_NATIVE_FLOW_PID"
wait_for_flow wezterm-config "$BOOTSTRAP_FLOW_PID"
finalize_bootstrap_refresh

maybe_reload_tmux "$REPO_ROOT"

runtime_log_info sync "sync-runtime completed" \
  "repo_root=$REPO_ROOT" \
  "target_home=$TARGET_HOME" \
  "target_file=$TARGET_FILE" \
  "target_runtime_dir=$TARGET_RUNTIME_DIR" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")"
sync_trace "step=completed duration_ms=$(runtime_log_duration_ms "$start_ms")"
printf 'Synced %s -> %s\n' "$SOURCE_FILE" "$TARGET_FILE"
printf 'Synced %s -> %s\n' "$RUNTIME_SOURCE_DIR" "$TARGET_RUNTIME_DIR"
if [[ -d "$NATIVE_SOURCE_DIR" ]]; then
  printf 'Synced %s -> %s\n' "$NATIVE_SOURCE_DIR" "$TARGET_NATIVE_DIR"
fi
