#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

cwd="${1:-$PWD}"

if [[ ! -d "$cwd" ]]; then
  cwd="$PWD"
fi

if ! git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  style 'fg=#7f7a72' 'no-git'
  exit 0
fi

staged=0
unstaged=0
untracked=0
ahead_count=""
behind_count=""
upstream_ref="$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue

  if [[ "$line" == '??'* ]]; then
    ((untracked += 1))
    continue
  fi

  index_status="${line:0:1}"
  worktree_status="${line:1:1}"

  if [[ "$index_status" != " " ]]; then
    ((staged += 1))
  fi

  if [[ "$worktree_status" != " " ]]; then
    ((unstaged += 1))
  fi
done < <(git -C "$cwd" status --porcelain 2>/dev/null || true)

if [[ -n "$upstream_ref" ]]; then
  read -r ahead_count behind_count < <(git -C "$cwd" rev-list --left-right --count "HEAD...${upstream_ref}" 2>/dev/null || printf ' ')
fi

git_changes="(+${staged},~${unstaged},?${untracked}"
if [[ -n "$upstream_ref" ]]; then
  if [[ "$ahead_count" != "0" ]]; then
    git_changes+=",^${ahead_count}"
  fi
  if [[ -n "$behind_count" && "$behind_count" != "0" ]]; then
    git_changes+=",v${behind_count}"
  fi
  if [[ "$ahead_count" == "0" && "${behind_count:-0}" == "0" ]]; then
    git_changes+=",=0"
  fi
else
  git_changes+=",*0"
fi
git_changes+=")"

style 'fg=#9a6631' "$git_changes"
