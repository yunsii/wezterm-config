#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_CONF="$SCRIPT_DIR/../../tmux.conf"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  tmux-worktree-task-window.sh --worktree-root PATH --prompt-file FILE [options]

options:
  --workspace NAME     Session namespace when a new tmux session must be created. Default: task
  --cwd PATH           Path used when deriving a new tmux session name. Default: current directory
  --session-name NAME  Reuse or create a specific tmux session
  --variant MODE       Managed Codex variant: auto, light, or dark. Default: auto
  --no-attach          Create/select the window without switching the client or attaching
EOF
}

repo_root_path() {
  (
    cd "$SCRIPT_DIR/../.."
    pwd -P
  )
}

session_variant_from_command() {
  local session_command="${1:-}"

  case "$session_command" in
    *'tui.theme="github"'*|*'codex-github-theme'*)
      printf 'light\n'
      ;;
    *'codex'*)
      printf 'dark\n'
      ;;
    *)
      printf 'light\n'
      ;;
  esac
}

build_managed_codex_command() {
  local resolved_variant="${1:-light}"
  local prompt_file="${2:-}"
  local command_string=""

  command_string="bash $(tmux_worktree_shell_quote "$SCRIPT_DIR/start-managed-codex.sh")"
  command_string="$command_string --variant $(tmux_worktree_shell_quote "$resolved_variant")"

  if [[ -n "$prompt_file" ]]; then
    command_string="$command_string --prompt-file $(tmux_worktree_shell_quote "$prompt_file")"
  fi

  printf '%s\n' "$command_string"
}

workspace="task"
cwd="$PWD"
session_name=""
variant="auto"
prompt_file=""
worktree_root=""
attach_mode="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      workspace="$2"
      shift 2
      ;;
    --cwd)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      cwd="$2"
      shift 2
      ;;
    --session-name)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      session_name="$2"
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      variant="$2"
      shift 2
      ;;
    --prompt-file)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      prompt_file="$2"
      shift 2
      ;;
    --worktree-root)
      [[ $# -ge 2 ]] || { usage; exit 1; }
      worktree_root="$2"
      shift 2
      ;;
    --no-attach)
      attach_mode="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

[[ -n "$worktree_root" ]] || { usage; exit 1; }
[[ -n "$prompt_file" ]] || { usage; exit 1; }
[[ -f "$prompt_file" ]] || { printf 'prompt file does not exist: %s\n' "$prompt_file" >&2; exit 1; }

case "$variant" in
  auto|light|dark)
    ;;
  *)
    printf 'invalid variant: %s\n' "$variant" >&2
    exit 1
    ;;
esac

worktree_root="$(tmux_worktree_abs_path "$worktree_root")"
cwd="$(tmux_worktree_abs_path "$cwd")"

if [[ ! -d "$worktree_root" ]]; then
  printf 'worktree root does not exist: %s\n' "$worktree_root" >&2
  exit 1
fi

if ! tmux_worktree_in_git_repo "$worktree_root"; then
  printf 'not a git worktree: %s\n' "$worktree_root" >&2
  exit 1
fi

repo_common_dir="$(tmux_worktree_common_dir "$worktree_root")"
main_worktree_root="$(tmux_worktree_main_root "$repo_common_dir" || true)"
repo_label="$(tmux_worktree_repo_label "$worktree_root")"
worktree_label="$(tmux_worktree_label_for_root "$worktree_root" "$main_worktree_root")"
current_session_name=""

if [[ -n "${TMUX:-}" ]]; then
  current_session_name="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
fi

if [[ -z "$session_name" && -n "$current_session_name" ]]; then
  current_common_dir="$(tmux_worktree_session_option "$current_session_name" @wezterm_repo_common_dir)"
  if [[ -n "$current_common_dir" && "$current_common_dir" == "$repo_common_dir" ]]; then
    session_name="$current_session_name"
  fi
fi

if [[ -z "$session_name" ]]; then
  session_name="$(tmux_worktree_session_name_for_path "$workspace" "$cwd")"
fi

session_primary_shell_command=""
if tmux has-session -t "$session_name" 2>/dev/null; then
  existing_common_dir="$(tmux_worktree_session_option "$session_name" @wezterm_repo_common_dir)"
  if [[ -n "$existing_common_dir" && "$existing_common_dir" != "$repo_common_dir" ]]; then
    printf 'tmux session %s belongs to another repo family\n' "$session_name" >&2
    exit 1
  fi

  session_primary_shell_command="$(tmux_worktree_session_option "$session_name" @wezterm_primary_shell_command)"
fi

resolved_variant="$variant"
if [[ "$resolved_variant" == "auto" ]]; then
  if [[ -n "$session_primary_shell_command" ]]; then
    resolved_variant="$(session_variant_from_command "$session_primary_shell_command")"
  else
    resolved_variant="light"
  fi
fi

custom_window_command="$(build_managed_codex_command "$resolved_variant" "$prompt_file")"
if [[ -z "$session_primary_shell_command" ]]; then
  session_primary_shell_command="$(build_managed_codex_command "$resolved_variant")"
fi
window_create_mode="attach"
if [[ "$attach_mode" != "1" ]]; then
  window_create_mode="detached"
fi

window_id=""
if ! tmux has-session -t "$session_name" 2>/dev/null; then
  runtime_log_info worktree "creating tmux session for task worktree" "session_name=$session_name" "worktree_root=$worktree_root" "variant=$resolved_variant"
  window_id="$(tmux new-session -d -P -F '#{window_id}' -s "$session_name" -c "$worktree_root" "$custom_window_command")"
else
  window_id="$(tmux_worktree_find_window "$session_name" "$worktree_root" || true)"
  if [[ -z "$window_id" ]]; then
    runtime_log_info worktree "creating task worktree window" "session_name=$session_name" "worktree_root=$worktree_root" "worktree_label=$worktree_label" "variant=$resolved_variant" "create_mode=$window_create_mode"
    window_id="$(tmux_worktree_create_window "$session_name" "$worktree_root" "$custom_window_command" "$worktree_label" "$window_create_mode")"
  else
    runtime_log_info worktree "selecting existing task worktree window" "session_name=$session_name" "window_id=$window_id" "worktree_root=$worktree_root" "worktree_label=$worktree_label"
  fi
fi

tmux_worktree_set_session_metadata "$session_name" "$repo_common_dir" "$repo_label" "$main_worktree_root" "$session_primary_shell_command"
tmux_worktree_set_window_metadata "$window_id" "$worktree_root" "$worktree_label"
tmux rename-window -t "$window_id" "$worktree_label"
tmux_worktree_ensure_window_panes "$window_id" "$worktree_root"

tmux_worktree_ensure_tmux_config_loaded "$TMUX_CONF" "$(repo_root_path)"

printf 'session_name=%s\n' "$session_name"
printf 'window_id=%s\n' "$window_id"
printf 'worktree_root=%s\n' "$worktree_root"

if [[ "$attach_mode" != "1" ]]; then
  exit 0
fi

if [[ -n "${TMUX:-}" ]]; then
  if [[ -n "$current_session_name" && "$current_session_name" != "$session_name" ]]; then
    tmux switch-client -t "$session_name"
  fi
  tmux select-window -t "$window_id"
  exit 0
fi

exec tmux attach-session -t "$session_name"
