#!/usr/bin/env bash
set -euo pipefail

# Compare locally installed wezterm / tmux / go against upstream latest and
# the repo's declared floors. Read-only; never modifies anything.
#
# Floors:
#   - tmux:  3.6  (scripts/runtime/tmux-version-lib.sh: tmux_version_at_least 3 6)
#   - go:    1.21 (native/picker/go.mod)
#   - wezterm: no declared floor; reports installed vs latest only.
#
# go is checked only when a `go` binary is on PATH (matches build-picker's
# auto-skip behavior).

usage() {
  cat <<EOF
Usage: $(basename "$0") [--timeout SECONDS] [--no-color] [--advisory] [--prefix STR]

Checks whether locally installed wezterm / tmux / go match upstream latest
and meet the repo's version floors. Skips go if no \`go\` binary is found.

Options:
  --timeout SECONDS  curl timeout per upstream call (default 8).
  --no-color         Disable ANSI colors (auto-disabled when stdout is not a TTY).
  --advisory         Always exit 0; print a trailing reminder line when there
                     is something to act on. Used by sync-runtime so a slow or
                     offline upstream never fails the sync.
  --prefix STR       Prepend STR to every output line (e.g. "[sync] " so the
                     table fits in with sync_trace output).

Exit codes (without --advisory):
  0  All probed tools are at-or-above the latest release (or no upstream
     check possible, e.g. offline).
  1  At least one tool is behind the latest upstream release, or below the
     repo floor.
  2  Argument / runtime error.
EOF
}

timeout_seconds=15
use_color=1
advisory=0
prefix=""
[[ -t 1 ]] || use_color=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout_seconds="${2:-}"; shift 2 ;;
    --no-color) use_color=0; shift ;;
    --advisory) advisory=1; shift ;;
    --prefix) prefix="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

c_reset=""; c_dim=""; c_red=""; c_yellow=""; c_green=""; c_bold=""
if (( use_color )); then
  c_reset=$'\033[0m'
  c_dim=$'\033[2m'
  c_red=$'\033[31m'
  c_yellow=$'\033[33m'
  c_green=$'\033[32m'
  c_bold=$'\033[1m'
fi

fetch() {
  curl -fsSL --max-time "$timeout_seconds" "$@" 2>/dev/null
}

# Compare two dot-separated numeric versions; returns 0 if $1 >= $2.
version_ge() {
  local a="$1" b="$2"
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" == "$b" ]]
}

# Extract a comparable leading version segment.
#   v1.21.0           -> 1.21.0
#   go1.22.0          -> 1.22.0
#   3.6a              -> 3.6
#   20260117-...      -> 20260117   (wezterm calver — first numeric run only)
normalize_version() {
  local v="$1"
  v="${v#v}"
  v="${v#go}"
  v="$(printf '%s' "$v" | grep -oE '^[0-9]+(\.[0-9]+)*' | head -n1)"
  printf '%s' "$v"
}

ANY_BEHIND=0
ANY_FLOOR_VIOLATION=0
declare -A TOOL_BEHIND

emit() {
  printf '%s%s\n' "$prefix" "$1"
}

print_row() {
  # name  installed  latest  floor  status
  local name="$1" installed="$2" latest="$3" floor="$4" status="$5" color="$6"
  emit "$(printf '  %-9s %-26s %-26s %-10s %s%s%s' \
    "$name" "$installed" "$latest" "$floor" "$color" "$status" "$c_reset")"
}

check_tool() {
  local name="$1" installed_raw="$2" latest_raw="$3" floor="$4"

  if [[ -z "$installed_raw" ]]; then
    print_row "$name" "(not installed)" "${latest_raw:-?}" "${floor:--}" "skip" "$c_dim"
    return
  fi
  if [[ -z "$latest_raw" ]]; then
    print_row "$name" "$installed_raw" "(unreachable)" "${floor:--}" "offline?" "$c_yellow"
    return
  fi

  local installed_norm latest_norm
  installed_norm="$(normalize_version "$installed_raw")"
  latest_norm="$(normalize_version "$latest_raw")"

  local status color
  if [[ -n "$floor" ]] && ! version_ge "$installed_norm" "$floor"; then
    status="below floor (need >= $floor)"
    color="$c_red"
    ANY_FLOOR_VIOLATION=1
  elif [[ -z "$installed_norm" || -z "$latest_norm" ]]; then
    status="unknown"
    color="$c_yellow"
  elif version_ge "$installed_norm" "$latest_norm"; then
    status="up-to-date"
    color="$c_green"
  else
    status="update available"
    color="$c_yellow"
    ANY_BEHIND=1
    TOOL_BEHIND[$name]=1
  fi
  print_row "$name" "$installed_raw" "$latest_raw" "${floor:--}" "$status" "$color"
}

# --- collect installed versions ---
# wezterm is a Windows app under hybrid-wsl: prefer the Linux binary if a user
# actually installed one, otherwise fall back to wezterm.exe via WSL interop so
# the Windows install on /mnt/<drive>/.../wezterm.exe is reported correctly.
wezterm_installed=""
wezterm_bin=""
if command -v wezterm >/dev/null 2>&1; then
  wezterm_bin="wezterm"
elif command -v wezterm.exe >/dev/null 2>&1; then
  wezterm_bin="wezterm.exe"
fi
if [[ -n "$wezterm_bin" ]]; then
  wezterm_installed="$("$wezterm_bin" --version 2>/dev/null | tr -d '\r' | awk '{print $2}')"
fi

tmux_installed=""
if command -v tmux >/dev/null 2>&1; then
  tmux_installed="$(tmux -V 2>/dev/null | awk '{print $2}')"
fi

# Mirror native/picker/build.sh's discovery chain: PATH, then
# ~/.local/go/bin/go, then /usr/local/go/bin/go. sync-runtime.sh runs in a
# non-interactive shell that may not inherit a user's PATH additions, and the
# repo treats `go` as installed if any of these resolve.
go_bin=""
if command -v go >/dev/null 2>&1; then
  go_bin="$(command -v go)"
elif [[ -x "$HOME/.local/go/bin/go" ]]; then
  go_bin="$HOME/.local/go/bin/go"
elif [[ -x /usr/local/go/bin/go ]]; then
  go_bin="/usr/local/go/bin/go"
fi
go_installed=""
if [[ -n "$go_bin" ]]; then
  go_installed="$("$go_bin" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
fi

# --- fetch upstream latest ---
# WezTerm: hybrid-wsl tracks the nightly build (see docs/setup.md). The
# nightly release has a rolling tag_name "nightly". Don't synthesize a calver
# from release-level timestamps — `updated_at` bumps on any asset re-upload
# even when the bundled binary is unchanged (we observed a 2026-04-25
# `updated_at` paired with a March 31 build inside the installer). Use only
# `target_commitish` (the SHA the API currently advertises) and compare it
# against the SHA suffix the installed binary reports. This avoids the
# "just installed → already behind" false positive driven by metadata noise.
wezterm_latest=""
wezterm_sha=""
if json="$(fetch -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/wezterm/wezterm/releases/tags/nightly)"; then
  wezterm_sha="$(awk -F'"' '/"target_commitish"[[:space:]]*:/ {print $4; exit}' <<<"$json")"
  if [[ -n "$wezterm_sha" ]]; then
    wezterm_latest="nightly@${wezterm_sha:0:8}"
  fi
fi

# tmux: GitHub releases on tmux/tmux. Tags like "3.5a", "3.6".
tmux_latest=""
tmux_release_json=""
if json="$(fetch -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/tmux/tmux/releases/latest)"; then
  tmux_release_json="$json"
  tmux_latest="$(awk -F'"' '/"tag_name"[[:space:]]*:/ {print $4; exit}' <<<"$json")"
fi

# Go: official endpoint returns plain "go1.23.4".
go_latest=""
if [[ -n "$go_installed" ]]; then
  if raw="$(fetch https://go.dev/VERSION?m=text)"; then
    go_latest="$(printf '%s' "$raw" | head -n1 | sed 's/^go//')"
  fi
fi

# --- render ---
emit "$(printf '%sDependency update check%s %s(timeout=%ss)%s' \
  "$c_bold" "$c_reset" "$c_dim" "$timeout_seconds" "$c_reset")"
emit "$(printf '  %-9s %-26s %-26s %-10s %s' "tool" "installed" "latest" "floor" "status")"
emit "$(printf '  %-9s %-26s %-26s %-10s %s' "----" "---------" "------" "-----" "------")"
check_wezterm() {
  # wezterm uses a SHA-based comparison instead of version_ge. The installed
  # calver ends with the build's commit SHA suffix (e.g. ...-577474d8); compare
  # it to target_commitish[:8] from the nightly tag. SHA mismatch is reported
  # as informational ("tracking nightly") rather than "update available", to
  # avoid false positives caused by API metadata churn (re-uploaded assets,
  # etc.). The changelog details still render on mismatch.
  if [[ -z "$wezterm_installed" ]]; then
    print_row "wezterm" "(not installed)" "${wezterm_latest:-?}" "-" "skip" "$c_dim"
    return
  fi
  if [[ -z "$wezterm_latest" || -z "$wezterm_sha" ]]; then
    print_row "wezterm" "$wezterm_installed" "(unreachable)" "-" "offline?" "$c_yellow"
    return
  fi
  local installed_sha8="${wezterm_installed##*-}"
  local latest_sha8="${wezterm_sha:0:8}"
  if [[ "$installed_sha8" == "$latest_sha8" ]]; then
    print_row "wezterm" "$wezterm_installed" "$wezterm_latest" "-" "up-to-date" "$c_green"
  else
    print_row "wezterm" "$wezterm_installed" "$wezterm_latest" "-" "tracking nightly" "$c_dim"
    TOOL_BEHIND[wezterm]=1
  fi
}

check_wezterm
check_tool "tmux"    "$tmux_installed"    "$tmux_latest"    "3.6"
check_tool "go"      "$go_installed"      "$go_latest"      "1.21"

if (( ANY_FLOOR_VIOLATION )); then
  emit "$(printf '%sreminder%s tool below repo floor — see scripts/runtime/tmux-version-lib.sh / native/picker/go.mod' \
    "$c_red" "$c_reset")"
elif (( ANY_BEHIND )); then
  emit "$(printf '%sreminder%s update available — bump the host tool to stay current' \
    "$c_yellow" "$c_reset")"
fi

# --- update details (only for tools marked behind) ---
# Prefer the project's own changelog file when one exists.
#   wezterm: docs/changelog.md on main — extract the "Continuous/Nightly"
#            section since the user is on a nightly.
#   tmux:    CHANGES file on master — extract the section "CHANGES FROM
#            <installed> TO ..." which is exactly the deltas missing from
#            the user's tmux.
#   go:      release notes are split per minor version; just link out.
emit_section() {
  # Print up to $1 non-empty lines from stdin, prefixed with two spaces.
  local max="$1" count=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    emit "  $line"
    if (( ++count >= max )); then break; fi
  done
}

# Fallback summarizer: when the project changelog cannot be located or its
# section is missing, list recent "key" commit titles from the upstream branch.
# Filters out routine commits (docs/, ci/, chore/, dep bumps, version cuts,
# merges) so what remains tends to be feat/fix/perf/refactor entries.
fetch_key_commits() {
  local repo="$1" branch="$2" max="${3:-5}"
  local json
  json="$(fetch -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${repo}/commits?sha=${branch}&per_page=30")" || return 1
  awk -v max="$max" '
    /"message"[[:space:]]*:/ {
      line = $0
      sub(/.*"message"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/(\\n|\\r|").*/, "", line)
      if (line == "") next
      if (line ~ /^(docs?|doc|ci|chore|build|test|tests|style|deps?|dep|typo)[(:]/ ) next
      if (line ~ /^(Update |Bump |Merge |bump |update |merge |Revert )/) next
      if (line ~ /^(release|Release|version|Version)([[:space:]:]|$)/) next
      if (line ~ /^(WIP|wip)/) next
      print "- " line
      if (++n >= max) exit
    }' <<<"$json"
}

emit_wezterm_changes() {
  [[ "${TOOL_BEHIND[wezterm]:-0}" == 1 ]] || return 0
  emit ""
  emit "$(printf '%swezterm%s changelog (continuous/nightly section)' "$c_bold" "$c_reset")"
  local md section
  if md="$(fetch https://raw.githubusercontent.com/wezterm/wezterm/main/docs/changelog.md)"; then
    section="$(awk '
      /^### Continuous\/Nightly[[:space:]]*$/ { capture=1; next }
      capture && /^### / { exit }
      capture && /^#### / { started=1 }
      capture && started { print }
    ' <<<"$md")"
    if [[ -n "$section" ]]; then
      printf '%s\n' "$section" | emit_section 12
    else
      emit "  (changelog section missing; falling back to recent key commits)"
      local commits
      if commits="$(fetch_key_commits wezterm/wezterm main 5)" && [[ -n "$commits" ]]; then
        printf '%s\n' "$commits" | emit_section 5
      else
        emit "  (commits unreachable)"
      fi
    fi
  else
    emit "  (changelog unreachable; falling back to recent key commits)"
    local commits
    if commits="$(fetch_key_commits wezterm/wezterm main 5)" && [[ -n "$commits" ]]; then
      printf '%s\n' "$commits" | emit_section 5
    else
      emit "  (commits unreachable)"
    fi
  fi
  emit "  see https://wezterm.org/changelog.html"
}

emit_tmux_changes() {
  [[ "${TOOL_BEHIND[tmux]:-0}" == 1 ]] || return 0
  emit ""
  emit "$(printf '%stmux%s changelog %s -> %s' "$c_bold" "$c_reset" "$tmux_installed" "$tmux_latest")"
  local changes section
  if changes="$(fetch https://raw.githubusercontent.com/tmux/tmux/master/CHANGES)"; then
    # Sections look like "CHANGES FROM <prev> TO <new>" — capture every
    # section after the user's installed version, stop at next header.
    section="$(awk -v base="$tmux_installed" '
      $0 ~ ("^CHANGES FROM " base " TO ") { capture=1; next }
      capture && /^CHANGES FROM / { exit }
      capture { print }
    ' <<<"$changes")"
    if [[ -n "$section" ]]; then
      printf '%s\n' "$section" | emit_section 8
    else
      emit "  (no \"CHANGES FROM ${tmux_installed} TO ...\" section; falling back to recent key commits)"
      local commits
      if commits="$(fetch_key_commits tmux/tmux master 5)" && [[ -n "$commits" ]]; then
        printf '%s\n' "$commits" | emit_section 5
      else
        emit "  (commits unreachable)"
      fi
    fi
  else
    emit "  (CHANGES file unreachable; falling back to recent key commits)"
    local commits
    if commits="$(fetch_key_commits tmux/tmux master 5)" && [[ -n "$commits" ]]; then
      printf '%s\n' "$commits" | emit_section 5
    else
      emit "  (commits unreachable)"
    fi
  fi
  emit "  see https://github.com/tmux/tmux/blob/master/CHANGES"
}

emit_go_changes() {
  [[ "${TOOL_BEHIND[go]:-0}" == 1 ]] || return 0
  emit ""
  emit "$(printf '%sgo%s release notes %s' "$c_bold" "$c_reset" "$go_latest")"
  local go_minor="${go_latest%.*}"
  emit "  point release: https://go.dev/doc/devel/release#go${go_latest}"
  emit "  major notes:   https://go.dev/doc/go${go_minor}"
}

# Each emit_*_changes self-gates on TOOL_BEHIND; call unconditionally so the
# wezterm "tracking nightly" path (which intentionally doesn't raise
# ANY_BEHIND) still surfaces the changelog summary.
emit_wezterm_changes
emit_tmux_changes
emit_go_changes

if (( advisory )); then
  exit 0
fi
if (( ANY_FLOOR_VIOLATION || ANY_BEHIND )); then
  exit 1
fi
exit 0
