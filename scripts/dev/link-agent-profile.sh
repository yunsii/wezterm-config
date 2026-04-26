#!/usr/bin/env bash
# Usage:
#   link-agent-profile.sh [--source <dir>] [--dry-run] [--force]
#
# Symlinks the user-level agent profile into any target directory that
# exists on this machine. Scans <source>/*.md and for each target:
#   ~/.claude/   AGENTS.md -> CLAUDE.md ; topic files keep their name
#   ~/.codex/    AGENTS.md -> AGENTS.md ; topic files keep their name
#
# Host-adapter files use a `<topic>-<host>.md` naming convention. They
# are linked only into the matching host's target and skipped for
# others (e.g. permissions-claude.md goes to ~/.claude/ but not
# ~/.codex/). The host token is the second segment after the topic.
#
# A target whose directory does not exist is skipped silently (well,
# with one "skip" line). Re-running is idempotent: links already
# pointing at the right source report "ok" and are left alone.
#
# Options:
#   --source <dir>   Source profile dir
#                    (default: <repo>/agent-profiles/v1/en)
#   --dry-run        Print actions without touching the filesystem.
#   --force          Replace existing non-link files or links that
#                    point somewhere else. Without --force these show
#                    up as "conflict" and the script keeps going.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
source_dir="$repo_root/agent-profiles/v1/en"
dry_run=0
force=0

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (($#)); do
  case "$1" in
    --source) source_dir="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "$source_dir" ]]; then
  echo "source dir not found: $source_dir" >&2
  exit 1
fi

link_one() {
  local dir=$1 src=$2 dst_name=$3
  local dst="$dir/$dst_name"
  local status src_real cur

  src_real=$(readlink -f "$src")

  if [[ -L "$dst" ]]; then
    cur=$(readlink -f "$dst" 2>/dev/null || true)
    if [[ "$cur" == "$src_real" ]]; then
      status=ok
    elif ((force)); then
      status=replace
    else
      printf '  %-24s conflict (-> %s; use --force)\n' "$dst_name" "$cur"
      return
    fi
  elif [[ -e "$dst" ]]; then
    if ((force)); then
      status=replace
    else
      printf '  %-24s conflict (regular file; use --force)\n' "$dst_name"
      return
    fi
  else
    status=link
  fi

  printf '  %-24s %s\n' "$dst_name" "$status"
  ((dry_run)) && return
  case "$status" in
    ok) ;;
    replace) rm -f "$dst"; ln -s "$src" "$dst" ;;
    link)    ln -s "$src" "$dst" ;;
  esac
}

process_target() {
  local label=$1 dir=$2 entry_name=$3
  if [[ ! -d "$dir" ]]; then
    printf '[%s] %s — not found, skip\n' "$label" "$dir"
    return
  fi
  printf '[%s] %s\n' "$label" "$dir"
  local f base dst_name host_suffix
  # Host adapter convention: <topic>-<host>.md where <host> is a known
  # target label (claude, codex, ...). Topic names that contain hyphens
  # (tool-use.md, platform-actions.md) are NOT host adapters because
  # their suffix does not match a known host.
  local known_hosts=" claude codex "
  for f in "$source_dir"/*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if [[ "$base" =~ -([A-Za-z0-9_]+)\.md$ ]]; then
      host_suffix="${BASH_REMATCH[1]}"
      if [[ "$known_hosts" == *" $host_suffix "* ]]; then
        if [[ "$host_suffix" != "$label" ]]; then
          continue
        fi
      fi
    fi
    if [[ "$base" == "AGENTS.md" ]]; then
      dst_name="$entry_name"
    else
      dst_name="$base"
    fi
    link_one "$dir" "$f" "$dst_name"
  done
}

((dry_run)) && echo "(dry run — no filesystem changes)"

process_target "claude" "$HOME/.claude" "CLAUDE.md"
process_target "codex"  "$HOME/.codex"  "AGENTS.md"
