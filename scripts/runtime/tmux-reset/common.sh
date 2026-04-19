#!/usr/bin/env bash

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
