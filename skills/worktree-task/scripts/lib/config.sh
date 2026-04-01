#!/usr/bin/env bash

wt_config_set_defaults() {
  WT_POLICY_WORKTREE_DIR=".worktrees/{repo}"
  WT_POLICY_METADATA_DIR=".worktrees/{repo}/.task-meta"
  WT_POLICY_BRANCH_PREFIX="task/"
  WT_POLICY_BASE_REF_STRATEGY="primary-head"
  WT_POLICY_SLUG_FALLBACK="task"
  WT_POLICY_RECLAIM_DIRTY="refuse"
  WT_POLICY_RECLAIM_DELETE_BRANCH="merged-into-primary-head"

  WT_PROVIDER_MODE="off"
  WT_PROVIDER="none"
  WT_PROVIDER_SEARCH_PATHS="${XDG_CONFIG_HOME:-$HOME/.config}/worktree-task/providers"
  WT_PROVIDER_WORKSPACE="task"
  WT_PROVIDER_DEFAULT_VARIANT="auto"
  WT_PROVIDER_ATTACH_DEFAULT="1"
  WT_PROVIDER_SESSION_NAME_OVERRIDE=""
  WT_PROVIDER_TMUX_CONFIG_FILE=""
  WT_PROVIDER_AGENT_BOOTSTRAP="nvm"
  WT_PROVIDER_AGENT_COMMAND="codex"
  WT_PROVIDER_AGENT_COMMAND_LIGHT=""
  WT_PROVIDER_AGENT_COMMAND_DARK=""
  WT_PROVIDER_AGENT_PROMPT_FLAG=""
  WT_PROVIDER_LOGIN_SHELL=""

  WT_CONFIG_USER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/worktree-task/config.env"
  WT_CONFIG_REPO_FILE="$WT_MAIN_WORKTREE_ROOT/.worktree-task/config.env"
}

wt_config_parse_value() {
  local value
  value="$(wt_trim "${1-}")"

  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s\n' "$value"
}

wt_config_apply_setting() {
  local key="${1:?missing key}"
  local value="${2-}"

  case "$key" in
    WT_POLICY_WORKTREE_DIR|WT_POLICY_METADATA_DIR|WT_POLICY_BRANCH_PREFIX|WT_POLICY_BASE_REF_STRATEGY|WT_POLICY_SLUG_FALLBACK|WT_POLICY_RECLAIM_DIRTY|WT_POLICY_RECLAIM_DELETE_BRANCH|WT_PROVIDER_MODE|WT_PROVIDER|WT_PROVIDER_SEARCH_PATHS|WT_PROVIDER_WORKSPACE|WT_PROVIDER_DEFAULT_VARIANT|WT_PROVIDER_ATTACH_DEFAULT|WT_PROVIDER_SESSION_NAME_OVERRIDE|WT_PROVIDER_TMUX_CONFIG_FILE|WT_PROVIDER_AGENT_BOOTSTRAP|WT_PROVIDER_AGENT_COMMAND|WT_PROVIDER_AGENT_COMMAND_LIGHT|WT_PROVIDER_AGENT_COMMAND_DARK|WT_PROVIDER_AGENT_PROMPT_FLAG|WT_PROVIDER_LOGIN_SHELL)
      printf -v "$key" '%s' "$value"
      ;;
    *)
      ;;
  esac
}

wt_config_load_file() {
  local file="${1:?missing config file}"
  local line=""
  local trimmed=""
  local key=""
  local value=""

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(wt_trim "$line")"
    [[ -n "$trimmed" ]] || continue
    if [[ "$trimmed" == \#* || "$trimmed" == \;* ]]; then
      continue
    fi
    [[ "$trimmed" == *=* ]] || continue

    key="$(wt_trim "${trimmed%%=*}")"
    value="$(wt_config_parse_value "${trimmed#*=}")"
    wt_config_apply_setting "$key" "$value"
  done < "$file"
}

wt_config_load() {
  wt_config_set_defaults
  wt_config_load_file "$WT_CONFIG_USER_FILE"
  wt_config_load_file "$WT_CONFIG_REPO_FILE"
}

wt_config_expand_repo_tokens() {
  local value="${1:-}"
  value="${value//\{repo\}/$WT_REPO_LABEL}"
  printf '%s\n' "$value"
}

wt_config_resolve_under_main_root() {
  wt_resolve_path "$WT_MAIN_WORKTREE_ROOT" "${1:?missing relative path}"
}

wt_config_resolve_under_repo_parent() {
  local path="${1:?missing relative path}"
  local repo_parent=""

  repo_parent="$(dirname "$WT_MAIN_WORKTREE_ROOT")"
  wt_resolve_path "$repo_parent" "$path"
}

wt_provider_builtin_path() {
  local scripts_dir="${1:?missing scripts dir}"
  local provider="${2:?missing provider}"

  case "$provider" in
    none)
      printf '%s/providers/none.sh\n' "$scripts_dir"
      ;;
    tmux-agent)
      printf '%s/providers/tmux-agent.sh\n' "$scripts_dir"
      ;;
    *)
      return 1
      ;;
  esac
}

wt_provider_resolve_command() {
  local scripts_dir="${1:?missing scripts dir}"
  local provider="${2:?missing provider}"

  if builtin_path="$(wt_provider_builtin_path "$scripts_dir" "$provider" 2>/dev/null)"; then
    printf '%s\n' "$builtin_path"
    return 0
  fi

  if [[ "$provider" == /* ]]; then
    [[ -x "$provider" ]] || return 1
    printf '%s\n' "$provider"
    return 0
  fi

  if [[ "$provider" == custom:* ]]; then
    local name="${provider#custom:}"
    local search_path=""
    local candidate=""
    IFS=: read -r -a search_paths <<< "$WT_PROVIDER_SEARCH_PATHS"
    for search_path in "${search_paths[@]}"; do
      [[ -n "$search_path" ]] || continue
      candidate="$search_path/$name"
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  return 1
}
