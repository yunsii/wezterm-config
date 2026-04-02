#!/usr/bin/env bash

command_panel_repo_root() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/../.." && pwd
}

command_panel_runtime_mode() {
  printf '%s\n' "${WEZTERM_RUNTIME_MODE:-hybrid-wsl}"
}

command_panel_shell_quote() {
  printf '%q' "${1:-}"
}

command_panel_join_by_comma() {
  local first=1
  local value

  for value in "$@"; do
    if (( first )); then
      printf '%s' "$value"
      first=0
    else
      printf ',%s' "$value"
    fi
  done
}

command_panel_reset_items() {
  COMMAND_PANEL_IDS=()
  COMMAND_PANEL_LABELS=()
  COMMAND_PANEL_DESCRIPTIONS=()
  COMMAND_PANEL_RUNTIME_MODES=()
  COMMAND_PANEL_BACKGROUNDS=()
  COMMAND_PANEL_CONFIRM_MESSAGES=()
  COMMAND_PANEL_SUCCESS_MESSAGES=()
  COMMAND_PANEL_FAILURE_MESSAGES=()
  COMMAND_PANEL_COMMANDS=()
}

command_panel_register_item() {
  local id="" label="" description="" background=0
  local confirm_message="" success_message="" failure_message=""
  local -a runtime_modes=()
  local -a command=()
  local command_text=""

  while (($# > 0)); do
    case "$1" in
      --id)
        id="${2:?missing value for --id}"
        shift 2
        ;;
      --label)
        label="${2:?missing value for --label}"
        shift 2
        ;;
      --description)
        description="${2:?missing value for --description}"
        shift 2
        ;;
      --runtime-mode)
        runtime_modes+=("${2:?missing value for --runtime-mode}")
        shift 2
        ;;
      --confirm-message)
        confirm_message="${2:?missing value for --confirm-message}"
        shift 2
        ;;
      --success-message)
        success_message="${2:?missing value for --success-message}"
        shift 2
        ;;
      --failure-message)
        failure_message="${2:?missing value for --failure-message}"
        shift 2
        ;;
      --background)
        background=1
        shift
        ;;
      --)
        shift
        command=("$@")
        break
        ;;
      *)
        printf 'command_panel_register_item: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$label" ]] || {
    printf 'command_panel_register_item: label is required\n' >&2
    return 1
  }
  [[ ${#command[@]} -gt 0 ]] || {
    printf 'command_panel_register_item: command is required\n' >&2
    return 1
  }

  if [[ -z "$id" ]]; then
    id="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
    id="${id#-}"
    id="${id%-}"
  fi

  printf -v command_text '%q ' "${command[@]}"
  command_text="${command_text% }"

  COMMAND_PANEL_IDS+=("$id")
  COMMAND_PANEL_LABELS+=("$label")
  COMMAND_PANEL_DESCRIPTIONS+=("$description")
  COMMAND_PANEL_RUNTIME_MODES+=("$(command_panel_join_by_comma "${runtime_modes[@]}")")
  COMMAND_PANEL_BACKGROUNDS+=("$background")
  COMMAND_PANEL_CONFIRM_MESSAGES+=("$confirm_message")
  COMMAND_PANEL_SUCCESS_MESSAGES+=("$success_message")
  COMMAND_PANEL_FAILURE_MESSAGES+=("$failure_message")
  COMMAND_PANEL_COMMANDS+=("$command_text")
}

command_panel_register_builtin_items() {
  command_panel_register_item \
    --id force-close-vscode-windows \
    --label 'Force close all VS Code windows' \
    --description 'Run taskkill /IM code.exe /F on the Windows host' \
    --runtime-mode hybrid-wsl \
    --confirm-message 'Force close all VS Code windows? Unsaved editor state will be lost.' \
    --success-message 'Closed all VS Code windows.' \
    --failure-message 'Failed to close VS Code windows.' \
    -- cmd.exe /c taskkill /IM code.exe /F
}

command_panel_load_local_items() {
  local repo_root local_path

  repo_root="$(command_panel_repo_root)"
  local_path="$repo_root/wezterm-x/local/command-panel.sh"
  if [[ ! -f "$local_path" ]]; then
    return 0
  fi

  if ! source "$local_path"; then
    runtime_log_error command_panel "failed to source local command panel config" "path=$local_path"
    return 1
  fi
}

command_panel_load_items() {
  command_panel_reset_items
  command_panel_register_builtin_items
  command_panel_load_local_items
}

command_panel_item_matches_runtime() {
  local index="${1:?missing item index}"
  local runtime_mode="${2:-$(command_panel_runtime_mode)}"
  local configured_modes="${COMMAND_PANEL_RUNTIME_MODES[$index]:-}"
  local mode=""

  [[ -z "$configured_modes" ]] && return 0

  IFS=',' read -r -a __command_panel_modes <<< "$configured_modes"
  for mode in "${__command_panel_modes[@]}"; do
    [[ "$mode" == "$runtime_mode" ]] && return 0
  done

  return 1
}

command_panel_visible_indexes() {
  local runtime_mode="${1:-$(command_panel_runtime_mode)}"
  local index

  for index in "${!COMMAND_PANEL_IDS[@]}"; do
    if command_panel_item_matches_runtime "$index" "$runtime_mode"; then
      printf '%s\n' "$index"
    fi
  done
}

command_panel_find_index_by_id() {
  local target_id="${1:?missing item id}"
  local runtime_mode="${2:-$(command_panel_runtime_mode)}"
  local index

  for index in "${!COMMAND_PANEL_IDS[@]}"; do
    if [[ "${COMMAND_PANEL_IDS[$index]}" == "$target_id" ]] && command_panel_item_matches_runtime "$index" "$runtime_mode"; then
      printf '%s\n' "$index"
      return 0
    fi
  done

  return 1
}

command_panel_command_for_index() {
  local index="${1:?missing item index}"
  local target_name="${2:-command_panel_command}"
  local command_text="${COMMAND_PANEL_COMMANDS[$index]:-}"
  local -n target_ref="$target_name"

  target_ref=()
  [[ -n "$command_text" ]] || return 1

  eval "target_ref=( $command_text )"
}
