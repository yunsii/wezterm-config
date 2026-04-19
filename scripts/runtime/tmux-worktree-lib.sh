#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/core.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/git.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/context.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/metadata.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/window.sh"
