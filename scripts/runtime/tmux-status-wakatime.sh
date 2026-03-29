#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

WAKA_CACHE="/tmp/.tmux-wakatime-cache"
WAKA_LOCK="/tmp/.tmux-wakatime.lock"
padding="${TMUX_STATUS_PADDING:- }"
separator="${TMUX_STATUS_SEPARATOR:- · }"

if ! command -v wakatime >/dev/null 2>&1; then
  printf '%s%s' "$padding" "$(style 'fg=#7f7a72' 'WakaTime unavailable')"
  exit 0
fi

cached_time=0
waka_json=""

if [[ -f "$WAKA_CACHE" ]]; then
  cached_time="$(head -n 1 "$WAKA_CACHE" 2>/dev/null || printf '0')"
  cached_day="$(epoch_to_day "$cached_time" 2>/dev/null || true)"
  today="$(date +%Y-%m-%d)"

  if [[ "$cached_day" == "$today" ]]; then
    waka_json="$(tail -n +2 "$WAKA_CACHE" 2>/dev/null || true)"
  else
    cached_time=0
  fi
fi

now="$(date +%s)"
age=$(( now - cached_time ))

if [[ -f "$WAKA_LOCK" ]]; then
  lock_mtime="$(file_mtime "$WAKA_LOCK" 2>/dev/null || printf '0')"
  lock_age=$(( now - lock_mtime ))
  if (( lock_age >= 300 )); then
    rm -f "$WAKA_LOCK"
  fi
fi

if (( age >= 60 )) && [[ ! -f "$WAKA_LOCK" ]]; then
  nohup bash -c '
    touch "'"$WAKA_LOCK"'"
    result=$(wakatime --today --output raw-json 2>/dev/null)
    if [[ -n "$result" ]]; then
      printf "%s\n%s" "$(date +%s)" "$result" > "'"$WAKA_CACHE"'"
    fi
    rm -f "'"$WAKA_LOCK"'"
  ' >/dev/null 2>&1 &
fi

if [[ -z "$waka_json" ]]; then
  printf '%s%s%s' \
    "$padding" \
    "$(style 'fg=#7f7a72' 'WakaTime:')" \
    "$(style 'fg=#7f7a72' ' Ready to roll')"
  exit 0
fi

ai="$(printf '%s' "$waka_json" | jq -r '.data.categories[]? | select(.name=="AI Coding") | .text' 2>/dev/null || true)"
code="$(printf '%s' "$waka_json" | jq -r '.data.categories[]? | select(.name=="Coding") | .text' 2>/dev/null || true)"

parts=()

if [[ -n "$ai" && "$ai" != "0 secs" && "$ai" != "null" ]]; then
  parts+=("$(style 'fg=#b9854d' "AI ${ai}")")
fi

if [[ -n "$code" && "$code" != "0 secs" && "$code" != "null" ]]; then
  parts+=("$(style 'fg=#226f73' "Code ${code}")")
fi

if (( ${#parts[@]} == 0 )); then
  printf '%s%s%s' \
    "$padding" \
    "$(style 'fg=#7f7a72' 'WakaTime:')" \
    "$(style 'fg=#7f7a72' ' Ready to roll')"
  exit 0
fi

printf '%s%s' "$padding" "$(style 'fg=#7f7a72' 'WakaTime:')"
printf '%s' "$(style 'fg=#7f7a72' ' ')"
join_with_separator "$(style 'fg=#7f7a72' "$separator")" "${parts[@]}"
