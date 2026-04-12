#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_LOG_LIB="$SCRIPT_DIR/../../../../scripts/runtime/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$RUNTIME_LOG_LIB"
export WEZTERM_RUNTIME_LOG_SOURCE="worktree-task.tmux-agent"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/git.sh"

provider_result() {
  if [[ -n "${WT_RESULT_FILE:-}" ]]; then
    wt_write_kv_file "$WT_RESULT_FILE" "$@"
  fi
}

provider_require_tmux() {
  command -v tmux >/dev/null 2>&1 || return 10
}

provider_validate() {
  provider_require_tmux || return $?

  if [[ -n "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" && ! -f "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" ]]; then
    printf 'tmux provider config file does not exist: %s\n' "$WT_PROVIDER_TMUX_CONFIG_FILE_ABS" >&2
    return 20
  fi

  if ! provider_agent_has_command_config; then
    runtime_log_error provider "tmux-agent validation failed: missing agent command config"
    printf 'tmux-agent requires WT_PROVIDER_AGENT_COMMAND or a variant-specific agent command\n' >&2
    return 20
  fi

  runtime_log_info provider "tmux-agent validation completed" "provider=tmux-agent"
}

provider_context_for_path() {
  local cwd="${1:-$PWD}"
  local repo_root=""
  local common_dir=""
  local main_root=""
  local repo_label=""

  [[ -d "$cwd" ]] || return 1
  wt_git_in_repo "$cwd" || return 1

  repo_root="$(wt_git_repo_root "$cwd" || true)"
  common_dir="$(wt_git_common_dir "$cwd" || true)"
  [[ -n "$repo_root" && -n "$common_dir" ]] || return 1

  main_root="$(wt_git_main_root "$common_dir" || true)"
  if [[ -z "$main_root" || ! -d "$main_root" ]]; then
    main_root="$repo_root"
  fi
  repo_label="$(wt_git_repo_label "$repo_root")"

  printf '%s\t%s\t%s\t%s\n' "$repo_root" "$common_dir" "$main_root" "$repo_label"
}

provider_window_context() {
  local window_target="${1:?missing window target}"
  local expected_common_dir="${2:-}"
  local pane_path=""
  local pane_context=""
  local pane_root=""
  local pane_common_dir=""
  local pane_main_root=""
  local pane_repo_label=""
  local resolved_root=""
  local resolved_common_dir=""
  local resolved_main_root=""
  local resolved_repo_label=""

  while IFS= read -r pane_path; do
    [[ -n "$pane_path" && -d "$pane_path" ]] || continue

    pane_context="$(provider_context_for_path "$pane_path" || true)"
    [[ -n "$pane_context" ]] || continue

    IFS=$'\t' read -r pane_root pane_common_dir pane_main_root pane_repo_label <<< "$pane_context"
    [[ -n "$pane_root" && -n "$pane_common_dir" ]] || continue

    if [[ -n "$expected_common_dir" && "$pane_common_dir" != "$expected_common_dir" ]]; then
      continue
    fi

    if [[ -z "$resolved_root" ]]; then
      resolved_root="$pane_root"
      resolved_common_dir="$pane_common_dir"
      resolved_main_root="$pane_main_root"
      resolved_repo_label="$pane_repo_label"
      continue
    fi

    if [[ "$pane_root" != "$resolved_root" || "$pane_common_dir" != "$resolved_common_dir" ]]; then
      return 1
    fi
  done < <(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null || true)

  [[ -n "$resolved_root" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "$resolved_root" "$resolved_common_dir" "$resolved_main_root" "$resolved_repo_label"
}

provider_context_for_context() {
  local current_window_id="${1:-}"
  local cwd="${2:-$PWD}"
  local context=""

  if [[ -n "$cwd" && -d "$cwd" ]]; then
    context="$(provider_context_for_path "$cwd" || true)"
    if [[ -n "$context" ]]; then
      printf '%s\n' "$context"
      return 0
    fi
  fi

  if [[ -n "$current_window_id" ]]; then
    context="$(provider_window_context "$current_window_id" || true)"
    if [[ -n "$context" ]]; then
      printf '%s\n' "$context"
      return 0
    fi
  fi

  return 1
}

provider_session_name_for_repo_family() {
  local workspace="${1:?missing workspace}"
  local repo_label="${2:?missing repo label}"
  local repo_common_dir="${3:?missing repo common dir}"

  printf 'worktree_task_%s_%s_%s\n' \
    "$(wt_sanitize_name "$workspace")" \
    "$(wt_sanitize_name "$repo_label")" \
    "$(wt_hash "$repo_common_dir")"
}

provider_session_common_dir() {
  local session_name="${1:?missing session name}"
  local window_id=""
  local window_context=""
  local window_common_dir=""
  local resolved_common_dir=""

  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    window_context="$(provider_window_context "$window_id" || true)"
    [[ -n "$window_context" ]] || continue

    IFS=$'\t' read -r _ window_common_dir _ _ <<< "$window_context"
    [[ -n "$window_common_dir" ]] || continue

    if [[ -z "$resolved_common_dir" ]]; then
      resolved_common_dir="$window_common_dir"
      continue
    fi

    if [[ "$window_common_dir" != "$resolved_common_dir" ]]; then
      return 20
    fi
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)

  printf '%s\n' "$resolved_common_dir"
}

provider_parse_command_spec() {
  local spec="${1:-}"
  local __result_var="${2:?missing result var}"

  [[ -n "$spec" ]] || return 1

  # Trusted local config may use shell quoting for arguments.
  eval "$__result_var=($spec)"
  eval "[[ \${#$__result_var[@]} -gt 0 ]]"
}

provider_command_name_from_spec() {
  local spec="${1:-}"
  local parts=()
  local command_name=""

  provider_parse_command_spec "$spec" parts || return 1
  command_name="${parts[0]}"
  command_name="${command_name##*/}"
  [[ -n "$command_name" ]] || return 1
  printf '%s\n' "$command_name"
}

provider_agent_has_command_config() {
  [[ -n "${WT_PROVIDER_AGENT_COMMAND:-}" || -n "${WT_PROVIDER_AGENT_COMMAND_LIGHT:-}" || -n "${WT_PROVIDER_AGENT_COMMAND_DARK:-}" ]]
}

provider_agent_command_spec_for_variant() {
  local variant="${1:?missing variant}"
  local command_spec=""

  case "$variant" in
    light)
      command_spec="${WT_PROVIDER_AGENT_COMMAND_LIGHT:-}"
      ;;
    dark)
      command_spec="${WT_PROVIDER_AGENT_COMMAND_DARK:-}"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ -z "$command_spec" ]]; then
    command_spec="${WT_PROVIDER_AGENT_COMMAND:-}"
  fi

  [[ -n "$command_spec" ]] || return 1
  printf '%s\n' "$command_spec"
}

provider_agent_command_names() {
  local emitted=""
  local spec=""
  local name=""

  for spec in \
    "${WT_PROVIDER_AGENT_COMMAND:-}" \
    "${WT_PROVIDER_AGENT_COMMAND_LIGHT:-}" \
    "${WT_PROVIDER_AGENT_COMMAND_DARK:-}"
  do
    [[ -n "$spec" ]] || continue
    name="$(provider_command_name_from_spec "$spec" || true)"
    [[ -n "$name" ]] || continue
    case " $emitted " in
      *" $name "*)
        ;;
      *)
        emitted="$emitted $name"
        printf '%s\n' "$name"
        ;;
    esac
  done
}

provider_command_hint() {
  local pane_start_command="${1:-}"
  local pane_current_command="${2:-}"
  local command_name=""

  case "$pane_start_command" in
    *'run-pane-command'*)
      printf '%s\n' "$pane_start_command"
      return 0
      ;;
  esac

  while IFS= read -r command_name; do
    [[ -n "$command_name" ]] || continue

    case "$pane_start_command" in
      *"$command_name"*)
        printf '%s\n' "$pane_start_command"
        return 0
        ;;
    esac

    case "$pane_current_command" in
      "$command_name")
        printf '%s\n' "$pane_current_command"
        return 0
        ;;
    esac
  done < <(provider_agent_command_names)

  return 1
}

provider_window_command_hint() {
  local window_target="${1:?missing window target}"
  local pane_index=""
  local pane_active=""
  local pane_current_command=""
  local pane_start_command=""
  local hint=""
  local fallback=""

  while IFS= read -r pane_index; do
    [[ -n "$pane_index" ]] || continue
    pane_active="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_active}' 2>/dev/null || true)"
    pane_current_command="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_current_command}' 2>/dev/null || true)"
    pane_start_command="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_start_command}' 2>/dev/null || true)"
    hint="$(provider_command_hint "$pane_start_command" "$pane_current_command" || true)"
    [[ -n "$hint" ]] || continue

    if [[ "$pane_active" == "1" ]]; then
      printf '%s\n' "$hint"
      return 0
    fi

    [[ -n "$fallback" ]] || fallback="$hint"
  done < <(tmux list-panes -t "$window_target" -F '#{pane_index}' 2>/dev/null || true)

  [[ -n "$fallback" ]] || return 1
  printf '%s\n' "$fallback"
}

provider_session_command_hint() {
  local session_name="${1:?missing session name}"
  local expected_common_dir="${2:-}"
  local preferred_window="${3:-}"
  local window_id=""
  local window_context=""
  local window_common_dir=""
  local command_hint=""

  if [[ -n "$preferred_window" ]]; then
    window_context="$(provider_window_context "$preferred_window" "$expected_common_dir" || true)"
    if [[ -n "$window_context" ]]; then
      command_hint="$(provider_window_command_hint "$preferred_window" || true)"
      if [[ -n "$command_hint" ]]; then
        printf '%s\n' "$command_hint"
        return 0
      fi
    fi
  fi

  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    window_context="$(provider_window_context "$window_id" "$expected_common_dir" || true)"
    [[ -n "$window_context" ]] || continue

    IFS=$'\t' read -r _ window_common_dir _ _ <<< "$window_context"
    if [[ -n "$expected_common_dir" && "$window_common_dir" != "$expected_common_dir" ]]; then
      continue
    fi

    command_hint="$(provider_window_command_hint "$window_id" || true)"
    if [[ -n "$command_hint" ]]; then
      printf '%s\n' "$command_hint"
      return 0
    fi
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)

  return 1
}

provider_find_window() {
  local session_name="${1:?missing session name}"
  local window_id=""
  local window_context=""
  local window_root=""

  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    window_context="$(provider_window_context "$window_id" "$WT_REPO_COMMON_DIR" || true)"
    [[ -n "$window_context" ]] || continue
    IFS=$'\t' read -r window_root _ _ _ <<< "$window_context"
    [[ "$window_root" == "$WT_WORKTREE_PATH" ]] || continue
    printf '%s\n' "$window_id"
    return 0
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)

  return 1
}

provider_ensure_window_panes() {
  local window_target="${1:?missing window target}"
  local pane_count=""
  local first_pane=""

  pane_count="$(tmux list-panes -t "$window_target" 2>/dev/null | wc -l | tr -d ' ')"
  first_pane="$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null | head -n 1)"

  [[ -n "$first_pane" ]] || return 1

  if [[ "${pane_count:-0}" -lt 2 ]]; then
    tmux split-window -h -t "$first_pane" -c "$WT_WORKTREE_PATH"
  fi

  tmux select-pane -t "$first_pane"
}

provider_variant_from_command() {
  local session_command="${1:-}"

  case "$session_command" in
    *'--variant light'*)
      printf 'light\n'
      ;;
    *'--variant dark'*)
      printf 'dark\n'
      ;;
    *)
      printf 'light\n'
      ;;
  esac
}

provider_resolve_variant() {
  local requested="${WT_RUNTIME_VARIANT:-auto}"
  local session_command="${1:-}"

  case "$requested" in
    light|dark)
      printf '%s\n' "$requested"
      return 0
      ;;
    auto)
      ;;
    *)
      printf 'invalid variant: %s\n' "$requested" >&2
      exit 20
      ;;
  esac

  case "${WT_PROVIDER_DEFAULT_VARIANT:-auto}" in
    light|dark)
      printf '%s\n' "$WT_PROVIDER_DEFAULT_VARIANT"
      return 0
      ;;
    auto|'')
      ;;
    *)
      printf 'invalid default variant: %s\n' "$WT_PROVIDER_DEFAULT_VARIANT" >&2
      exit 20
      ;;
  esac

  if [[ -n "$session_command" ]]; then
    provider_variant_from_command "$session_command"
    return 0
  fi

  printf 'light\n'
}

provider_build_pane_command() {
  local resolved_variant="${1:?missing variant}"
  local prompt_file="${2:-}"
  local command_string="env"

  if [[ -n "${WT_PROVIDER_AGENT_COMMAND:-}" ]]; then
    command_string="$command_string WT_PROVIDER_AGENT_COMMAND=$(wt_shell_quote "$WT_PROVIDER_AGENT_COMMAND")"
  fi
  if [[ -n "${WT_PROVIDER_AGENT_COMMAND_LIGHT:-}" ]]; then
    command_string="$command_string WT_PROVIDER_AGENT_COMMAND_LIGHT=$(wt_shell_quote "$WT_PROVIDER_AGENT_COMMAND_LIGHT")"
  fi
  if [[ -n "${WT_PROVIDER_AGENT_COMMAND_DARK:-}" ]]; then
    command_string="$command_string WT_PROVIDER_AGENT_COMMAND_DARK=$(wt_shell_quote "$WT_PROVIDER_AGENT_COMMAND_DARK")"
  fi
  if [[ -n "${WT_PROVIDER_AGENT_PROMPT_FLAG:-}" ]]; then
    command_string="$command_string WT_PROVIDER_AGENT_PROMPT_FLAG=$(wt_shell_quote "$WT_PROVIDER_AGENT_PROMPT_FLAG")"
  fi
  if [[ -n "${WT_PROVIDER_LOGIN_SHELL:-}" ]]; then
    command_string="$command_string WT_PROVIDER_LOGIN_SHELL=$(wt_shell_quote "$WT_PROVIDER_LOGIN_SHELL")"
  fi
  command_string="$command_string bash $(wt_shell_quote "$SCRIPT_DIR/tmux-agent.sh") run-pane-command --variant $(wt_shell_quote "$resolved_variant")"

  if [[ -n "$prompt_file" ]]; then
    command_string="$command_string --prompt-file $(wt_shell_quote "$prompt_file")"
  fi

  printf '%s\n' "$command_string"
}

provider_apply_tmux_config() {
  if [[ -n "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" && -f "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" ]]; then
    local runtime_root=""
    runtime_root="${WEZTERM_CONFIG_REPO_ROOT:-}"
    if [[ -z "$runtime_root" ]]; then
      runtime_root="$(cd "$(dirname "$WT_PROVIDER_TMUX_CONFIG_FILE_ABS")" && pwd -P)"
    fi
    tmux set-option -g @wezterm_runtime_root "$runtime_root"
    tmux source-file "$WT_PROVIDER_TMUX_CONFIG_FILE_ABS"
  fi
}

provider_launch() {
  local current_session_name=""
  local current_window_id=""
  local current_path=""
  local current_context=""
  local current_common_dir=""
  local session_name=""
  local existing_common_dir=""
  local command_hint=""
  local resolved_variant=""
  local window_id=""
  local worktree_label=""
  local custom_window_command=""
  local start_ms=""

  start_ms="$(runtime_log_now_ms)"

  provider_require_tmux || return $?
  runtime_log_info provider "tmux-agent launch invoked" \
    "repo_label=$WT_REPO_LABEL" \
    "repo_common_dir=$WT_REPO_COMMON_DIR" \
    "worktree_path=$WT_WORKTREE_PATH" \
    "workspace=${WT_RUNTIME_WORKSPACE:-task}"

  if [[ -n "${TMUX:-}" ]]; then
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    current_window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
    current_path="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)"
    current_context="$(provider_context_for_context "$current_window_id" "$current_path" || true)"
    if [[ -n "$current_context" ]]; then
      IFS=$'\t' read -r _ current_common_dir _ _ <<< "$current_context"
    fi
  fi

  if [[ -n "${WT_PROVIDER_SESSION_NAME_OVERRIDE:-}" ]]; then
    session_name="$WT_PROVIDER_SESSION_NAME_OVERRIDE"
  elif [[ -n "$current_session_name" && "$current_common_dir" == "$WT_REPO_COMMON_DIR" ]]; then
    session_name="$current_session_name"
  elif [[ -n "$current_session_name" ]]; then
    if existing_common_dir="$(provider_session_common_dir "$current_session_name" 2>/dev/null)"; then
      if [[ "$existing_common_dir" == "$WT_REPO_COMMON_DIR" ]]; then
        session_name="$current_session_name"
      fi
    fi
  fi

  if [[ -z "$session_name" ]]; then
    session_name="$(provider_session_name_for_repo_family "${WT_RUNTIME_WORKSPACE:-task}" "$WT_REPO_LABEL" "$WT_REPO_COMMON_DIR")"
  fi

  if tmux has-session -t "$session_name" 2>/dev/null; then
    if ! existing_common_dir="$(provider_session_common_dir "$session_name")"; then
      printf 'tmux session %s mixes multiple repo families\n' "$session_name" >&2
      return 20
    fi
    if [[ -n "$existing_common_dir" && "$existing_common_dir" != "$WT_REPO_COMMON_DIR" ]]; then
      printf 'tmux session %s belongs to another repo family\n' "$session_name" >&2
      return 20
    fi

    if [[ -n "$current_window_id" && "$current_session_name" == "$session_name" ]]; then
      command_hint="$(provider_session_command_hint "$session_name" "$WT_REPO_COMMON_DIR" "$current_window_id" || true)"
    else
      command_hint="$(provider_session_command_hint "$session_name" "$WT_REPO_COMMON_DIR" || true)"
    fi
  fi

  resolved_variant="$(provider_resolve_variant "$command_hint")"
  custom_window_command="$(provider_build_pane_command "$resolved_variant" "$WT_PROMPT_FILE")"
  worktree_label="$(wt_git_worktree_label_for_root "$WT_WORKTREE_PATH" "$WT_MAIN_WORKTREE_ROOT")"

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -c "$WT_WORKTREE_PATH" "$custom_window_command")"
  else
    window_id="$(provider_find_window "$session_name" || true)"
    if [[ -z "$window_id" ]]; then
      window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$session_name" -c "$WT_WORKTREE_PATH" "$custom_window_command")"
    fi
  fi

  tmux rename-window -t "$window_id" "$worktree_label"
  provider_ensure_window_panes "$window_id"
  provider_apply_tmux_config

  provider_result \
    session_name "$session_name" \
    window_id "$window_id" \
    attached "no" \
    variant "$resolved_variant"
  runtime_log_info provider "tmux-agent launch completed" \
    "session_name=$session_name" \
    "window_id=$window_id" \
    "variant=$resolved_variant" \
    "worktree_label=$worktree_label" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
}

provider_attach() {
  local start_ms=""

  start_ms="$(runtime_log_now_ms)"
  provider_require_tmux || return $?
  [[ -n "${WT_PROVIDER_SESSION_NAME:-}" ]] || return 20
  [[ -n "${WT_PROVIDER_WINDOW_ID:-}" ]] || return 20

  runtime_log_info provider "tmux-agent attach invoked" "session_name=$WT_PROVIDER_SESSION_NAME" "window_id=$WT_PROVIDER_WINDOW_ID"

  tmux select-window -t "$WT_PROVIDER_WINDOW_ID" >/dev/null 2>&1 || true

  if [[ -n "${TMUX:-}" ]]; then
    local current_session_name=""
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    if [[ -n "$current_session_name" && "$current_session_name" != "$WT_PROVIDER_SESSION_NAME" ]]; then
      tmux switch-client -t "$WT_PROVIDER_SESSION_NAME"
    fi
    tmux select-window -t "$WT_PROVIDER_WINDOW_ID"
    provider_result attached "yes"
    runtime_log_info provider "tmux-agent attach completed" "session_name=$WT_PROVIDER_SESSION_NAME" "window_id=$WT_PROVIDER_WINDOW_ID" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
    return 0
  fi

  provider_result attached "yes"
  runtime_log_info provider "tmux-agent attach completed" "session_name=$WT_PROVIDER_SESSION_NAME" "window_id=$WT_PROVIDER_WINDOW_ID" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exec tmux attach-session -t "$WT_PROVIDER_SESSION_NAME"
}

provider_cleanup() {
  local session_name=""
  local window_id=""
  local window_context=""
  local window_root=""
  local closed_windows=0
  local start_ms=""

  start_ms="$(runtime_log_now_ms)"

  provider_require_tmux || return $?
  runtime_log_info provider "tmux-agent cleanup invoked" "worktree_path=$WT_WORKTREE_PATH" "repo_common_dir=$WT_REPO_COMMON_DIR"

  while IFS= read -r session_name; do
    [[ -n "$session_name" ]] || continue

    while IFS= read -r window_id; do
      [[ -n "$window_id" ]] || continue
      window_context="$(provider_window_context "$window_id" "$WT_REPO_COMMON_DIR" || true)"
      [[ -n "$window_context" ]] || continue
      IFS=$'\t' read -r window_root _ _ _ <<< "$window_context"
      [[ "$window_root" == "$WT_WORKTREE_PATH" ]] || continue
      tmux kill-window -t "$window_id" 2>/dev/null || true
      closed_windows=$((closed_windows + 1))
    done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  provider_result windows_closed "$closed_windows"
  runtime_log_info provider "tmux-agent cleanup completed" "worktree_path=$WT_WORKTREE_PATH" "windows_closed=$closed_windows" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
}

provider_detect_context() {
  local current_session_name=""
  local current_window_id=""
  local current_path=""
  local current_context=""
  local current_common_dir=""
  local session_common_dir=""
  local can_reuse="no"

  provider_require_tmux || return $?

  if [[ -n "${TMUX:-}" ]]; then
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    current_window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
    current_path="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || true)"
    current_context="$(provider_context_for_context "$current_window_id" "$current_path" || true)"
    if [[ -n "$current_context" ]]; then
      IFS=$'\t' read -r _ current_common_dir _ _ <<< "$current_context"
    fi

    if [[ "$current_common_dir" == "$WT_REPO_COMMON_DIR" ]]; then
      can_reuse="yes"
    elif [[ -n "$current_session_name" ]]; then
      session_common_dir="$(provider_session_common_dir "$current_session_name" 2>/dev/null || true)"
      if [[ "$session_common_dir" == "$WT_REPO_COMMON_DIR" ]]; then
        can_reuse="yes"
      fi
    fi
  fi

  provider_result \
    session_name "$current_session_name" \
    can_reuse_session "$can_reuse"
}

provider_run_pane_command() {
  local variant="light"
  local prompt_file=""
  local prompt_arg=""
  local command_spec=""
  local command=()
  local command_string=""
  local login_shell=""
  local status=0
  local start_ms=""

  start_ms="$(runtime_log_now_ms)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)
        [[ $# -ge 2 ]] || exit 20
        variant="$2"
        shift 2
        ;;
      --prompt-file)
        [[ $# -ge 2 ]] || exit 20
        prompt_file="$2"
        shift 2
        ;;
      *)
        exit 20
        ;;
    esac
  done

  if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || exit 20
    prompt_arg="$(< "$prompt_file")"
    rm -f "$prompt_file"
  fi

  case "${WT_PROVIDER_LOGIN_SHELL:-}" in
    "")
      if [[ -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
        login_shell="$SHELL"
      else
        for login_shell in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
          [[ -x "$login_shell" ]] && break
        done
      fi
      ;;
    *)
      login_shell="$WT_PROVIDER_LOGIN_SHELL"
      ;;
  esac
  [[ -n "$login_shell" ]] || login_shell="/bin/sh"

  command_spec="$(provider_agent_command_spec_for_variant "$variant" || true)"
  [[ -n "$command_spec" ]] || exit 20
  provider_parse_command_spec "$command_spec" command || exit 20
  runtime_log_info provider "tmux-agent pane command starting" \
    "variant=$variant" \
    "command_name=${command[0]:-unknown}" \
    "has_prompt_file=$([[ -n "$prompt_arg" ]] && printf yes || printf no)"

  if [[ -n "$prompt_arg" ]]; then
    if [[ -n "${WT_PROVIDER_AGENT_PROMPT_FLAG:-}" ]]; then
      command+=("$WT_PROVIDER_AGENT_PROMPT_FLAG" "$prompt_arg")
    else
      command+=("$prompt_arg")
    fi
  fi

  printf -v command_string '%q ' "${command[@]}"
  command_string="${command_string% }"

  if ! "$login_shell" -ilc "$command_string"; then
    status=$?
    runtime_log_error provider "tmux-agent pane command failed" "variant=$variant" "command_name=${command[0]:-unknown}" "duration_ms=$(runtime_log_duration_ms "$start_ms")" "exit_code=$status"
    printf 'tmux-agent pane command exited with status %s\n' "$status" >&2
  else
    runtime_log_info provider "tmux-agent pane command completed" "variant=$variant" "command_name=${command[0]:-unknown}" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  fi

  exec "$login_shell" -il
}

verb="${1:-}"
shift || true

case "$verb" in
  validate)
    provider_validate
    ;;
  detect-context)
    provider_detect_context
    ;;
  launch)
    provider_launch
    ;;
  attach)
    provider_attach
    ;;
  cleanup)
    provider_cleanup
    ;;
  run-pane-command)
    provider_run_pane_command "$@"
    ;;
  *)
    printf 'unsupported provider verb: %s\n' "$verb" >&2
    exit 20
    ;;
esac
