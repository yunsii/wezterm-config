#!/usr/bin/env bash

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

refresh_current_window() {
  reset_window_in_place "$@"
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
