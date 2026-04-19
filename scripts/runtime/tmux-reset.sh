#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"

subcommand="${1:-}"
if [[ -n "$subcommand" ]]; then
  shift
fi

default_session_prefix='wezterm_default_shell_'

print_usage() {
  cat <<'EOF' >&2
usage:
  tmux-reset.sh session-name --workspace NAME --cwd PATH
  tmux-reset.sh current-session --workspace NAME [--cwd PATH]
  tmux-reset.sh refresh-current-window [--session-name NAME] [--window-id ID] [--cwd PATH]
  tmux-reset.sh refresh-current-session [--session-name NAME] [--window-id ID] [--cwd PATH] [--client-tty TTY]
  tmux-reset.sh refresh-current-workspace [--session-name NAME] [--window-id ID] [--cwd PATH] [--client-tty TTY]
  tmux-reset.sh refresh-all [--session-name NAME] [--window-id ID] [--cwd PATH] [--client-tty TTY]
  tmux-reset.sh reset-managed-window --workspace NAME [--cwd PATH]
  tmux-reset.sh reset-current-window --session-name NAME --window-id ID [--cwd PATH]
  tmux-reset.sh reset-default --cwd PATH [--kill-other-default-sessions] [--kill-other-sessions]
  tmux-reset.sh resolve-default-session --cwd PATH
  tmux-reset.sh list-default-sessions
  tmux-reset.sh list-sessions
EOF
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

normalize_tmux_command() {
  local value="${1-}"
  if [[ -n "$value" && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s\n' "$value"
}

normalize_requested_cwd() {
  local cwd="${1:-}"
  if [[ -n "$cwd" && -d "$cwd" && ! "$cwd" =~ ^/mnt/[a-z]/Users/[^/]+$ ]]; then
    tmux_worktree_abs_path "$cwd"
    return 0
  fi
  printf '\n'
}

context_value_or_env() {
  local explicit_value="${1-}"
  local env_name="${2:?missing env name}"
  if [[ -n "$explicit_value" ]]; then
    printf '%s\n' "$explicit_value"
    return 0
  fi
  printf '%s\n' "${!env_name:-}"
}

resolve_session_name() {
  local workspace=""
  local cwd=""

  while (($# > 0)); do
    case "$1" in
      --workspace)
        workspace="${2:?missing value for --workspace}"
        shift 2
        ;;
      --cwd)
        cwd="${2:?missing value for --cwd}"
        shift 2
        ;;
      *)
        printf 'tmux-reset session-name: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$workspace" && "$workspace" != "default" ]] || {
    printf 'tmux-reset session-name requires a non-default workspace\n' >&2
    return 1
  }
  [[ -n "$cwd" ]] || {
    printf 'tmux-reset session-name requires --cwd\n' >&2
    return 1
  }

  cwd="$(tmux_worktree_abs_path "$cwd")"
  printf '%s\n' "$(tmux_worktree_session_name_for_path "$workspace" "$cwd")"
}

path_match_score() {
  local candidate="${1:-}"
  local target="${2:-}"

  if [[ -z "$candidate" || -z "$target" ]]; then
    printf '0\n'
    return 0
  fi

  if [[ "$candidate" == "$target" ]]; then
    printf '%s\n' "$((100000 + ${#candidate}))"
    return 0
  fi

  if [[ "$target" == "$candidate"/* ]]; then
    printf '%s\n' "$((50000 + ${#candidate}))"
    return 0
  fi

  if [[ "$candidate" == "$target"/* ]]; then
    printf '%s\n' "$((25000 + ${#target}))"
    return 0
  fi

  printf '0\n'
}

resolve_attached_workspace_session() {
  local workspace="${1:?missing workspace}"
  local prefix="wezterm_${workspace}_"
  local best_session=""
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""

  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$prefix"* ]] || continue

    if (( ${session_attached:-0} > best_attached )) \
      || (( ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-sessions -F '#{session_name}|#{session_last_attached}|#{session_attached}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

resolve_current_workspace_session() {
  local workspace=""
  local cwd=""
  local session_name=""

  while (($# > 0)); do
    case "$1" in
      --workspace)
        workspace="${2:?missing value for --workspace}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset current-session: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$workspace" && "$workspace" != "default" ]] || {
    printf 'tmux-reset current-session requires a non-default workspace\n' >&2
    return 1
  }

  if [[ -n "$cwd" && -d "$cwd" ]]; then
    session_name="$(resolve_session_name --workspace "$workspace" --cwd "$cwd" || true)"
    if [[ -n "$session_name" ]]; then
      printf '%s\n' "$session_name"
      return 0
    fi
  fi

  resolve_attached_workspace_session "$workspace"
}

resolve_default_session() {
  local cwd=""
  local best_session=""
  local best_score=-1
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""
  local pane_path=""
  local score=0

  while (($# > 0)); do
    case "$1" in
      --cwd)
        cwd="${2:?missing value for --cwd}"
        shift 2
        ;;
      *)
        printf 'tmux-reset resolve-default-session: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  [[ -n "$cwd" ]] || {
    printf 'tmux-reset resolve-default-session requires --cwd\n' >&2
    return 1
  }

  cwd="$(tmux_worktree_abs_path "$cwd")"
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached pane_path; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$default_session_prefix"* ]] || continue

    score="$(path_match_score "$pane_path" "$cwd")"
    if (( score <= 0 )); then
      continue
    fi

    if (( score > best_score )) \
      || (( score == best_score && ${session_attached:-0} > best_attached )) \
      || (( score == best_score && ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_score="$score"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-panes -a -F '#{session_name}|#{session_last_attached}|#{session_attached}|#{pane_current_path}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

resolve_attached_default_session() {
  local best_session=""
  local best_attached=-1
  local best_last_attached=-1
  local session_name=""
  local session_last_attached=""
  local session_attached=""

  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  while IFS='|' read -r session_name session_last_attached session_attached; do
    [[ -n "$session_name" ]] || continue
    [[ "$session_name" == "$default_session_prefix"* ]] || continue

    if (( ${session_attached:-0} > best_attached )) \
      || (( ${session_attached:-0} == best_attached && ${session_last_attached:-0} > best_last_attached )); then
      best_session="$session_name"
      best_attached="${session_attached:-0}"
      best_last_attached="${session_last_attached:-0}"
    fi
  done < <(
    tmux list-sessions -F '#{session_name}|#{session_last_attached}|#{session_attached}' 2>/dev/null || true
  )

  if [[ -n "$best_session" ]]; then
    printf '%s\n' "$best_session"
  fi
}

list_default_sessions() {
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | awk -v prefix="$default_session_prefix" 'index($0, prefix) == 1 { print }' \
    | unique_lines
}

list_sessions() {
  if ! tmux list-sessions >/dev/null 2>&1; then
    return 0
  fi

  tmux list-sessions -F '#{session_name}' 2>/dev/null | unique_lines
}

resolve_login_shell() {
  if [[ -n "${WEZTERM_MANAGED_SHELL:-}" && -x "${WEZTERM_MANAGED_SHELL:-}" ]]; then
    printf '%s\n' "$WEZTERM_MANAGED_SHELL"
    return 0
  fi

  if [[ -n "${SHELL:-}" && -x "${SHELL:-}" ]]; then
    printf '%s\n' "$SHELL"
    return 0
  fi

  local candidate
  for candidate in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf '/bin/sh\n'
}

build_primary_shell_command() {
  local login_shell quoted_shell
  login_shell="$(resolve_login_shell)"
  quoted_shell="$(printf '%q' "$login_shell")"
  printf '%s -il' "$quoted_shell"
}

active_window_id_for_session() {
  local session_name="${1:?missing session name}"
  tmux display-message -p -t "$session_name" '#{window_id}' 2>/dev/null || true
}

resolve_worktree_root_for_cwd() {
  local cwd="${1:-}"
  [[ -n "$cwd" && -d "$cwd" ]] || return 1

  if tmux_worktree_in_git_repo "$cwd"; then
    tmux_worktree_repo_root "$cwd"
    return 0
  fi

  tmux_worktree_abs_path "$cwd"
}

session_workspace_name() {
  local session_name="${1:?missing session name}"
  local workspace_name=""

  workspace_name="$(tmux_worktree_session_metadata "$session_name" @wezterm_workspace)"
  if [[ -n "$workspace_name" ]]; then
    printf '%s\n' "$workspace_name"
    return 0
  fi

  if [[ "$session_name" == "$default_session_prefix"* ]]; then
    printf 'default\n'
    return 0
  fi

  workspace_name="$(printf '%s' "$session_name" | sed -n 's/^wezterm_\([^_][^_]*\)_.*/\1/p')"
  if [[ -n "$workspace_name" ]]; then
    printf '%s\n' "$workspace_name"
  fi
}

session_role() {
  local session_name="${1:?missing session name}"
  local role=""

  role="$(tmux_worktree_session_metadata "$session_name" @wezterm_session_role)"
  if [[ -n "$role" ]]; then
    printf '%s\n' "$role"
    return 0
  fi

  if [[ "$session_name" == "$default_session_prefix"* ]]; then
    printf 'default\n'
  else
    printf 'managed\n'
  fi
}

window_primary_command() {
  local window_target="${1:?missing window target}"
  local pane_index=""
  local pane_active=""
  local command=""
  local current_command=""
  local preferred_command=""
  local fallback_command=""

  while IFS= read -r pane_index; do
    [[ -n "$pane_index" ]] || continue
    pane_active="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_active}' 2>/dev/null || true)"
    command="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_start_command}' 2>/dev/null || true)"
    current_command="$(tmux display-message -p -t "${window_target}.${pane_index}" '#{pane_current_command}' 2>/dev/null || true)"
    command="$(normalize_tmux_command "$command")"
    current_command="$(normalize_tmux_command "$current_command")"

    case "$command" in
      *'run-managed-command.sh'*|*'run-pane-command'*)
        printf '%s\n' "$command"
        return 0
        ;;
    esac

    if [[ -n "$command" && "$command" != *'--prompt-file '* && "$command" != *'--prompt-file='* ]]; then
      [[ -n "$fallback_command" ]] || fallback_command="$command"
      if [[ "$pane_active" == "1" ]]; then
        preferred_command="$command"
      fi
      continue
    fi

    if [[ -n "$current_command" ]] && ! tmux_worktree_is_shell_command "$current_command"; then
      [[ -n "$fallback_command" ]] || fallback_command="$current_command"
      if [[ "$pane_active" == "1" ]]; then
        preferred_command="$current_command"
      fi
    fi
  done < <(tmux list-panes -t "$window_target" -F '#{pane_index}' 2>/dev/null || true)

  if [[ -n "$preferred_command" ]]; then
    printf '%s\n' "$preferred_command"
    return 0
  fi

  if [[ -n "$fallback_command" ]]; then
    printf '%s\n' "$fallback_command"
    return 0
  fi

  build_primary_shell_command
}

window_layout_for_target() {
  local window_target="${1:?missing window target}"
  local layout=""
  local pane_count=""

  layout="$(tmux_worktree_window_metadata "$window_target" @wezterm_window_layout)"
  if [[ -n "$layout" ]]; then
    printf '%s\n' "$layout"
    return 0
  fi

  pane_count="$(tmux list-panes -t "$window_target" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${pane_count:-0}" -gt 1 ]]; then
    printf 'managed_two_pane\n'
  else
    printf 'single\n'
  fi
}

window_role_for_target() {
  local window_target="${1:?missing window target}"
  local session_name="${2:?missing session name}"
  local role=""

  role="$(tmux_worktree_window_metadata "$window_target" @wezterm_window_role)"
  if [[ -n "$role" ]]; then
    printf '%s\n' "$role"
    return 0
  fi

  if [[ "$(session_role "$session_name")" == "default" ]]; then
    printf 'shell\n'
  else
    printf 'managed_primary\n'
  fi
}

window_root_for_target() {
  local window_target="${1:?missing window target}"
  local session_name="${2:?missing session name}"
  local requested_cwd="${3:-}"
  local role=""
  local root=""

  role="$(window_role_for_target "$window_target" "$session_name")"
  root="$(tmux_worktree_window_metadata "$window_target" @wezterm_window_root)"

  if [[ -n "$requested_cwd" ]]; then
    if [[ "$role" == "managed_primary" ]]; then
      root="$(resolve_worktree_root_for_cwd "$requested_cwd" || true)"
    else
      root="$requested_cwd"
    fi
  fi

  if [[ -z "$root" && "$role" == "managed_primary" ]]; then
    root="$(tmux_worktree_current_root_for_window "$window_target" || true)"
  fi
  if [[ -z "$root" ]]; then
    root="$(tmux list-panes -t "$window_target" -F '#{pane_current_path}' 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$root" || ! -d "$root" ]]; then
    root="${HOME:-$PWD}"
  fi

  tmux_worktree_abs_path "$root"
}

window_label_for_target() {
  local window_target="${1:?missing window target}"
  local worktree_root="${2:?missing worktree root}"
  local session_name="${3:?missing session name}"
  local role=""
  local label=""
  local main_worktree_root=""

  label="$(tmux_worktree_window_metadata "$window_target" @wezterm_window_label)"
  if [[ -n "$label" ]]; then
    printf '%s\n' "$label"
    return 0
  fi

  role="$(window_role_for_target "$window_target" "$session_name")"
  if [[ "$role" == "shell" ]]; then
    label="$(basename "$worktree_root")"
    if [[ -z "$label" || "$label" == "/" ]]; then
      label="shell"
    fi
    printf '%s\n' "$label"
    return 0
  fi

  if [[ "$role" == "managed_primary" ]] && tmux_worktree_in_git_repo "$worktree_root"; then
    main_worktree_root="$(tmux_worktree_main_root "$(tmux_worktree_common_dir "$worktree_root")" || true)"
    tmux_worktree_label_for_root "$worktree_root" "$main_worktree_root"
    return 0
  fi

  label="$(tmux display-message -p -t "$window_target" '#{window_name}' 2>/dev/null || true)"
  if [[ -n "$label" ]]; then
    printf '%s\n' "$label"
    return 0
  fi

  printf '%s\n' "$(basename "$worktree_root")"
}

window_refresh_spec() {
  local session_name="${1:?missing session name}"
  local window_target="${2:?missing window target}"
  local requested_cwd="${3:-}"
  local worktree_root=""
  local window_label=""
  local primary_command=""
  local layout=""
  local role=""

  worktree_root="$(window_root_for_target "$window_target" "$session_name" "$requested_cwd")"
  window_label="$(window_label_for_target "$window_target" "$worktree_root" "$session_name")"
  role="$(window_role_for_target "$window_target" "$session_name")"
  primary_command="$(tmux_worktree_window_metadata "$window_target" @wezterm_window_primary_command)"
  if [[ -z "$primary_command" && "$role" == "shell" ]]; then
    primary_command="$(build_primary_shell_command)"
  elif [[ -z "$primary_command" ]]; then
    primary_command="$(window_primary_command "$window_target")"
  fi
  layout="$(window_layout_for_target "$window_target")"

  printf '%s\t%s\t%s\t%s\t%s\n' "$worktree_root" "$window_label" "$primary_command" "$layout" "$role"
}

apply_window_metadata() {
  local session_name="${1:?missing session name}"
  local window_target="${2:?missing window target}"
  local worktree_root="${3:?missing worktree root}"
  local window_label="${4:?missing window label}"
  local primary_command="${5:?missing primary command}"
  local layout="${6:?missing layout}"
  local role="${7:?missing role}"
  local workspace_name=""

  workspace_name="$(session_workspace_name "$session_name")"
  tmux_worktree_set_session_metadata "$session_name" "$workspace_name" "$(session_role "$session_name")"
  tmux_worktree_set_window_metadata "$window_target" "$role" "$worktree_root" "$window_label" "$primary_command" "$layout"
}

backfill_window_metadata() {
  local session_name="${1:?missing session name}"
  local window_target="${2:?missing window target}"
  local worktree_root=""
  local window_label=""
  local primary_command=""
  local layout=""
  local role=""

  IFS=$'\t' read -r worktree_root window_label primary_command layout role <<< "$(window_refresh_spec "$session_name" "$window_target")"
  apply_window_metadata "$session_name" "$window_target" "$worktree_root" "$window_label" "$primary_command" "$layout" "$role"
}

reset_window_in_place() {
  local session_name=""
  local window_id=""
  local cwd=""
  local requested_cwd=""
  local worktree_root=""
  local window_label=""
  local primary_command=""
  local layout=""
  local role=""
  local target_pane=""
  local target_pane_index=""
  local target_pane_path=""
  local pane_count=0

  while (($# > 0)); do
    case "$1" in
      --session-name)
        session_name="${2:?missing value for --session-name}"
        shift 2
        ;;
      --window-id)
        window_id="${2:?missing value for --window-id}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset refresh-current-window: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  session_name="$(context_value_or_env "$session_name" COMMAND_PANEL_SESSION_NAME)"
  window_id="$(context_value_or_env "$window_id" COMMAND_PANEL_WINDOW_ID)"
  cwd="$(context_value_or_env "$cwd" COMMAND_PANEL_CWD)"
  requested_cwd="$(normalize_requested_cwd "$cwd")"

  [[ -n "$session_name" ]] || {
    printf 'tmux-reset refresh-current-window requires --session-name\n' >&2
    return 1
  }
  if [[ -z "$window_id" ]]; then
    window_id="$(active_window_id_for_session "$session_name" || true)"
  fi
  if [[ -z "$window_id" ]]; then
    runtime_log_warn workspace "no tmux window found for window reset" "session_name=$session_name" "cwd=${requested_cwd:-}"
    printf 'no_current_window\n'
    return 0
  fi

  IFS='|' read -r target_pane target_pane_index target_pane_path <<< "$(tmux display-message -p -t "$window_id" '#{pane_id}|#{pane_index}|#{pane_current_path}' 2>/dev/null || true)"
  [[ -n "$target_pane" ]] || {
    runtime_log_warn workspace "tmux window has no panes to reset" "session_name=$session_name" "window_id=$window_id"
    printf 'no_current_window\n'
    return 0
  }
  pane_count="$(tmux list-panes -t "$window_id" 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "${target_pane_index:-0}" == "0" && "$(session_role "$session_name")" == "managed" ]]; then
    backfill_window_metadata "$session_name" "$window_id"
  fi

  IFS=$'\t' read -r worktree_root window_label primary_command layout role <<< "$(window_refresh_spec "$session_name" "$window_id" "$requested_cwd")"

  if [[ "${target_pane_index:-0}" != "0" ]]; then
    if [[ -n "$target_pane_path" && -d "$target_pane_path" && ! "$target_pane_path" =~ ^/mnt/[a-z]/Users/[^/]+$ ]]; then
      worktree_root="$(tmux_worktree_abs_path "$target_pane_path")"
    elif [[ -n "$requested_cwd" ]]; then
      worktree_root="$requested_cwd"
    else
      worktree_root="${HOME:-$PWD}"
    fi
    primary_command="$(build_primary_shell_command)"
  fi

  runtime_log_info workspace "resetting tmux window in place" \
    "session_name=$session_name" \
    "window_id=$window_id" \
    "target_pane=$target_pane" \
    "target_pane_index=$target_pane_index" \
    "worktree_root=$worktree_root" \
    "window_label=$window_label" \
    "primary_command=$primary_command" \
    "layout=$layout" \
    "role=$role"

  tmux respawn-pane -k -t "$target_pane" -c "$worktree_root" "$primary_command"
  tmux rename-window -t "$window_id" "$window_label" 2>/dev/null || true
  if [[ "${target_pane_index:-0}" == "0" && "$layout" == "managed_two_pane" && "${pane_count:-0}" -lt 2 ]]; then
    tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"
  fi
  if [[ "${target_pane_index:-0}" == "0" ]]; then
    apply_window_metadata "$session_name" "$window_id" "$worktree_root" "$window_label" "$primary_command" "$layout" "$role"
  fi

  printf 'reset_window_in_place\n'
}

list_attached_clients_for_session() {
  local session_name="${1:?missing session name}"
  local client_tty=""

  while IFS='|' read -r client_tty attached_session; do
    [[ -n "$client_tty" && "$attached_session" == "$session_name" ]] || continue
    printf '%s\n' "$client_tty"
  done < <(tmux list-clients -F '#{client_tty}|#{session_name}' 2>/dev/null || true)
}

session_option_value() {
  local session_name="${1:?missing session name}"
  local option_name="${2:?missing option name}"
  tmux show-options -v -t "$session_name" "$option_name" 2>/dev/null || true
}

replacement_session_name() {
  local session_name="${1:?missing session name}"
  printf '%s__refresh_%s_%s\n' "$session_name" "$(date +%Y%m%dT%H%M%S)" "$$"
}

backfill_session_metadata() {
  local session_name="${1:?missing session name}"
  local window_id=""
  local worktree_root=""
  local window_label=""
  local primary_command=""
  local layout=""
  local role=""
  local workspace_name=""
  local session_role_value=""

  workspace_name="$(session_workspace_name "$session_name")"
  session_role_value="$(session_role "$session_name")"
  tmux_worktree_set_session_metadata "$session_name" "$workspace_name" "$session_role_value"

  while IFS= read -r window_id; do
    [[ -n "$window_id" ]] || continue
    backfill_window_metadata "$session_name" "$window_id"
  done < <(tmux list-windows -t "$session_name" -F '#{window_id}' 2>/dev/null || true)
}

create_window_from_spec() {
  local session_name="${1:?missing session name}"
  local create_mode="${2:?missing create mode}"
  local worktree_root="${3:?missing worktree root}"
  local window_label="${4:?missing window label}"
  local primary_command="${5:?missing primary command}"
  local layout="${6:?missing layout}"
  local role="${7:?missing role}"
  local window_id=""

  if [[ "$create_mode" == "session" ]]; then
    window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -n "$window_label" -c "$worktree_root" "$primary_command")"
  else
    window_id="$(tmux new-window -d -P -F '#{window_id}' -t "$session_name" -n "$window_label" -c "$worktree_root" "$primary_command")"
  fi

  if [[ "$layout" == "managed_two_pane" ]]; then
    tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"
  fi

  apply_window_metadata "$session_name" "$window_id" "$worktree_root" "$window_label" "$primary_command" "$layout" "$role"
  printf '%s\n' "$window_id"
}

clone_session_via_replacement() {
  local source_session="${1:?missing source session}"
  local current_window_id="${2:-}"
  local requested_cwd="${3:-}"
  local temp_session=""
  local source_workspace=""
  local source_role=""
  local active_ordinal=0
  local ordinal=0
  local window_id=""
  local window_active=""
  local worktree_root=""
  local window_label=""
  local primary_command=""
  local layout=""
  local role=""
  local session_status=""
  local destroy_unattached=""

  temp_session="$(replacement_session_name "$source_session")"
  source_workspace="$(session_workspace_name "$source_session")"
  source_role="$(session_role "$source_session")"

  while IFS='|' read -r window_id window_active; do
    [[ -n "$window_id" ]] || continue
    if [[ "$window_id" == "$current_window_id" ]]; then
      IFS=$'\t' read -r worktree_root window_label primary_command layout role <<< "$(window_refresh_spec "$source_session" "$window_id" "$requested_cwd")"
    else
      IFS=$'\t' read -r worktree_root window_label primary_command layout role <<< "$(window_refresh_spec "$source_session" "$window_id")"
    fi

    if (( ordinal == 0 )); then
      create_window_from_spec "$temp_session" session "$worktree_root" "$window_label" "$primary_command" "$layout" "$role" >/dev/null
      tmux_worktree_set_session_metadata "$temp_session" "$source_workspace" "$source_role"
    else
      create_window_from_spec "$temp_session" window "$worktree_root" "$window_label" "$primary_command" "$layout" "$role" >/dev/null
    fi

    if [[ "$window_active" == "1" ]]; then
      active_ordinal="$ordinal"
    fi
    ordinal=$((ordinal + 1))
  done < <(tmux list-windows -t "$source_session" -F '#{window_id}|#{window_active}' 2>/dev/null || true)

  session_status="$(session_option_value "$source_session" status)"
  destroy_unattached="$(session_option_value "$source_session" destroy-unattached)"
  [[ -n "$session_status" ]] && tmux set-option -t "$temp_session" status "$session_status" >/dev/null 2>&1 || true
  [[ -n "$destroy_unattached" ]] && tmux set-option -t "$temp_session" destroy-unattached "$destroy_unattached" >/dev/null 2>&1 || true

  tmux select-window -t "${temp_session}:${active_ordinal}" >/dev/null 2>&1 || true
  printf '%s\n' "$temp_session"
}

switch_session_clients() {
  local source_session="${1:?missing source session}"
  local target_session="${2:?missing target session}"
  local current_client_tty="${3:-}"
  local client_tty=""

  while IFS= read -r client_tty; do
    [[ -n "$client_tty" ]] || continue
    tmux switch-client -c "$client_tty" -t "$target_session" >/dev/null 2>&1 || tmux switch-client -t "$target_session" >/dev/null 2>&1 || true
  done < <(list_attached_clients_for_session "$source_session")

  if [[ -n "$current_client_tty" ]]; then
    tmux switch-client -c "$current_client_tty" -t "$target_session" >/dev/null 2>&1 || tmux switch-client -t "$target_session" >/dev/null 2>&1 || true
  fi
}

replace_session_in_place() {
  local source_session="${1:?missing source session}"
  local current_window_id="${2:-}"
  local requested_cwd="${3:-}"
  local current_client_tty="${4:-}"
  local temp_session=""

  tmux has-session -t "$source_session" >/dev/null 2>&1 || return 0

  runtime_log_info workspace "refreshing tmux session via replacement session" \
    "session_name=$source_session" \
    "current_window_id=$current_window_id" \
    "requested_cwd=$requested_cwd" \
    "client_tty=$current_client_tty"

  backfill_session_metadata "$source_session"
  temp_session="$(clone_session_via_replacement "$source_session" "$current_window_id" "$requested_cwd")"
  switch_session_clients "$source_session" "$temp_session" "$current_client_tty"
  tmux kill-session -t "$source_session" >/dev/null 2>&1 || true
  tmux rename-session -t "$temp_session" "$source_session" >/dev/null 2>&1 || true
}

workspace_session_names() {
  local workspace_name="${1:?missing workspace name}"
  local session_name=""

  while IFS= read -r session_name; do
    [[ -n "$session_name" ]] || continue
    if [[ "$(session_workspace_name "$session_name")" == "$workspace_name" ]]; then
      printf '%s\n' "$session_name"
    fi
  done < <(list_sessions)
}

ordered_target_sessions() {
  local current_session="${1:-}"
  shift || true
  local session_name=""

  for session_name in "$@"; do
    [[ -n "$session_name" && "$session_name" != "$current_session" ]] || continue
    printf '%s\n' "$session_name"
  done

  if [[ -n "$current_session" ]]; then
    for session_name in "$@"; do
      if [[ "$session_name" == "$current_session" ]]; then
        printf '%s\n' "$session_name"
        break
      fi
    done
  fi
}

refresh_current_window() {
  reset_window_in_place "$@"
}

refresh_current_session() {
  local session_name=""
  local window_id=""
  local cwd=""
  local client_tty=""
  local requested_cwd=""

  while (($# > 0)); do
    case "$1" in
      --session-name)
        session_name="${2:?missing value for --session-name}"
        shift 2
        ;;
      --window-id)
        window_id="${2:?missing value for --window-id}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      --client-tty)
        client_tty="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset refresh-current-session: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  session_name="$(context_value_or_env "$session_name" COMMAND_PANEL_SESSION_NAME)"
  window_id="$(context_value_or_env "$window_id" COMMAND_PANEL_WINDOW_ID)"
  cwd="$(context_value_or_env "$cwd" COMMAND_PANEL_CWD)"
  client_tty="$(context_value_or_env "$client_tty" COMMAND_PANEL_CLIENT_TTY)"
  requested_cwd="$(normalize_requested_cwd "$cwd")"

  [[ -n "$session_name" ]] || {
    printf 'tmux-reset refresh-current-session requires --session-name\n' >&2
    return 1
  }

  replace_session_in_place "$session_name" "$window_id" "$requested_cwd" "$client_tty"
  printf 'refreshed_session\n'
}

refresh_current_workspace() {
  local session_name=""
  local window_id=""
  local cwd=""
  local client_tty=""
  local requested_cwd=""
  local workspace_name=""
  local target_session=""
  local -a sessions=()

  while (($# > 0)); do
    case "$1" in
      --session-name)
        session_name="${2:?missing value for --session-name}"
        shift 2
        ;;
      --window-id)
        window_id="${2:?missing value for --window-id}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      --client-tty)
        client_tty="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset refresh-current-workspace: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  session_name="$(context_value_or_env "$session_name" COMMAND_PANEL_SESSION_NAME)"
  window_id="$(context_value_or_env "$window_id" COMMAND_PANEL_WINDOW_ID)"
  cwd="$(context_value_or_env "$cwd" COMMAND_PANEL_CWD)"
  client_tty="$(context_value_or_env "$client_tty" COMMAND_PANEL_CLIENT_TTY)"
  requested_cwd="$(normalize_requested_cwd "$cwd")"
  workspace_name="$(session_workspace_name "$session_name")"

  [[ -n "$workspace_name" ]] || {
    printf 'tmux-reset refresh-current-workspace could not resolve workspace\n' >&2
    return 1
  }

  while IFS= read -r target_session; do
    [[ -n "$target_session" ]] || continue
    sessions+=("$target_session")
  done < <(workspace_session_names "$workspace_name")

  while IFS= read -r target_session; do
    [[ -n "$target_session" ]] || continue
    if [[ "$target_session" == "$session_name" ]]; then
      replace_session_in_place "$target_session" "$window_id" "$requested_cwd" "$client_tty"
    else
      replace_session_in_place "$target_session"
    fi
  done < <(ordered_target_sessions "$session_name" "${sessions[@]}")

  printf 'refreshed_workspace\n'
}

refresh_all_sessions() {
  local session_name=""
  local window_id=""
  local cwd=""
  local client_tty=""
  local requested_cwd=""
  local target_session=""
  local -a sessions=()

  while (($# > 0)); do
    case "$1" in
      --session-name)
        session_name="${2:?missing value for --session-name}"
        shift 2
        ;;
      --window-id)
        window_id="${2:?missing value for --window-id}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      --client-tty)
        client_tty="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset refresh-all: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  session_name="$(context_value_or_env "$session_name" COMMAND_PANEL_SESSION_NAME)"
  window_id="$(context_value_or_env "$window_id" COMMAND_PANEL_WINDOW_ID)"
  cwd="$(context_value_or_env "$cwd" COMMAND_PANEL_CWD)"
  client_tty="$(context_value_or_env "$client_tty" COMMAND_PANEL_CLIENT_TTY)"
  requested_cwd="$(normalize_requested_cwd "$cwd")"

  while IFS= read -r target_session; do
    [[ -n "$target_session" ]] || continue
    sessions+=("$target_session")
  done < <(list_sessions)

  while IFS= read -r target_session; do
    [[ -n "$target_session" ]] || continue
    if [[ "$target_session" == "$session_name" ]]; then
      replace_session_in_place "$target_session" "$window_id" "$requested_cwd" "$client_tty"
    else
      replace_session_in_place "$target_session"
    fi
  done < <(ordered_target_sessions "$session_name" "${sessions[@]}")

  printf 'refreshed_all\n'
}

reset_managed_window() {
  local workspace=""
  local cwd=""
  local session_name=""
  local window_id=""
  local requested_cwd=""

  while (($# > 0)); do
    case "$1" in
      --workspace)
        workspace="${2:?missing value for --workspace}"
        shift 2
        ;;
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      *)
        printf 'tmux-reset reset-managed-window: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  requested_cwd="$(normalize_requested_cwd "$cwd")"
  session_name="$(resolve_current_workspace_session --workspace "$workspace" --cwd "$requested_cwd" || true)"
  window_id="$(active_window_id_for_session "$session_name" || true)"
  reset_window_in_place --session-name "$session_name" --window-id "$window_id" --cwd "$cwd"
}

reset_current_window() {
  refresh_current_window "$@"
}

reset_default_session() {
  local cwd=""
  local requested_cwd=""
  local current_session=""
  local current_window_id=""
  local kill_other_default_sessions=0
  local kill_other_sessions=0
  local session_name=""
  local -a cleanup_sessions=()

  while (($# > 0)); do
    case "$1" in
      --cwd)
        cwd="${2-}"
        shift 2
        ;;
      --kill-other-default-sessions)
        kill_other_default_sessions=1
        shift
        ;;
      --kill-other-sessions)
        kill_other_sessions=1
        shift
        ;;
      *)
        printf 'tmux-reset reset-default: unknown option: %s\n' "$1" >&2
        return 1
        ;;
    esac
  done

  requested_cwd="$(normalize_requested_cwd "$cwd")"
  if [[ -n "$requested_cwd" ]]; then
    current_session="$(resolve_default_session --cwd "$requested_cwd" || true)"
  fi
  if [[ -z "$current_session" ]]; then
    current_session="$(resolve_attached_default_session || true)"
  fi
  if [[ -z "$current_session" ]]; then
    runtime_log_warn workspace "no current default tmux session found for in-place reset" "cwd=${requested_cwd:-${HOME:-$PWD}}"
    printf 'no_current_session\n'
    return 0
  fi

  current_window_id="$(active_window_id_for_session "$current_session" || true)"
  reset_window_in_place --session-name "$current_session" --window-id "$current_window_id" --cwd "$cwd" >/dev/null

  if (( kill_other_sessions )); then
    while IFS= read -r session_name; do
      [[ -n "$session_name" && "$session_name" != "$current_session" ]] || continue
      cleanup_sessions+=("$session_name")
    done < <(list_sessions)
  elif (( kill_other_default_sessions )); then
    while IFS= read -r session_name; do
      [[ -n "$session_name" && "$session_name" != "$current_session" ]] || continue
      cleanup_sessions+=("$session_name")
    done < <(list_default_sessions)
  fi

  for session_name in "${cleanup_sessions[@]}"; do
    tmux kill-session -t "$session_name" >/dev/null 2>&1 || true
  done

  printf 'reset_in_place\n'
}

case "$subcommand" in
  session-name)
    resolve_session_name "$@"
    ;;
  current-session)
    resolve_current_workspace_session "$@"
    ;;
  refresh-current-window)
    refresh_current_window "$@"
    ;;
  refresh-current-session)
    refresh_current_session "$@"
    ;;
  refresh-current-workspace)
    refresh_current_workspace "$@"
    ;;
  refresh-all)
    refresh_all_sessions "$@"
    ;;
  reset-managed-window)
    reset_managed_window "$@"
    ;;
  reset-current-window)
    reset_current_window "$@"
    ;;
  reset-default)
    reset_default_session "$@"
    ;;
  resolve-default-session)
    resolve_default_session "$@"
    ;;
  list-default-sessions)
    list_default_sessions "$@"
    ;;
  list-sessions)
    list_sessions "$@"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
