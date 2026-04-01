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
  WEZTERM_CONFIG_REPO="${WEZTERM_CONFIG_REPO:-${WT_CONFIG_WEZTERM_REPO:-}}"
  WEZTERM_CONFIG_REPO_ROOT=""
  WEZTERM_CONFIG_REPO_FILE=""
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

wt_config_is_wezterm_repo_root() {
  local repo_root="${1:-}"
  [[ -n "$repo_root" ]] || return 1
  [[ -d "$repo_root" && -f "$repo_root/wezterm.lua" && -d "$repo_root/wezterm-x" ]]
}

wt_config_is_wezterm_profile_repo_root() {
  local repo_root="${1:-}"
  wt_config_is_wezterm_repo_root "$repo_root" || return 1
  [[ -f "$repo_root/.worktree-task/config.env" ]]
}

wt_config_apply_setting() {
  local key="${1:?missing key}"
  local value="${2-}"

  case "$key" in
    WT_POLICY_WORKTREE_DIR|WT_POLICY_METADATA_DIR|WT_POLICY_BRANCH_PREFIX|WT_POLICY_BASE_REF_STRATEGY|WT_POLICY_SLUG_FALLBACK|WT_POLICY_RECLAIM_DIRTY|WT_POLICY_RECLAIM_DELETE_BRANCH|WT_PROVIDER_MODE|WT_PROVIDER|WT_PROVIDER_SEARCH_PATHS|WT_PROVIDER_WORKSPACE|WT_PROVIDER_DEFAULT_VARIANT|WT_PROVIDER_ATTACH_DEFAULT|WT_PROVIDER_SESSION_NAME_OVERRIDE|WT_PROVIDER_TMUX_CONFIG_FILE|WT_PROVIDER_AGENT_BOOTSTRAP|WT_PROVIDER_AGENT_COMMAND|WT_PROVIDER_AGENT_COMMAND_LIGHT|WT_PROVIDER_AGENT_COMMAND_DARK|WT_PROVIDER_AGENT_PROMPT_FLAG|WT_PROVIDER_LOGIN_SHELL)
      printf -v "$key" '%s' "$value"
      ;;
    WEZTERM_CONFIG_REPO|WT_CONFIG_WEZTERM_REPO)
      printf -v WEZTERM_CONFIG_REPO '%s' "$value"
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

wt_config_base_dir_for_file() {
  local file="${1:?missing config file}"
  local parent_dir=""

  parent_dir="$(dirname "$file")"
  if [[ "$(basename "$parent_dir")" == ".worktree-task" ]]; then
    dirname "$parent_dir"
    return 0
  fi

  printf '%s\n' "$parent_dir"
}

wt_config_find_wezterm_repo_in_file() {
  local file="${1:?missing config file}"
  local line=""
  local trimmed=""
  local key=""
  local value=""
  local found=1

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(wt_trim "$line")"
    [[ -n "$trimmed" ]] || continue
    if [[ "$trimmed" == \#* || "$trimmed" == \;* ]]; then
      continue
    fi
    [[ "$trimmed" == *=* ]] || continue

    key="$(wt_trim "${trimmed%%=*}")"
    case "$key" in
      WEZTERM_CONFIG_REPO|WT_CONFIG_WEZTERM_REPO)
        value="$(wt_config_parse_value "${trimmed#*=}")"
        found=0
        ;;
    esac
  done < "$file"

  if [[ "$found" -eq 0 ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  return 1
}

wt_config_validate_wezterm_repo_root() {
  local repo_root="${1:?missing repo root}"

  [[ -d "$repo_root" ]] || wt_die "wezterm config repo does not exist: $repo_root"
  wt_config_is_wezterm_profile_repo_root "$repo_root" || wt_die "wezterm config repo is missing wezterm.lua, wezterm-x, or .worktree-task/config.env: $repo_root"
}

wt_config_resolve_wezterm_repo_root() {
  local base_dir="${1:?missing base dir}"
  local repo_value="${2:?missing repo value}"
  local candidate=""

  candidate="$(wt_resolve_path "$base_dir" "$repo_value")"
  [[ -d "$candidate" ]] || wt_die "wezterm config repo does not exist: $candidate"
  candidate="$(wt_abs_path "$candidate")"
  wt_config_validate_wezterm_repo_root "$candidate"
  printf '%s\n' "$candidate"
}

wt_config_save_user_wezterm_repo() {
  local repo_root="${1:?missing repo root}"
  local user_file="${WT_CONFIG_USER_FILE:?missing user config file}"
  local tmp_file=""
  local line=""
  local trimmed=""
  local key=""
  local replaced=0

  mkdir -p "$(dirname "$user_file")"
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/worktree-task-config.XXXXXX")"

  if [[ -f "$user_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="$(wt_trim "$line")"
      if [[ -n "$trimmed" && "$trimmed" == *=* ]]; then
        key="$(wt_trim "${trimmed%%=*}")"
        case "$key" in
          WEZTERM_CONFIG_REPO|WT_CONFIG_WEZTERM_REPO)
            if [[ "$replaced" -eq 0 ]]; then
              printf 'WEZTERM_CONFIG_REPO=%s\n' "$repo_root" >> "$tmp_file"
              replaced=1
            fi
            continue
            ;;
        esac
      fi
      printf '%s\n' "$line" >> "$tmp_file"
    done < "$user_file"
  fi

  if [[ "$replaced" -eq 0 ]]; then
    [[ ! -s "$tmp_file" ]] || printf '\n' >> "$tmp_file"
    printf 'WEZTERM_CONFIG_REPO=%s\n' "$repo_root" >> "$tmp_file"
  fi

  mv "$tmp_file" "$user_file"
}

wt_config_discover_wezterm_repo() {
  local repo_value=""
  local base_dir=""

  WEZTERM_CONFIG_REPO_ROOT=""
  WEZTERM_CONFIG_REPO_FILE=""

  if [[ -n "${WEZTERM_CONFIG_REPO:-}" ]]; then
    WEZTERM_CONFIG_REPO_ROOT="$(wt_config_resolve_wezterm_repo_root "$PWD" "$WEZTERM_CONFIG_REPO")"
  fi

  if repo_value="$(wt_config_find_wezterm_repo_in_file "$WT_CONFIG_USER_FILE" 2>/dev/null || true)"; then
    if [[ -n "$repo_value" ]]; then
      base_dir="$(wt_config_base_dir_for_file "$WT_CONFIG_USER_FILE")"
      WEZTERM_CONFIG_REPO_ROOT="$(wt_config_resolve_wezterm_repo_root "$base_dir" "$repo_value")"
    fi
  fi

  if repo_value="$(wt_config_find_wezterm_repo_in_file "$WT_CONFIG_REPO_FILE" 2>/dev/null || true)"; then
    if [[ -n "$repo_value" ]]; then
      base_dir="$(wt_config_base_dir_for_file "$WT_CONFIG_REPO_FILE")"
      WEZTERM_CONFIG_REPO_ROOT="$(wt_config_resolve_wezterm_repo_root "$base_dir" "$repo_value")"
    fi
  fi

  if [[ -n "$WEZTERM_CONFIG_REPO_ROOT" ]]; then
    WEZTERM_CONFIG_REPO_FILE="$WEZTERM_CONFIG_REPO_ROOT/.worktree-task/config.env"
    [[ -f "$WEZTERM_CONFIG_REPO_FILE" ]] || wt_die "wezterm config repo is missing .worktree-task/config.env: $WEZTERM_CONFIG_REPO_ROOT"
    return 0
  fi

  wt_die "WEZTERM_CONFIG_REPO is required for worktree-task; run 'worktree-task configure --repo /absolute/path/to/wezterm-config' or set it in $WT_CONFIG_USER_FILE"
}

wt_config_load() {
  wt_config_set_defaults
  wt_config_discover_wezterm_repo
  wt_config_load_file "$WEZTERM_CONFIG_REPO_FILE"
  wt_config_load_file "$WT_CONFIG_USER_FILE"
  wt_config_load_file "$WT_CONFIG_REPO_FILE"
  if [[ -n "$WEZTERM_CONFIG_REPO_ROOT" ]]; then
    WEZTERM_CONFIG_REPO="$WEZTERM_CONFIG_REPO_ROOT"
  fi
}

wt_config_expand_repo_tokens() {
  local value="${1:-}"
  value="${value//\{repo\}/$WT_REPO_LABEL}"
  printf '%s\n' "$value"
}

wt_config_resolve_under_main_root() {
  wt_resolve_path "$WT_MAIN_WORKTREE_ROOT" "${1:?missing relative path}"
}

wt_config_resolve_under_wezterm_repo() {
  local path="${1:?missing relative path}"

  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  [[ -n "${WEZTERM_CONFIG_REPO_ROOT:-}" ]] || wt_die "relative repo-managed path requires WEZTERM_CONFIG_REPO to point at a wezterm-config repo"
  wt_resolve_path "$WEZTERM_CONFIG_REPO_ROOT" "$path"
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
