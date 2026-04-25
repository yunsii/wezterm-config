#!/usr/bin/env bash

# Capture this lib's directory at SOURCE time (top-level of the file).
# Inside `runtime_log_init`, BASH_SOURCE[0] resolves unreliably across
# bash invocation contexts (interactive `source`, `bash -c`, etc.) and
# can wrongly resolve to "environment" — see commit message rationale.
__RUNTIME_LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

runtime_log_init() {
  if [[ -n "${__WEZTERM_RUNTIME_LOG_INITIALIZED:-}" ]]; then
    return
  fi

  local repo_root config_file
  repo_root="${WEZTERM_REPO_ROOT:-$(cd "$__RUNTIME_LOG_LIB_DIR/../.." && pwd)}"
  config_file="$repo_root/wezterm-x/local/runtime-logging.sh"

  # Source canonical WSL path constants so the default log location
  # tracks docs/performance.md's `wezterm-runtime/{state,logs,bin}/`
  # convention without each script re-deriving it.
  # shellcheck disable=SC1091
  . "$__RUNTIME_LOG_LIB_DIR/wsl-runtime-paths-lib.sh"

  if [[ -f "$config_file" ]]; then
    # shellcheck disable=SC1090
    source "$config_file"
  fi

  : "${WEZTERM_RUNTIME_LOG_ENABLED:=1}"
  : "${WEZTERM_RUNTIME_LOG_LEVEL:=info}"
  : "${WEZTERM_RUNTIME_LOG_CATEGORIES:=}"
  : "${WEZTERM_RUNTIME_LOG_FILE:=$WSL_RUNTIME_LOG_FILE}"
  : "${WEZTERM_RUNTIME_LOG_ROTATE_BYTES:=5242880}"
  : "${WEZTERM_RUNTIME_LOG_ROTATE_COUNT:=5}"
  : "${WEZTERM_RUNTIME_LOG_SOURCE:=$(basename "${0:-runtime}")}"

  # One-time migration: the previous override wrote to a flat path
  # `${XDG_STATE_HOME}/wezterm-runtime.log` (no nested logs/ dir). Fold
  # any historical data — including content from stale-env writers that
  # are still appending to the legacy path between sync and tmux reload —
  # into the canonical location. Use rename-then-append-then-rm so a
  # concurrent writer can't double-append: once the legacy file is
  # renamed away, new opens of the original name see ENOENT and create
  # a fresh file (which we will pick up on the next init).
  local legacy_log="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime.log"
  if [[ -f "$legacy_log" ]]; then
    mkdir -p "$(dirname "$WEZTERM_RUNTIME_LOG_FILE")" 2>/dev/null
    local pending="${legacy_log}.migrating-$$"
    if mv "$legacy_log" "$pending" 2>/dev/null; then
      [[ -s "$pending" ]] && cat "$pending" >> "$WEZTERM_RUNTIME_LOG_FILE" 2>/dev/null
      rm -f "$pending" 2>/dev/null
    fi
    local i
    for i in 1 2 3 4 5; do
      [[ -f "${legacy_log}.$i" ]] || continue
      local pending_n="${legacy_log}.$i.migrating-$$"
      if mv "${legacy_log}.$i" "$pending_n" 2>/dev/null; then
        [[ -s "$pending_n" ]] && cat "$pending_n" >> "${WEZTERM_RUNTIME_LOG_FILE}.$i" 2>/dev/null
        rm -f "$pending_n" 2>/dev/null
      fi
    done
  fi

  __WEZTERM_RUNTIME_LOG_INITIALIZED=1
}

runtime_log_level_rank() {
  case "$1" in
    error) printf '1\n' ;;
    warn) printf '2\n' ;;
    info) printf '3\n' ;;
    debug) printf '4\n' ;;
    *) printf '3\n' ;;
  esac
}

runtime_log_should_emit() {
  runtime_log_init

  local level="$1"
  local category="$2"
  local requested current categories

  [[ "$WEZTERM_RUNTIME_LOG_ENABLED" == "1" ]] || return 1

  requested="$(runtime_log_level_rank "$level")"
  current="$(runtime_log_level_rank "$WEZTERM_RUNTIME_LOG_LEVEL")"
  (( requested <= current )) || return 1

  categories=",$WEZTERM_RUNTIME_LOG_CATEGORIES,"
  if [[ "$categories" != ",," && "$categories" != *",$category,"* ]]; then
    return 1
  fi

  return 0
}

runtime_log_now_ms() {
  local now

  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$now"
    return 0
  fi

  printf '%s000\n' "$(date +%s)"
}

runtime_log_duration_ms() {
  local start_ms="${1:-0}"
  local end_ms

  end_ms="$(runtime_log_now_ms)"
  if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
    printf '%s\n' "$((end_ms - start_ms))"
    return 0
  fi

  printf '0\n'
}

runtime_log_generate_trace_id() {
  printf '%s-%s-%04d\n' "$(date +%Y%m%dT%H%M%S 2>/dev/null || date +%s)" "$$" "$((RANDOM % 10000))"
}

runtime_log_current_trace_id() {
  runtime_log_init

  if [[ -z "${WEZTERM_RUNTIME_TRACE_ID:-}" ]]; then
    WEZTERM_RUNTIME_TRACE_ID="$(runtime_log_generate_trace_id)"
    export WEZTERM_RUNTIME_TRACE_ID
  fi

  printf '%s\n' "$WEZTERM_RUNTIME_TRACE_ID"
}

runtime_log_escape_value() {
  local value="${1-}"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

runtime_log_file_size() {
  local path="${1:?missing path}"

  if [[ ! -f "$path" ]]; then
    printf '0\n'
    return 0
  fi

  if stat -c %s "$path" >/dev/null 2>&1; then
    stat -c %s "$path"
    return 0
  fi

  stat -f %z "$path"
}

runtime_log_rotate_if_needed() {
  runtime_log_init

  local file="${WEZTERM_RUNTIME_LOG_FILE:?missing log file}"
  local max_bytes="${WEZTERM_RUNTIME_LOG_ROTATE_BYTES:-0}"
  local max_files="${WEZTERM_RUNTIME_LOG_ROTATE_COUNT:-0}"
  local size=0
  local index=0
  local next_index=0

  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  [[ "$max_files" =~ ^[0-9]+$ ]] || return 0
  (( max_bytes > 0 && max_files > 0 )) || return 0
  [[ -f "$file" ]] || return 0

  size="$(runtime_log_file_size "$file" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size >= max_bytes )) || return 0

  if [[ -f "$file.$max_files" ]]; then
    rm -f "$file.$max_files"
  fi

  for (( index=max_files-1; index>=1; index-=1 )); do
    if [[ -f "$file.$index" ]]; then
      next_index=$((index + 1))
      mv "$file.$index" "$file.$next_index"
    fi
  done

  mv "$file" "$file.1"
}

runtime_log_format_fields() {
  local field key value
  local -a parts=()

  for field in "$@"; do
    if [[ "$field" == *=* ]]; then
      key="${field%%=*}"
      value="${field#*=}"
    else
      key="detail"
      value="$field"
    fi

    [[ -n "$key" ]] || key="detail"
    parts+=("${key}=$(runtime_log_escape_value "$value")")
  done

  printf '%s' "${parts[*]}"
}

runtime_log_shell_join() {
  local part=""
  local rendered=""

  for part in "$@"; do
    printf -v rendered '%s%q ' "$rendered" "$part"
  done

  rendered="${rendered% }"
  printf '%s\n' "$rendered"
}

runtime_log_emit() {
  runtime_log_init

  local level="$1"
  local category="$2"
  local message="$3"
  shift 3

  runtime_log_should_emit "$level" "$category" || return 0

  mkdir -p "$(dirname "$WEZTERM_RUNTIME_LOG_FILE")"
  runtime_log_rotate_if_needed

  local timestamp line trace_id formatted_fields source_name
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  trace_id="$(runtime_log_current_trace_id)"
  source_name="${WEZTERM_RUNTIME_LOG_SOURCE:-runtime}"
  formatted_fields="$(runtime_log_format_fields "$@")"
  line="ts=$(runtime_log_escape_value "$timestamp") level=$(runtime_log_escape_value "$level") source=$(runtime_log_escape_value "$source_name") category=$(runtime_log_escape_value "$category") trace_id=$(runtime_log_escape_value "$trace_id") message=$(runtime_log_escape_value "$message")"

  if [[ -n "$formatted_fields" ]]; then
    line="$line $formatted_fields"
  fi

  printf '%s\n' "$line" >> "$WEZTERM_RUNTIME_LOG_FILE"
}

runtime_log_debug() {
  runtime_log_emit debug "$@"
}

runtime_log_info() {
  runtime_log_emit info "$@"
}

runtime_log_warn() {
  runtime_log_emit warn "$@"
}

runtime_log_error() {
  runtime_log_emit error "$@"
}
