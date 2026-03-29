#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_PROMPT_LIB="$SCRIPT_DIR/sync-prompt-lib.sh"

# Shared with the prompt test script so output regressions are easy to verify.
source "$SYNC_PROMPT_LIB"

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

resolve_repo_root() {
  local repo_root="${WEZTERM_CONFIG_REPO:-$PWD}"
  [[ -d "$repo_root" ]] || { printf 'Repository root does not exist: %s\n' "$repo_root" >&2; return 1; }
  repo_root="$(cd "$repo_root" && pwd -P)"
  [[ -f "$repo_root/wezterm.lua" ]] || { printf 'Expected %s/wezterm.lua. Run from the repo root or set WEZTERM_CONFIG_REPO.\n' "$repo_root" >&2; return 1; }
  [[ -d "$repo_root/wezterm-x" ]] || { printf 'Expected %s/wezterm-x. Run from the repo root or set WEZTERM_CONFIG_REPO.\n' "$repo_root" >&2; return 1; }
  printf '%s\n' "$repo_root"
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
    printf '%s\n' "$WEZTERM_SYNC_TARGET"
    return 0
  fi
  if [[ -f "$SYNC_CACHE_FILE" ]]; then
    local cached
    cached="$(< "$SYNC_CACHE_FILE")"
    [[ -n "$cached" ]] && printf '%s\n' "$cached" && return 0
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
    printf '%s\n' "$TARGET_HOME_OVERRIDE"
    return 0
  fi

  local target
  if target="$(load_cached_target)"; then
    [[ -d "$target" ]] && printf '%s\n' "$target" && return 0
  fi
  target="$(prompt_user_for_target)" || return 1
  printf '%s\n' "$target" > "$SYNC_CACHE_FILE"
  printf '%s\n' "$target"
}

LIST_TARGETS=0
TARGET_HOME_OVERRIDE=""

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
SYNC_CACHE_FILE="$REPO_ROOT/.sync-target"

TARGET_HOME="$(choose_target_home)"
TARGET_FILE="$TARGET_HOME/.wezterm.lua"
TARGET_RUNTIME_DIR="$TARGET_HOME/.wezterm-x"

mkdir -p "$TARGET_HOME"
cp "$SOURCE_FILE" "$TARGET_FILE"

if [[ -d "$TARGET_HOME/.wezterm-runtime" ]]; then
  rm -rf "$TARGET_HOME/.wezterm-runtime"
fi

rm -rf "$TARGET_RUNTIME_DIR"
mkdir -p "$TARGET_RUNTIME_DIR"
cp -R "$RUNTIME_SOURCE_DIR"/. "$TARGET_RUNTIME_DIR"/

repo_root_path="${WEZTERM_REPO_ROOT:-}"
if [[ -z "$repo_root_path" ]]; then
  repo_root_path="$(cd "$REPO_ROOT" && pwd -P)"
fi
printf '%s\n' "$repo_root_path" > "$TARGET_RUNTIME_DIR/repo-root.txt"

printf 'Synced %s -> %s\n' "$SOURCE_FILE" "$TARGET_FILE"
printf 'Synced %s -> %s\n' "$RUNTIME_SOURCE_DIR" "$TARGET_RUNTIME_DIR"
