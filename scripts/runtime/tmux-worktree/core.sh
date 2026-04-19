#!/usr/bin/env bash

tmux_worktree_hash() {
  local value="${1:-}"

  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha1sum | awk '{print substr($1, 1, 10)}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum | awk '{print substr($1, 1, 10)}'
    return
  fi

  printf '%s' "$value" | cksum | awk '{print $1}'
}

tmux_worktree_shell_quote() {
  printf '%q' "${1:-}"
}

tmux_worktree_sanitize_name() {
  printf '%s' "${1:-}" | tr '/ .:' '____'
}

tmux_worktree_abs_path() {
  local path="${1:-$PWD}"
  (
    cd "$path"
    pwd -P
  )
}

tmux_worktree_file_mtime() {
  local path="${1:?missing path}"

  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
    return
  fi

  stat -f %m "$path"
}
