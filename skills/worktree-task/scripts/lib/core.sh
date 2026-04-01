#!/usr/bin/env bash

wt_core_usage() {
  cat <<'EOF'
usage:
  worktree-task <command> [options]

commands:
  launch    Create a linked task worktree and optionally open it in tmux
  reclaim   Remove a linked task worktree created by this skill
EOF
}

wt_core_launch_usage() {
  cat <<'EOF'
usage:
  worktree-task launch --title TITLE [options]

options:
  --cwd PATH            Target repository path. Default: current directory
  --task-slug VALUE     Slug prefix for the worktree directory and prompt file
  --branch VALUE        Explicit branch name. Default: WT_POLICY_BRANCH_PREFIX + slug
  --base-ref VALUE      Base ref for the new branch. Default: primary worktree HEAD
  --prompt-file FILE    Read the cleaned-up task prompt from FILE instead of stdin
  --provider VALUE      Provider name or path. Builtins: none, tmux-agent
  --provider-mode MODE  off, auto, or required
  --workspace NAME      Provider workspace/session namespace override
  --session-name NAME   Force a specific tmux session name for tmux-agent
  --variant MODE        Provider variant override: auto, light, or dark
  --no-attach           Prepare the runtime target without switching/attaching
EOF
}

wt_core_reclaim_usage() {
  cat <<'EOF'
usage:
  worktree-task reclaim [options]

options:
  --cwd PATH            Repository or task worktree path. Default: current directory
  --task-slug VALUE     Reclaim WT_POLICY_WORKTREE_DIR/VALUE from the resolved repo family
  --worktree-root PATH  Reclaim a specific linked task worktree
  --provider VALUE      Provider name or path. Builtins: none, tmux-agent
  --provider-mode MODE  off, auto, or required
  --force               Reclaim even when the task worktree has local changes
  --keep-branch         Keep the task branch even if it is already merged
EOF
}

wt_core_reset_provider_result() {
  WT_PROVIDER_RESULT_SESSION_NAME=""
  WT_PROVIDER_RESULT_WINDOW_ID=""
  WT_PROVIDER_RESULT_ATTACHED=""
  WT_PROVIDER_RESULT_VARIANT=""
  WT_PROVIDER_RESULT_WINDOWS_CLOSED=""
}

wt_core_parse_provider_result() {
  local result_file="${1:?missing result file}"
  local key=""
  local value=""

  wt_core_reset_provider_result

  while IFS=$'\t' read -r key value; do
    case "$key" in
      session_name)
        WT_PROVIDER_RESULT_SESSION_NAME="$value"
        ;;
      window_id)
        WT_PROVIDER_RESULT_WINDOW_ID="$value"
        ;;
      attached)
        WT_PROVIDER_RESULT_ATTACHED="$value"
        ;;
      variant)
        WT_PROVIDER_RESULT_VARIANT="$value"
        ;;
      windows_closed)
        WT_PROVIDER_RESULT_WINDOWS_CLOSED="$value"
        ;;
    esac
  done < <(wt_parse_kv_file "$result_file")
}

wt_core_resolve_repo_context() {
  WT_RESOLVED_CWD="$(wt_abs_path "${1:-$PWD}")"

  if ! wt_git_in_repo "$WT_RESOLVED_CWD"; then
    wt_die "target path is not in a git repository: $WT_RESOLVED_CWD"
  fi

  WT_REPO_ROOT="$(wt_git_repo_root "$WT_RESOLVED_CWD")"
  WT_REPO_COMMON_DIR="$(wt_git_common_dir "$WT_RESOLVED_CWD")"
  WT_MAIN_WORKTREE_ROOT="$(wt_git_main_root "$WT_REPO_COMMON_DIR" || true)"
  if [[ -z "$WT_MAIN_WORKTREE_ROOT" || ! -d "$WT_MAIN_WORKTREE_ROOT" ]]; then
    WT_MAIN_WORKTREE_ROOT="$WT_REPO_ROOT"
  fi
  WT_REPO_LABEL="$(wt_git_repo_label "$WT_MAIN_WORKTREE_ROOT")"
}

wt_core_apply_launch_overrides() {
  local provider_override="${1:-}"
  local provider_mode_override="${2:-}"
  local workspace_override="${3:-}"
  local session_name_override="${4:-}"
  local variant_override="${5:-}"
  local attach_override="${6:-}"

  [[ -n "$provider_override" ]] && WT_PROVIDER="$provider_override"
  [[ -n "$provider_mode_override" ]] && WT_PROVIDER_MODE="$provider_mode_override"
  [[ -n "$workspace_override" ]] && WT_PROVIDER_WORKSPACE="$workspace_override"
  [[ -n "$session_name_override" ]] && WT_PROVIDER_SESSION_NAME_OVERRIDE="$session_name_override"
  [[ -n "$variant_override" ]] && WT_PROVIDER_DEFAULT_VARIANT="$variant_override"
  [[ -n "$attach_override" ]] && WT_PROVIDER_ATTACH_DEFAULT="$attach_override"
  return 0
}

wt_core_apply_reclaim_overrides() {
  local provider_override="${1:-}"
  local provider_mode_override="${2:-}"

  [[ -n "$provider_override" ]] && WT_PROVIDER="$provider_override"
  [[ -n "$provider_mode_override" ]] && WT_PROVIDER_MODE="$provider_mode_override"
  return 0
}

wt_core_resolve_policy_paths() {
  WT_POLICY_WORKTREE_DIR_ABS="$(wt_config_resolve_under_repo_parent "$(wt_config_expand_repo_tokens "$WT_POLICY_WORKTREE_DIR")")"
  WT_POLICY_METADATA_DIR_ABS="$(wt_config_resolve_under_repo_parent "$(wt_config_expand_repo_tokens "$WT_POLICY_METADATA_DIR")")"

  WT_PROVIDER_TMUX_CONFIG_FILE_ABS=""
  if [[ -n "$WT_PROVIDER_TMUX_CONFIG_FILE" ]]; then
    WT_PROVIDER_TMUX_CONFIG_FILE_ABS="$(wt_config_resolve_under_main_root "$WT_PROVIDER_TMUX_CONFIG_FILE")"
  fi
}

wt_core_provider_prompt_dir() {
  printf '%s/worktree-task-prompts\n' "${TMPDIR:-/tmp}"
}

wt_core_provider_prompt_path() {
  local task_slug="${1:?missing task slug}"
  printf '%s/%s-%s.txt\n' "$(wt_core_provider_prompt_dir)" "$(wt_hash "$WT_REPO_COMMON_DIR")" "$task_slug"
}

wt_core_provider_command() {
  wt_provider_resolve_command "$WT_SKILL_SCRIPTS_DIR" "${1:?missing provider name}"
}

wt_core_export_provider_env() {
  export WT_REPO_ROOT
  export WT_REPO_COMMON_DIR
  export WT_MAIN_WORKTREE_ROOT
  export WT_REPO_LABEL
  export WT_WORKTREE_PATH
  export WT_BRANCH_NAME
  export WT_TASK_SLUG
  export WT_PROMPT_FILE
  export WT_RUNTIME_WORKSPACE
  export WT_RUNTIME_VARIANT
  export WT_RUNTIME_ATTACH
  export WT_PROVIDER_TMUX_CONFIG_FILE_ABS
  export WT_PROVIDER_AGENT_BOOTSTRAP
  export WT_PROVIDER_AGENT_COMMAND
  export WT_PROVIDER_AGENT_COMMAND_LIGHT
  export WT_PROVIDER_AGENT_COMMAND_DARK
  export WT_PROVIDER_AGENT_PROMPT_FLAG
  export WT_PROVIDER_LOGIN_SHELL
  export WT_PROVIDER_SESSION_NAME_OVERRIDE
  export WT_PROVIDER_SESSION_NAME
  export WT_PROVIDER_WINDOW_ID
}

wt_core_run_provider() {
  local provider_name="${1:?missing provider name}"
  local verb="${2:?missing provider verb}"
  local result_file=""
  local provider_cmd=""
  local status=0

  provider_cmd="$(wt_core_provider_command "$provider_name" 2>/dev/null || true)"
  if [[ -z "$provider_cmd" ]]; then
    return 10
  fi

  result_file="$(mktemp "${TMPDIR:-/tmp}/worktree-task-provider.XXXXXX")"
  export WT_RESULT_FILE="$result_file"
  wt_core_export_provider_env

  if "$provider_cmd" "$verb"; then
    :
  else
    status=$?
    rm -f "$result_file"
    return "$status"
  fi

  wt_core_parse_provider_result "$result_file"
  rm -f "$result_file"
  return 0
}

wt_core_prepare_launch_provider() {
  WT_SELECTED_PROVIDER="$WT_PROVIDER"

  case "$WT_PROVIDER_MODE" in
    off)
      WT_SELECTED_PROVIDER="none"
      return 0
      ;;
    auto|required)
      ;;
    *)
      wt_die "invalid provider mode: $WT_PROVIDER_MODE"
      ;;
  esac

  if wt_core_run_provider "$WT_SELECTED_PROVIDER" validate; then
    return 0
  fi

  if [[ "$WT_PROVIDER_MODE" == "auto" && "$WT_SELECTED_PROVIDER" != "none" ]]; then
    WT_SELECTED_PROVIDER="none"
    return 0
  fi

  wt_die "provider validation failed: $WT_SELECTED_PROVIDER"
}

wt_core_run_launch_provider() {
  local status=0

  if wt_core_run_provider "$WT_SELECTED_PROVIDER" launch; then
    return 0
  else
    status=$?
  fi

  if [[ "$WT_PROVIDER_MODE" == "auto" && "$WT_SELECTED_PROVIDER" != "none" ]]; then
    WT_SELECTED_PROVIDER="none"
    wt_core_run_provider "$WT_SELECTED_PROVIDER" launch
    return $?
  fi

  return "$status"
}

wt_core_rollback_launch_failure() {
  local worktree_created="${1:-0}"
  local branch_created="${2:-0}"
  local provider_prompt_created="${3:-0}"

  rm -f "$WT_MANIFEST_FILE" 2>/dev/null || true

  if [[ "$WT_SELECTED_PROVIDER" != "none" ]]; then
    wt_core_run_provider "$WT_SELECTED_PROVIDER" cleanup >/dev/null 2>&1 || true
  fi

  if [[ "$provider_prompt_created" == "1" && -n "${WT_PROMPT_FILE:-}" && -f "$WT_PROMPT_FILE" ]]; then
    rm -f "$WT_PROMPT_FILE"
  fi

  if [[ "$worktree_created" == "1" && -d "$WT_WORKTREE_PATH" ]]; then
    git -C "$WT_MAIN_WORKTREE_ROOT" worktree remove -f "$WT_WORKTREE_PATH" >/dev/null 2>&1 || true
  fi

  if [[ "$branch_created" == "1" && -n "$WT_BRANCH_NAME" ]]; then
    git -C "$WT_MAIN_WORKTREE_ROOT" branch -D "$WT_BRANCH_NAME" >/dev/null 2>&1 || true
  fi

  rmdir "$WT_POLICY_METADATA_DIR_ABS" 2>/dev/null || true
  rmdir "$WT_POLICY_WORKTREE_DIR_ABS" 2>/dev/null || true
}

wt_core_read_prompt() {
  local prompt_file="${1:-}"
  local prompt_content=""

  if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || wt_die "prompt file does not exist: $prompt_file"
    prompt_content="$(< "$prompt_file")"
  else
    [[ ! -t 0 ]] || wt_die "pipe the cleaned-up task prompt on stdin or use --prompt-file"
    prompt_content="$(cat)"
  fi

  if [[ -z "${prompt_content//[[:space:]]/}" ]]; then
    wt_die "task prompt is empty"
  fi

  printf '%s\n' "$prompt_content"
}

wt_core_emit_launch_result() {
  printf 'branch_name=%s\n' "$WT_BRANCH_NAME"
  printf 'worktree_path=%s\n' "$WT_WORKTREE_PATH"
  printf 'manifest_file=%s\n' "$WT_MANIFEST_FILE"
  printf 'provider=%s\n' "$WT_SELECTED_PROVIDER"
  if [[ -n "$WT_PROVIDER_RESULT_SESSION_NAME" ]]; then
    printf 'session_name=%s\n' "$WT_PROVIDER_RESULT_SESSION_NAME"
  fi
  if [[ -n "$WT_PROVIDER_RESULT_WINDOW_ID" ]]; then
    printf 'window_id=%s\n' "$WT_PROVIDER_RESULT_WINDOW_ID"
  fi
}

wt_core_emit_reclaim_result() {
  printf 'worktree_path=%s\n' "$WT_WORKTREE_PATH"
  printf 'branch_name=%s\n' "$WT_BRANCH_NAME"
  printf 'manifest_file=%s\n' "$WT_MANIFEST_FILE"
  printf 'provider=%s\n' "$WT_SELECTED_PROVIDER"
  printf 'provider_cleanup_status=%s\n' "$WT_PROVIDER_CLEANUP_STATUS"
  printf 'tmux_windows_closed=%s\n' "${WT_PROVIDER_RESULT_WINDOWS_CLOSED:-0}"
  printf 'branch_deleted=%s\n' "$WT_BRANCH_DELETED"
  printf 'branch_delete_reason=%s\n' "$WT_BRANCH_DELETE_REASON"
}

wt_core_launch() {
  local cwd="$PWD"
  local task_title=""
  local task_slug=""
  local branch_name=""
  local base_ref=""
  local prompt_file=""
  local provider_override=""
  local provider_mode_override=""
  local workspace_override=""
  local session_name_override=""
  local variant_override=""
  local attach_override=""
  local prompt_content=""
  local base_slug=""
  local resolved_slug=""
  local suffix=1
  local path_suffix=1
  local worktree_created=0
  local branch_created=0
  local provider_prompt_created=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        cwd="$2"
        shift 2
        ;;
      --title)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        task_title="$2"
        shift 2
        ;;
      --task-slug)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        task_slug="$2"
        shift 2
        ;;
      --branch)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        branch_name="$2"
        shift 2
        ;;
      --base-ref)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        base_ref="$2"
        shift 2
        ;;
      --prompt-file)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        prompt_file="$2"
        shift 2
        ;;
      --provider)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        provider_override="$2"
        shift 2
        ;;
      --provider-mode)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        provider_mode_override="$2"
        shift 2
        ;;
      --workspace)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        workspace_override="$2"
        shift 2
        ;;
      --session-name)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        session_name_override="$2"
        shift 2
        ;;
      --variant)
        [[ $# -ge 2 ]] || { wt_core_launch_usage; exit 1; }
        variant_override="$2"
        shift 2
        ;;
      --no-attach)
        attach_override="0"
        shift
        ;;
      -h|--help)
        wt_core_launch_usage
        exit 0
        ;;
      *)
        wt_core_launch_usage
        exit 1
        ;;
    esac
  done

  [[ -n "$task_title" ]] || { wt_core_launch_usage; exit 1; }

  wt_core_resolve_repo_context "$cwd"
  wt_config_load
  wt_core_apply_launch_overrides "$provider_override" "$provider_mode_override" "$workspace_override" "$session_name_override" "$variant_override" "$attach_override"
  wt_core_resolve_policy_paths

  if [[ -z "$base_ref" ]]; then
    case "$WT_POLICY_BASE_REF_STRATEGY" in
      primary-head)
        base_ref="$(git -C "$WT_MAIN_WORKTREE_ROOT" rev-parse --verify HEAD)"
        ;;
      *)
        wt_die "unsupported base ref strategy: $WT_POLICY_BASE_REF_STRATEGY"
        ;;
    esac
  fi

  prompt_content="$(wt_core_read_prompt "$prompt_file")"

  base_slug="$(wt_slugify "${task_slug:-$task_title}" "$WT_POLICY_SLUG_FALLBACK")"
  resolved_slug="$base_slug"

  if [[ -z "$branch_name" ]]; then
    while [[ -e "$WT_POLICY_WORKTREE_DIR_ABS/$resolved_slug" ]] || wt_git_branch_exists "$WT_MAIN_WORKTREE_ROOT" "${WT_POLICY_BRANCH_PREFIX}${resolved_slug}"; do
      suffix=$((suffix + 1))
      resolved_slug="${base_slug}-${suffix}"
    done
    WT_BRANCH_NAME="${WT_POLICY_BRANCH_PREFIX}${resolved_slug}"
  else
    while [[ -e "$WT_POLICY_WORKTREE_DIR_ABS/$resolved_slug" ]]; do
      path_suffix=$((path_suffix + 1))
      resolved_slug="${base_slug}-${path_suffix}"
    done
    WT_BRANCH_NAME="$branch_name"
  fi

  WT_TASK_SLUG="$resolved_slug"
  WT_WORKTREE_PATH="$WT_POLICY_WORKTREE_DIR_ABS/$WT_TASK_SLUG"
  WT_PROMPT_FILE=""
  WT_MANIFEST_FILE="$(wt_manifest_path "$WT_POLICY_METADATA_DIR_ABS" "$WT_TASK_SLUG")"

  WT_RUNTIME_WORKSPACE="$WT_PROVIDER_WORKSPACE"
  WT_RUNTIME_VARIANT="$WT_PROVIDER_DEFAULT_VARIANT"
  WT_RUNTIME_ATTACH="$WT_PROVIDER_ATTACH_DEFAULT"
  WT_PROVIDER_SESSION_NAME=""
  WT_PROVIDER_WINDOW_ID=""

  wt_core_prepare_launch_provider

  mkdir -p "$WT_POLICY_WORKTREE_DIR_ABS" "$WT_POLICY_METADATA_DIR_ABS"

  if [[ -d "$WT_WORKTREE_PATH" ]]; then
    if ! wt_git_in_repo "$WT_WORKTREE_PATH"; then
      wt_die "worktree path already exists and is not a git worktree: $WT_WORKTREE_PATH"
    fi

    if [[ "$(wt_git_common_dir "$WT_WORKTREE_PATH" || true)" != "$WT_REPO_COMMON_DIR" ]]; then
      wt_die "worktree path already belongs to another repo family: $WT_WORKTREE_PATH"
    fi
  else
    worktree_created=1
    if wt_git_branch_exists "$WT_MAIN_WORKTREE_ROOT" "$WT_BRANCH_NAME"; then
      git -C "$WT_MAIN_WORKTREE_ROOT" worktree add "$WT_WORKTREE_PATH" "$WT_BRANCH_NAME"
    else
      branch_created=1
      git -C "$WT_MAIN_WORKTREE_ROOT" worktree add -b "$WT_BRANCH_NAME" "$WT_WORKTREE_PATH" "$base_ref"
    fi
  fi

  if [[ "$WT_SELECTED_PROVIDER" != "none" ]]; then
    WT_PROMPT_FILE="$(wt_core_provider_prompt_path "$WT_TASK_SLUG")"
    mkdir -p "$(wt_core_provider_prompt_dir)"
    printf '%s\n' "$prompt_content" > "$WT_PROMPT_FILE"
    provider_prompt_created=1
  fi

  if wt_core_run_launch_provider; then
    :
  else
    wt_core_rollback_launch_failure "$worktree_created" "$branch_created" "$provider_prompt_created"
    wt_die "provider launch failed: $WT_SELECTED_PROVIDER"
  fi

  if [[ "$WT_SELECTED_PROVIDER" == "none" && -n "${WT_PROMPT_FILE:-}" && -f "$WT_PROMPT_FILE" ]]; then
    rm -f "$WT_PROMPT_FILE"
    WT_PROMPT_FILE=""
  fi

  if [[ -n "$WT_PROVIDER_RESULT_SESSION_NAME" ]]; then
    WT_PROVIDER_SESSION_NAME="$WT_PROVIDER_RESULT_SESSION_NAME"
  fi
  if [[ -n "$WT_PROVIDER_RESULT_WINDOW_ID" ]]; then
    WT_PROVIDER_WINDOW_ID="$WT_PROVIDER_RESULT_WINDOW_ID"
  fi

  wt_manifest_write \
    "$WT_MANIFEST_FILE" \
    "$WT_TASK_SLUG" \
    "$WT_REPO_COMMON_DIR" \
    "$WT_MAIN_WORKTREE_ROOT" \
    "$WT_WORKTREE_PATH" \
    "$WT_BRANCH_NAME" \
    "$WT_SELECTED_PROVIDER" \
    "$WT_PROVIDER_RESULT_SESSION_NAME" \
    "$WT_PROVIDER_RESULT_WINDOW_ID"

  wt_core_emit_launch_result

  if wt_bool_is_true "$WT_RUNTIME_ATTACH"; then
    wt_core_run_provider "$WT_SELECTED_PROVIDER" attach >/dev/null || wt_die "provider attach failed: $WT_SELECTED_PROVIDER"
  fi
}

wt_core_reclaim() {
  local cwd="$PWD"
  local task_slug=""
  local worktree_root=""
  local provider_override=""
  local provider_mode_override=""
  local force_mode="0"
  local keep_branch="0"
  local context_path=""
  local manifest_provider=""
  local manifest_session_name=""
  local manifest_window_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cwd)
        [[ $# -ge 2 ]] || { wt_core_reclaim_usage; exit 1; }
        cwd="$2"
        shift 2
        ;;
      --task-slug)
        [[ $# -ge 2 ]] || { wt_core_reclaim_usage; exit 1; }
        task_slug="$2"
        shift 2
        ;;
      --worktree-root)
        [[ $# -ge 2 ]] || { wt_core_reclaim_usage; exit 1; }
        worktree_root="$2"
        shift 2
        ;;
      --provider)
        [[ $# -ge 2 ]] || { wt_core_reclaim_usage; exit 1; }
        provider_override="$2"
        shift 2
        ;;
      --provider-mode)
        [[ $# -ge 2 ]] || { wt_core_reclaim_usage; exit 1; }
        provider_mode_override="$2"
        shift 2
        ;;
      --force)
        force_mode="1"
        shift
        ;;
      --keep-branch)
        keep_branch="1"
        shift
        ;;
      -h|--help)
        wt_core_reclaim_usage
        exit 0
        ;;
      *)
        wt_core_reclaim_usage
        exit 1
        ;;
    esac
  done

  if [[ -n "$task_slug" && -n "$worktree_root" ]]; then
    wt_die "use either --task-slug or --worktree-root, not both"
  fi

  if [[ -n "$worktree_root" ]]; then
    [[ -d "$worktree_root" ]] || wt_die "task worktree does not exist: $worktree_root"
    context_path="$worktree_root"
  else
    context_path="$cwd"
  fi
  wt_core_resolve_repo_context "$context_path"
  wt_config_load
  wt_core_apply_reclaim_overrides "$provider_override" "$provider_mode_override"
  wt_core_resolve_policy_paths

  if [[ -n "$worktree_root" ]]; then
    WT_WORKTREE_PATH="$(wt_abs_path "$worktree_root")"
  elif [[ -n "$task_slug" ]]; then
    WT_WORKTREE_PATH="$WT_POLICY_WORKTREE_DIR_ABS/$task_slug"
  else
    WT_WORKTREE_PATH="$WT_REPO_ROOT"
  fi

  if [[ "$WT_WORKTREE_PATH" == "$WT_MAIN_WORKTREE_ROOT" ]]; then
    wt_die "refusing to reclaim the primary worktree; use --task-slug or --worktree-root for a linked task worktree"
  fi

  case "$WT_WORKTREE_PATH" in
    "$WT_POLICY_WORKTREE_DIR_ABS"/*)
      ;;
    *)
      wt_die "target worktree is not under the skill-managed task directory: $WT_WORKTREE_PATH"
      ;;
  esac

  [[ -d "$WT_WORKTREE_PATH" ]] || wt_die "task worktree does not exist: $WT_WORKTREE_PATH"
  wt_git_in_repo "$WT_WORKTREE_PATH" || wt_die "task worktree is not a git worktree: $WT_WORKTREE_PATH"

  if [[ "$(wt_git_common_dir "$WT_WORKTREE_PATH" || true)" != "$WT_REPO_COMMON_DIR" ]]; then
    wt_die "task worktree belongs to another repo family: $WT_WORKTREE_PATH"
  fi

  WT_TASK_SLUG="$(basename "$WT_WORKTREE_PATH")"
  WT_PROMPT_FILE="$(wt_core_provider_prompt_path "$WT_TASK_SLUG")"
  WT_MANIFEST_FILE="$(wt_manifest_path "$WT_POLICY_METADATA_DIR_ABS" "$WT_TASK_SLUG")"
  WT_BRANCH_NAME="$(git -C "$WT_WORKTREE_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  if [[ -f "$WT_MANIFEST_FILE" ]]; then
    manifest_provider="$(wt_manifest_read_field "$WT_MANIFEST_FILE" provider || true)"
    manifest_session_name="$(wt_manifest_read_field "$WT_MANIFEST_FILE" provider_session_name || true)"
    manifest_window_id="$(wt_manifest_read_field "$WT_MANIFEST_FILE" provider_window_id || true)"
  fi

  if [[ "$force_mode" != "1" ]]; then
    if [[ -n "$(git -C "$WT_WORKTREE_PATH" status --porcelain --untracked-files=all)" ]]; then
      wt_die "task worktree has uncommitted changes; rerun with --force to discard them"
    fi
  fi

  WT_SELECTED_PROVIDER="${provider_override:-${manifest_provider:-$WT_PROVIDER}}"
  WT_PROVIDER_CLEANUP_STATUS="skipped"
  WT_PROVIDER_SESSION_NAME="$manifest_session_name"
  WT_PROVIDER_WINDOW_ID="$manifest_window_id"
  WT_RUNTIME_ATTACH="0"
  WT_RUNTIME_VARIANT="$WT_PROVIDER_DEFAULT_VARIANT"
  WT_RUNTIME_WORKSPACE="$WT_PROVIDER_WORKSPACE"

  if [[ -z "$WT_SELECTED_PROVIDER" ]]; then
    WT_SELECTED_PROVIDER="none"
  fi

  case "$WT_PROVIDER_MODE" in
    off)
      WT_SELECTED_PROVIDER="none"
      ;;
    auto|required)
      ;;
    *)
      wt_die "invalid provider mode: $WT_PROVIDER_MODE"
      ;;
  esac

  if [[ "$WT_SELECTED_PROVIDER" != "none" ]]; then
    if wt_core_run_provider "$WT_SELECTED_PROVIDER" cleanup; then
      WT_PROVIDER_CLEANUP_STATUS="ok"
    else
      case "$?" in
        10)
          WT_PROVIDER_CLEANUP_STATUS="unavailable"
          ;;
        *)
          WT_PROVIDER_CLEANUP_STATUS="failed"
          ;;
      esac
    fi
  fi

  if [[ "$force_mode" == "1" ]]; then
    git -C "$WT_MAIN_WORKTREE_ROOT" worktree remove -f "$WT_WORKTREE_PATH"
  else
    git -C "$WT_MAIN_WORKTREE_ROOT" worktree remove "$WT_WORKTREE_PATH"
  fi

  if [[ -f "$WT_PROMPT_FILE" ]]; then
    rm -f "$WT_PROMPT_FILE"
  fi

  if [[ -f "$WT_MANIFEST_FILE" ]]; then
    rm -f "$WT_MANIFEST_FILE"
  fi

  rmdir "$WT_POLICY_METADATA_DIR_ABS" 2>/dev/null || true
  rmdir "$WT_POLICY_WORKTREE_DIR_ABS" 2>/dev/null || true

  WT_BRANCH_DELETED="no"
  WT_BRANCH_DELETE_REASON="kept"
  if [[ "$keep_branch" == "1" ]]; then
    WT_BRANCH_DELETE_REASON="kept-by-option"
  elif [[ -z "$WT_BRANCH_NAME" ]]; then
    WT_BRANCH_DELETE_REASON="detached-head"
  elif git -C "$WT_MAIN_WORKTREE_ROOT" merge-base --is-ancestor "$WT_BRANCH_NAME" HEAD 2>/dev/null; then
    if git -C "$WT_MAIN_WORKTREE_ROOT" branch -d "$WT_BRANCH_NAME" >/dev/null 2>&1; then
      WT_BRANCH_DELETED="yes"
      WT_BRANCH_DELETE_REASON="merged"
    else
      WT_BRANCH_DELETE_REASON="delete-failed"
    fi
  else
    WT_BRANCH_DELETE_REASON="not-merged"
  fi

  wt_core_emit_reclaim_result
}
