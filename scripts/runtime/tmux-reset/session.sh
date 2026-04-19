#!/usr/bin/env bash

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
