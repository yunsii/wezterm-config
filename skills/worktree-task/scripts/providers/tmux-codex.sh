#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
}

provider_session_option() {
  local session_name="${1:?missing session name}"
  local option_name="${2:?missing option name}"
  tmux show-options -qv -t "$session_name" "$option_name" 2>/dev/null || true
}

provider_window_option() {
  local window_target="${1:?missing window target}"
  local option_name="${2:?missing option name}"
  tmux show-options -qv -w -t "$window_target" "$option_name" 2>/dev/null || true
}

provider_session_common_dir() {
  local session_name="${1:?missing session name}"
  local value=""

  value="$(provider_session_option "$session_name" @worktree_task_repo_common_dir)"
  printf '%s\n' "$value"
}

provider_session_primary_command() {
  local session_name="${1:?missing session name}"
  local value=""

  value="$(provider_session_option "$session_name" @worktree_task_primary_command)"
  printf '%s\n' "$value"
}

provider_window_root() {
  local window_target="${1:?missing window target}"
  local value=""

  value="$(provider_window_option "$window_target" @worktree_task_root)"
  printf '%s\n' "$value"
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

provider_write_session_metadata() {
  local session_name="${1:?missing session name}"
  local primary_command="${2:-}"

  tmux set-option -q -t "$session_name" @worktree_task_repo_common_dir "$WT_REPO_COMMON_DIR"
  tmux set-option -q -t "$session_name" @worktree_task_repo_label "$WT_REPO_LABEL"
  tmux set-option -q -t "$session_name" @worktree_task_main_root "$WT_MAIN_WORKTREE_ROOT"
  tmux set-option -q -t "$session_name" @worktree_task_primary_command "$primary_command"
  tmux set-option -q -t "$session_name" @worktree_task_provider "tmux-codex"
}

provider_write_window_metadata() {
  local window_target="${1:?missing window target}"
  local worktree_label="${2:?missing worktree label}"

  tmux set-option -q -w -t "$window_target" @worktree_task_root "$WT_WORKTREE_PATH"
  tmux set-option -q -w -t "$window_target" @worktree_task_label "$worktree_label"
}

provider_find_window() {
  local session_name="${1:?missing session name}"
  local window_id=""
  local window_root=""

  while IFS=$'\t' read -r window_id window_root; do
    [[ "$window_root" == "$WT_WORKTREE_PATH" ]] || continue
    printf '%s\n' "$window_id"
    return 0
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}	#{@worktree_task_root}' 2>/dev/null || true)

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
    *'--variant light'*|*'tui.theme="github"'*)
      printf 'light\n'
      ;;
    *'--variant dark'*|*'codex'*)
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

  command_string="$command_string WT_PROVIDER_CODEX_BOOTSTRAP=$(wt_shell_quote "${WT_PROVIDER_CODEX_BOOTSTRAP:-nvm}")"
  if [[ -n "${WT_PROVIDER_LOGIN_SHELL:-}" ]]; then
    command_string="$command_string WT_PROVIDER_LOGIN_SHELL=$(wt_shell_quote "$WT_PROVIDER_LOGIN_SHELL")"
  fi
  command_string="$command_string bash $(wt_shell_quote "$SCRIPT_DIR/tmux-codex.sh") run-pane-command --variant $(wt_shell_quote "$resolved_variant")"

  if [[ -n "$prompt_file" ]]; then
    command_string="$command_string --prompt-file $(wt_shell_quote "$prompt_file")"
  fi

  printf '%s\n' "$command_string"
}

provider_apply_tmux_config() {
  if [[ -n "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" && -f "${WT_PROVIDER_TMUX_CONFIG_FILE_ABS:-}" ]]; then
    tmux set-option -g @wezterm_runtime_root "$WT_MAIN_WORKTREE_ROOT"
    tmux source-file "$WT_PROVIDER_TMUX_CONFIG_FILE_ABS"
  fi
}

provider_launch() {
  local current_session_name=""
  local session_name=""
  local existing_common_dir=""
  local session_primary_command=""
  local resolved_variant=""
  local window_id=""
  local worktree_label=""
  local custom_window_command=""

  provider_require_tmux || return $?

  if [[ -n "${TMUX:-}" ]]; then
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  fi

  if [[ -n "${WT_PROVIDER_SESSION_NAME_OVERRIDE:-}" ]]; then
    session_name="$WT_PROVIDER_SESSION_NAME_OVERRIDE"
  elif [[ -n "$current_session_name" && "$(provider_session_common_dir "$current_session_name")" == "$WT_REPO_COMMON_DIR" ]]; then
    session_name="$current_session_name"
  else
    session_name="$(provider_session_name_for_repo_family "${WT_RUNTIME_WORKSPACE:-task}" "$WT_REPO_LABEL" "$WT_REPO_COMMON_DIR")"
  fi

  if tmux has-session -t "$session_name" 2>/dev/null; then
    existing_common_dir="$(provider_session_common_dir "$session_name")"
    if [[ -n "$existing_common_dir" && "$existing_common_dir" != "$WT_REPO_COMMON_DIR" ]]; then
      printf 'tmux session %s belongs to another repo family\n' "$session_name" >&2
      return 20
    fi
    session_primary_command="$(provider_session_primary_command "$session_name")"
  fi

  resolved_variant="$(provider_resolve_variant "$session_primary_command")"
  custom_window_command="$(provider_build_pane_command "$resolved_variant" "$WT_PROMPT_FILE")"
  if [[ -z "$session_primary_command" ]]; then
    session_primary_command="$(provider_build_pane_command "$resolved_variant")"
  fi

  worktree_label="$(wt_git_worktree_label_for_root "$WT_WORKTREE_PATH" "$WT_MAIN_WORKTREE_ROOT")"

  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -c "$WT_WORKTREE_PATH" "$custom_window_command")"
  else
    window_id="$(provider_find_window "$session_name" || true)"
    if [[ -z "$window_id" ]]; then
      window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$session_name" -c "$WT_WORKTREE_PATH" "$custom_window_command")"
    fi
  fi

  provider_write_session_metadata "$session_name" "$session_primary_command"
  provider_write_window_metadata "$window_id" "$worktree_label"
  tmux rename-window -t "$window_id" "$worktree_label"
  provider_ensure_window_panes "$window_id"
  provider_apply_tmux_config

  provider_result \
    session_name "$session_name" \
    window_id "$window_id" \
    attached "no" \
    variant "$resolved_variant"
}

provider_attach() {
  provider_require_tmux || return $?
  [[ -n "${WT_PROVIDER_SESSION_NAME:-}" ]] || return 20
  [[ -n "${WT_PROVIDER_WINDOW_ID:-}" ]] || return 20

  tmux select-window -t "$WT_PROVIDER_WINDOW_ID" >/dev/null 2>&1 || true

  if [[ -n "${TMUX:-}" ]]; then
    local current_session_name=""
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    if [[ -n "$current_session_name" && "$current_session_name" != "$WT_PROVIDER_SESSION_NAME" ]]; then
      tmux switch-client -t "$WT_PROVIDER_SESSION_NAME"
    fi
    tmux select-window -t "$WT_PROVIDER_WINDOW_ID"
    provider_result attached "yes"
    return 0
  fi

  provider_result attached "yes"
  exec tmux attach-session -t "$WT_PROVIDER_SESSION_NAME"
}

provider_cleanup() {
  local session_name=""
  local window_id=""
  local window_root=""
  local closed_windows=0

  provider_require_tmux || return $?

  while IFS= read -r session_name; do
    [[ -n "$session_name" ]] || continue
    [[ "$(provider_session_common_dir "$session_name")" == "$WT_REPO_COMMON_DIR" ]] || continue

    while IFS=$'\t' read -r window_id window_root; do
      [[ -n "$window_id" ]] || continue
      [[ "$window_root" == "$WT_WORKTREE_PATH" ]] || continue
      tmux kill-window -t "${session_name}:${window_id}" 2>/dev/null || true
      closed_windows=$((closed_windows + 1))
    done < <(tmux list-windows -t "$session_name" -F '#{window_id}	#{@worktree_task_root}' 2>/dev/null || true)
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

  provider_result windows_closed "$closed_windows"
}

provider_detect_context() {
  local current_session_name=""
  local can_reuse="no"

  provider_require_tmux || return $?

  if [[ -n "${TMUX:-}" ]]; then
    current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
    if [[ -n "$current_session_name" && "$(provider_session_common_dir "$current_session_name")" == "$WT_REPO_COMMON_DIR" ]]; then
      can_reuse="yes"
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
  local command=()
  local login_shell=""
  local status=0
  local bootstrap="${WT_PROVIDER_CODEX_BOOTSTRAP:-nvm}"

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

  if [[ "$bootstrap" == "nvm" ]]; then
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
      # shellcheck disable=SC1090
      source "$NVM_DIR/nvm.sh"
    fi
  fi

  case "$variant" in
    light)
      command=(codex -c 'tui.theme="github"')
      ;;
    dark)
      command=(codex)
      ;;
    *)
      exit 20
      ;;
  esac

  if [[ -n "$prompt_arg" ]]; then
    command+=("$prompt_arg")
  fi

  if ! "${command[@]}"; then
    status=$?
    printf 'tmux-codex pane command exited with status %s\n' "$status" >&2
  fi

  exec "$login_shell" -l
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
