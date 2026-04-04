#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

usage() {
  cat <<'EOF' >&2
usage:
  open-current-dir-in-vscode.sh [--window WINDOW_ID] [--code-command ARG ... --] [target_dir]
EOF
}

code_command=()
tmux_window_id=""
window_root=""
start_ms="$(runtime_log_now_ms)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)
      tmux_window_id="${2:-}"
      shift 2
      ;;
    --code-command)
      shift
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
          shift
          break
        fi
        code_command+=("$1")
        shift
      done
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

target_dir="${1:-$PWD}"
requested_dir="$target_dir"

if [[ "$target_dir" != /* ]]; then
  runtime_log_error alt_o "expected absolute path" "requested_dir=$target_dir"
  exit 1
fi

if [[ ! -d "$target_dir" ]]; then
  runtime_log_error alt_o "directory does not exist" "requested_dir=$target_dir"
  exit 1
fi

if [[ -n "$tmux_window_id" ]]; then
  window_root="$(tmux_worktree_current_root_for_window "$tmux_window_id" || true)"
  if [[ -n "$window_root" ]]; then
    target_dir="$window_root"
  fi
fi

if [[ -z "$target_dir" ]]; then
  target_dir="$requested_dir"
fi

if [[ -z "$window_root" ]] && repo_root="$(tmux_worktree_repo_root "$target_dir" 2>/dev/null || true)" && [[ -n "$repo_root" ]]; then
  target_dir="$repo_root"
fi

if (( ${#code_command[@]} == 0 )); then
  code_bin="$(command -v code || true)"
  if [[ -z "$code_bin" ]]; then
    runtime_log_error alt_o "code binary was not found" "requested_dir=$requested_dir"
    exit 1
  fi
  code_command=("$code_bin")
fi

cd "$target_dir"
if "${code_command[@]}" .; then
  runtime_log_info alt_o "open-current-dir-in-vscode completed" \
    "requested_dir=$requested_dir" \
    "effective_dir=$PWD" \
    "code_command=${code_command[*]}" \
    "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

status=$?
runtime_log_error alt_o "open-current-dir-in-vscode failed" \
  "requested_dir=$requested_dir" \
  "effective_dir=$PWD" \
  "code_command=${code_command[*]}" \
  "duration_ms=$(runtime_log_duration_ms "$start_ms")" \
  "exit_code=$status"
exit "$status"
