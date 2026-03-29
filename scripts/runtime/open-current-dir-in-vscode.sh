#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/tmux-worktree-lib.sh"

target_dir="${1:-$PWD}"
runtime_log_info alt_o "open-current-dir-in-vscode invoked" "requested_dir=$target_dir"

if [[ "$target_dir" != /* ]]; then
  runtime_log_error alt_o "expected absolute path" "requested_dir=$target_dir"
  exit 1
fi

if [[ ! -d "$target_dir" ]]; then
  runtime_log_error alt_o "directory does not exist" "requested_dir=$target_dir"
  exit 1
fi

target_dir="$(tmux_worktree_primary_root_for_path "$target_dir")"
runtime_log_info alt_o "resolved Alt+o target directory" "effective_target_dir=$target_dir"

code_bin="$(command -v code || true)"
runtime_log_info alt_o "resolved code binary" "code_bin=${code_bin:-missing}"

cd "$target_dir"
runtime_log_info alt_o "changed to effective directory" "effective_dir=$PWD"

if [[ -z "$code_bin" ]]; then
  runtime_log_error alt_o "code binary was not found" "requested_dir=$target_dir"
  exit 1
fi

runtime_log_info alt_o "executing code from current directory" "effective_dir=$PWD"
exec "$code_bin" .
