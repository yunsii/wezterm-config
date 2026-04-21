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
  COMMAND_PANEL_ACCELERATORS=()
  COMMAND_PANEL_DESCRIPTIONS=()
  COMMAND_PANEL_HOTKEYS=()
  COMMAND_PANEL_RUNTIME_MODES=()
  COMMAND_PANEL_BACKGROUNDS=()
  COMMAND_PANEL_CONFIRM_MESSAGES=()
  COMMAND_PANEL_SUCCESS_MESSAGES=()
  COMMAND_PANEL_FAILURE_MESSAGES=()
  COMMAND_PANEL_COMMANDS=()
}

command_panel_register_item() {
  local id="" label="" accelerator="" description="" background=0
  local confirm_message="" success_message="" failure_message=""
  local -a runtime_modes=()
  local -a hotkeys=()
  local hotkeys_joined=""
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
      --accelerator)
        accelerator="${2:?missing value for --accelerator}"
        shift 2
        ;;
      --description)
        description="${2:?missing value for --description}"
        shift 2
        ;;
      --hotkey)
        hotkeys+=("${2:?missing value for --hotkey}")
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

  if (( ${#hotkeys[@]} > 0 )); then
    hotkeys_joined="$(IFS=','; printf '%s' "${hotkeys[*]}")"
  fi

  COMMAND_PANEL_IDS+=("$id")
  COMMAND_PANEL_LABELS+=("$label")
  COMMAND_PANEL_ACCELERATORS+=("${accelerator,,}")
  COMMAND_PANEL_DESCRIPTIONS+=("$description")
  COMMAND_PANEL_HOTKEYS+=("$hotkeys_joined")
  COMMAND_PANEL_RUNTIME_MODES+=("$(command_panel_join_by_comma "${runtime_modes[@]}")")
  COMMAND_PANEL_BACKGROUNDS+=("$background")
  COMMAND_PANEL_CONFIRM_MESSAGES+=("$confirm_message")
  COMMAND_PANEL_SUCCESS_MESSAGES+=("$success_message")
  COMMAND_PANEL_FAILURE_MESSAGES+=("$failure_message")
  COMMAND_PANEL_COMMANDS+=("$command_text")
}

command_panel_manifest_path() {
  local repo_root
  repo_root="$(command_panel_repo_root)"
  printf '%s\n' "$repo_root/wezterm-x/commands/manifest.json"
}

command_panel_register_manifest_items() {
  local manifest_path="${1:-$(command_panel_manifest_path)}"
  local repo_root="${2:-$(command_panel_repo_root)}"
  local id label description context accelerator display_only hotkey_display
  local confirm success failure hotkey_keys_joined palette_command_sh
  local first_hotkey
  local -a command_argv=()
  local -a hotkey_keys=()
  local -a hotkey_args=()
  local -a register_args=()
  local key key_index

  if [[ ! -f "$manifest_path" ]]; then
    runtime_log_error command_panel "command panel manifest missing" "manifest_path=$manifest_path"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    runtime_log_error command_panel "jq is required to load command panel manifest" "manifest_path=$manifest_path"
    return 1
  fi

  # Flatten every palette-visible entry into one row so the whole manifest
  # resolves in a single jq invocation (~168 → 1 process). Fields are joined
  # with ASCII Unit Separator (\x1f) instead of a tab because bash `read` would
  # otherwise collapse consecutive empty fields whenever IFS only contains
  # whitespace characters — which shifted every field past the first empty
  # `confirm_message` by one slot.
  local jq_filter='
    [.[] | select(has("palette"))]
    | sort_by(.palette.display_only // false)
    | .[]
    | [
        .id,
        .label,
        (.description // ""),
        (.context // "any"),
        (.palette.display_only // false | tostring),
        (.hotkey_display // ""),
        (.palette.accelerator // ""),
        (.palette.confirm_message // ""),
        (.palette.success_message // ""),
        (.palette.failure_message // ""),
        ([.hotkeys[]?.keys] | join(",")),
        (.palette.command // [] | @sh)
      ]
    | join("\u001f")
  '

  while IFS=$'\x1f' read -r id label description context display_only hotkey_display accelerator confirm success failure hotkey_keys_joined palette_command_sh; do
    [[ -n "$id" ]] || continue

    if [[ -n "$hotkey_display" ]]; then
      hotkey_keys=("$hotkey_display")
    elif [[ -n "$hotkey_keys_joined" ]]; then
      IFS=',' read -ra hotkey_keys <<<"$hotkey_keys_joined"
    else
      hotkey_keys=()
    fi

    command_argv=()
    if [[ "$display_only" == "true" ]]; then
      if (( ${#hotkey_keys[@]} == 0 )); then
        runtime_log_warn command_panel "manifest display-only entry has no hotkey" "id=$id"
        continue
      fi
      first_hotkey="${hotkey_keys[0]}"
      command_argv=(tmux display-message -d 2000 "Press ${first_hotkey} to trigger this command.")
    else
      if [[ -z "$palette_command_sh" ]]; then
        runtime_log_warn command_panel "manifest palette entry missing command" "id=$id"
        continue
      fi
      # palette.command was emitted by jq's `@sh` as a space-separated list of
      # single-quoted tokens; eval resolves it back into a bash array without
      # invoking an extra jq process per entry.
      eval "command_argv=( $palette_command_sh )"
      for key_index in "${!command_argv[@]}"; do
        command_argv[$key_index]="${command_argv[$key_index]//\{repo_root\}/$repo_root}"
      done
    fi

    hotkey_args=()
    for key in "${hotkey_keys[@]}"; do
      [[ -n "$key" ]] || continue
      hotkey_args+=(--hotkey "$key")
    done

    register_args=(--id "$id" --label "$label")
    [[ -n "$description" ]] && register_args+=(--description "$description")
    [[ -n "$accelerator" ]] && register_args+=(--accelerator "$accelerator")
    [[ -n "$confirm" ]] && register_args+=(--confirm-message "$confirm")
    [[ -n "$success" ]] && register_args+=(--success-message "$success")
    [[ -n "$failure" ]] && register_args+=(--failure-message "$failure")
    [[ "$context" == "hybrid-wsl" ]] && register_args+=(--runtime-mode hybrid-wsl)
    register_args+=("${hotkey_args[@]}")

    command_panel_register_item "${register_args[@]}" -- "${command_argv[@]}"
  done < <(jq -r "$jq_filter" "$manifest_path")
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
  command_panel_register_manifest_items || return 1
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
