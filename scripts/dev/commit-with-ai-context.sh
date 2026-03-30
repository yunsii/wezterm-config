#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/dev/commit-with-ai-context.sh [options]

Build a conventional commit message with an optional AI Collaboration block,
preview it, and require explicit confirmation before running git commit.

Required:
  --type <type>                  conventional commit type
  --description <text>           commit title description

Optional:
  --scope <scope>                conventional commit scope
  --body <text>                  add one body paragraph line; repeatable
  --body-file <path>             append body text from a file
  --write-message-file <path>    write the validated commit message to a file
                                  use auto for /tmp/codex-commit-msg-<repo>-<branch>.txt
  --human-adjustments <count>    meaningful human adjustments, excluding escalation-only interactions
  --hard-part <text>             summarize a debugging challenge or missed constraint; repeatable
  --ai-complexity <level>        one of: low, medium, high
  --tool-used <name>             tool or MCP used materially; repeatable
  --skill-used <name>            skill used materially; repeatable
  --print-only                   preview the message and exit without committing
  --help                         show this help

Examples:
  scripts/dev/commit-with-ai-context.sh \
    --type feat \
    --scope auth \
    --description "add session timeout warning" \
    --body "Warn users before idle sessions expire to reduce surprise logouts." \
    --write-message-file auto \
    --human-adjustments 1 \
    --ai-complexity low \
    --tool-used apply_patch \
    --print-only
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

join_by_comma() {
  local output=""
  local item

  for item in "$@"; do
    if [[ -n "$output" ]]; then
      output+=", "
    fi
    output+="$item"
  done

  printf '%s' "$output"
}

ensure_git_repo() {
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  repo_name="$(basename "$repo_root")"
  branch_name="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  if [[ -z "$branch_name" ]]; then
    branch_name="detached-$(git rev-parse --short HEAD 2>/dev/null)" || die "failed to resolve detached HEAD commit"
  fi
}

validate_complexity() {
  case "$1" in
    low|medium|high) ;;
    *)
      die "invalid --ai-complexity: $1"
      ;;
  esac
}

slugify_name() {
  local raw_value="$1"
  local fallback="$2"
  local slug

  slug="$(printf '%s' "$raw_value" | tr -cs 'A-Za-z0-9._-' '-')"
  slug="${slug#-}"
  slug="${slug%-}"

  if [[ -z "$slug" ]]; then
    slug="$fallback"
  fi

  printf '%s' "$slug"
}

repo_temp_message_file() {
  local temp_root="${TMPDIR:-/tmp}"
  local repo_slug
  local branch_slug

  repo_slug="$(slugify_name "$repo_name" "repo")"
  branch_slug="$(slugify_name "$branch_name" "branch")"

  printf '%s/codex-commit-msg-%s-%s.txt' "$temp_root" "$repo_slug" "$branch_slug"
}

resolve_write_message_file() {
  if [[ -z "$write_message_file" ]]; then
    resolved_write_message_file=""
    return
  fi

  if [[ "$write_message_file" == "auto" ]]; then
    resolved_write_message_file="$(repo_temp_message_file)"
    return
  fi

  resolved_write_message_file="$write_message_file"
}

type=""
scope=""
description=""
body_lines=()
body_file=""
write_message_file=""
resolved_write_message_file=""
human_adjustments=""
hard_parts=()
ai_complexity=""
tools_used=()
skills_used=()
print_only=0
repo_root=""
repo_name=""
branch_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)
      [[ $# -ge 2 ]] || die "missing value for --type"
      type="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || die "missing value for --scope"
      scope="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || die "missing value for --description"
      description="$2"
      shift 2
      ;;
    --body)
      [[ $# -ge 2 ]] || die "missing value for --body"
      body_lines+=("$2")
      shift 2
      ;;
    --body-file)
      [[ $# -ge 2 ]] || die "missing value for --body-file"
      body_file="$2"
      shift 2
      ;;
    --write-message-file)
      [[ $# -ge 2 ]] || die "missing value for --write-message-file"
      write_message_file="$2"
      shift 2
      ;;
    --human-adjustments)
      [[ $# -ge 2 ]] || die "missing value for --human-adjustments"
      human_adjustments="$2"
      shift 2
      ;;
    --hard-part)
      [[ $# -ge 2 ]] || die "missing value for --hard-part"
      hard_parts+=("$2")
      shift 2
      ;;
    --ai-complexity)
      [[ $# -ge 2 ]] || die "missing value for --ai-complexity"
      ai_complexity="$2"
      shift 2
      ;;
    --tool-used)
      [[ $# -ge 2 ]] || die "missing value for --tool-used"
      tools_used+=("$2")
      shift 2
      ;;
    --skill-used)
      [[ $# -ge 2 ]] || die "missing value for --skill-used"
      skills_used+=("$2")
      shift 2
      ;;
    --print-only)
      print_only=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$type" ]] || die "--type is required"
[[ -n "$description" ]] || die "--description is required"

ensure_git_repo

if [[ -n "$body_file" ]]; then
  [[ -f "$body_file" ]] || die "body file not found: $body_file"
fi

if [[ -n "$human_adjustments" ]] && [[ ! "$human_adjustments" =~ ^[0-9]+$ ]]; then
  die "--human-adjustments must be a non-negative integer"
fi

if [[ -n "$ai_complexity" ]]; then
  validate_complexity "$ai_complexity"
fi

resolve_write_message_file

title="$type"
if [[ -n "$scope" ]]; then
  title+="($scope)"
fi
title+=": $description"

message="$title"

if (( ${#body_lines[@]} > 0 )) || [[ -n "$body_file" ]]; then
  message+=$'\n\n'

  if (( ${#body_lines[@]} > 0 )); then
    for line in "${body_lines[@]}"; do
      message+="$line"$'\n'
    done
  fi

  if [[ -n "$body_file" ]]; then
    message+="$(<"$body_file")"$'\n'
  fi

  message="${message%$'\n'}"
fi

has_ai_block=0
if [[ -n "$human_adjustments" ]] || (( ${#hard_parts[@]} > 0 )) || [[ -n "$ai_complexity" ]] || (( ${#tools_used[@]} > 0 )) || (( ${#skills_used[@]} > 0 )); then
  has_ai_block=1
fi

if (( has_ai_block )); then
  message+=$'\n\nAI Collaboration:\n'

  if [[ -n "$human_adjustments" ]]; then
    message+="- human-adjustments: $human_adjustments (excluding escalation-only interactions)"$'\n'
  fi

  if (( ${#hard_parts[@]} > 0 )); then
    for item in "${hard_parts[@]}"; do
      message+="- hard-parts: $item"$'\n'
    done
  fi

  if [[ -n "$ai_complexity" ]]; then
    message+="- ai-complexity: $ai_complexity"$'\n'
  fi

  if (( ${#tools_used[@]} > 0 )); then
    message+="- tools-used: $(join_by_comma "${tools_used[@]}")"$'\n'
  fi

  if (( ${#skills_used[@]} > 0 )); then
    message+="- skills-used: $(join_by_comma "${skills_used[@]}")"$'\n'
  fi

  message="${message%$'\n'}"
fi

printf '%s\n' "----- commit message preview -----"
printf '%s\n' "$message"
printf '%s\n' "----------------------------------"

if [[ -n "$resolved_write_message_file" ]]; then
  mkdir -p "$(dirname "$resolved_write_message_file")"
  printf '%s\n' "$message" >"$resolved_write_message_file"
  printf 'Message file: %s\n' "$resolved_write_message_file"
fi

if (( print_only )); then
  exit 0
fi

printf 'Proceed with git commit? [y/N] '
read -r reply

case "$reply" in
  y|Y|yes|YES)
    if [[ -n "$resolved_write_message_file" ]]; then
      git commit -F "$resolved_write_message_file"
    else
      temp_file="$(mktemp)"
      trap 'rm -f "$temp_file"' EXIT
      printf '%s\n' "$message" >"$temp_file"
      git commit -F "$temp_file"
    fi
    ;;
  *)
    echo "commit cancelled"
    ;;
esac
