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

# Returns the agent profile base (claude / codex / …) when the active
# `MANAGED_AGENT_PROFILE` has a configured `*_RESUME_COMMAND` — i.e. when
# `resolve_resume_primary_command` would actually override the metadata
# command with the agent wrapper. Empty otherwise. Used by the refresh
# path to decide whether to tag the pane with `@wezterm_pane_role` so
# the C-n / User3 bindings can detect agent panes through the wrapper's
# leaf=sh / leaf=node startup transient.
agent_profile_for_managed_pane() {
  local wezterm_repo="$1"
  if ! declare -F resolve_resume_primary_command >/dev/null 2>&1; then
    return 0
  fi
  local resume_command
  resume_command="$(resolve_resume_primary_command "$wezterm_repo" 2>/dev/null || true)"
  [[ -n "$resume_command" ]] || return 0
  local profile="${MANAGED_AGENT_PROFILE:-claude}"
  profile="${profile%-resume}"
  printf '%s\n' "$profile"
}

# Tag (or untag) a primary pane with `@wezterm_pane_role=agent-cli:<profile>`
# so the C-n / User3 bindings can detect it through the resume wrapper's
# leaf=sh / leaf=node boot transient. Used by every path that respawns
# or freshly creates a managed primary pane (in-place window refresh,
# session-replacement clone, …) to keep the predicate semantics in one
# place.
ensure_primary_pane_role_tag() {
  local pane_id="${1:?missing pane id}"
  local role="${2:-}"
  local wezterm_repo="${3:-}"
  local agent_profile=""

  [[ -n "$pane_id" ]] || return 0
  if [[ "$role" == managed* ]]; then
    agent_profile="$(agent_profile_for_managed_pane "$wezterm_repo" 2>/dev/null || true)"
  fi
  if [[ -n "$agent_profile" ]]; then
    tmux set-option -p -t "$pane_id" @wezterm_pane_role "agent-cli:$agent_profile" 2>/dev/null || true
  else
    tmux set-option -p -t "$pane_id" -u @wezterm_pane_role 2>/dev/null || true
  fi
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
