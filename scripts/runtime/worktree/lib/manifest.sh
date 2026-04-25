#!/usr/bin/env bash

wt_manifest_path() {
  local metadata_dir="${1:?missing metadata dir}"
  local task_slug="${2:?missing task slug}"
  printf '%s/%s.json\n' "$metadata_dir" "$task_slug"
}

wt_manifest_write() {
  local manifest_path="${1:?missing manifest path}"
  local task_slug="${2:?missing task slug}"
  local repo_common_dir="${3:?missing repo common dir}"
  local main_worktree_root="${4:?missing main worktree root}"
  local worktree_path="${5:?missing worktree path}"
  local branch_name="${6:-}"
  local provider="${7:-none}"
  local provider_session_name="${8:-}"
  local provider_window_id="${9:-}"

  cat > "$manifest_path" <<EOF
{
  "version": 1,
  "task_slug": "$(wt_json_escape "$task_slug")",
  "repo_common_dir": "$(wt_json_escape "$repo_common_dir")",
  "main_worktree_root": "$(wt_json_escape "$main_worktree_root")",
  "worktree_path": "$(wt_json_escape "$worktree_path")",
  "branch_name": "$(wt_json_escape "$branch_name")",
  "provider": "$(wt_json_escape "$provider")",
  "provider_session_name": "$(wt_json_escape "$provider_session_name")",
  "provider_window_id": "$(wt_json_escape "$provider_window_id")"
}
EOF
}

wt_manifest_read_field() {
  local manifest_path="${1:?missing manifest path}"
  local field="${2:?missing field}"
  local value=""

  [[ -f "$manifest_path" ]] || return 1

  value="$(sed -nE 's/^[[:space:]]*"'$field'"[[:space:]]*:[[:space:]]*"(.*)"[,]?$/\1/p' "$manifest_path" | head -n 1)"
  value="${value//\\\"/\"}"
  value="${value//\\\\/\\}"
  printf '%s\n' "$value"
}
