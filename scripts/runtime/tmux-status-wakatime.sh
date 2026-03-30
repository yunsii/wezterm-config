#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/tmux-status-lib.sh"

WAKA_CACHE="${TMUX_STATUS_WAKATIME_CACHE:-/tmp/.tmux-wakatime-cache}"
WAKA_LOCK="${TMUX_STATUS_WAKATIME_LOCK:-/tmp/.tmux-wakatime.lock}"
WAKA_API_URL="${TMUX_STATUS_WAKATIME_API_URL:-https://api.wakatime.com/api/v1/users/current/status_bar/today}"
padding="$(tmux_option_or_env TMUX_STATUS_PADDING @tmux_status_padding ' ')"
separator="$(tmux_option_or_env TMUX_STATUS_SEPARATOR @tmux_status_separator ' · ')"
script_path="$script_dir/tmux-status-wakatime.sh"
repo_root="${WEZTERM_REPO_ROOT:-$(cd "$script_dir/../.." && pwd -P)}"
shared_env_file="${TMUX_STATUS_SHARED_ENV_FILE:-$repo_root/wezterm-x/local/shared.env}"

load_shared_env() {
  if [[ -f "$shared_env_file" ]]; then
    # shellcheck disable=SC1090
    source "$shared_env_file"
  fi
}

load_shared_env
api_key="${TMUX_STATUS_WAKATIME_API_KEY:-${WAKATIME_API_KEY:-}}"

is_wakatime_available() {
  [[ -n "$api_key" ]] && command -v python3 >/dev/null 2>&1
}

emit_wakatime_summary_from_json() {
  python3 - <<'PY'
import json
import os
import sys

try:
    payload = json.loads(os.environ.get("WAKA_JSON", ""))
except json.JSONDecodeError:
    raise SystemExit(1)

categories = {}
for item in payload.get("data", {}).get("categories", []) or []:
    name = item.get("name")
    text = item.get("text")
    if isinstance(name, str) and isinstance(text, str):
        categories[name] = text

print(f"AI\t{categories.get('AI Coding', '')}")
print(f"CODE\t{categories.get('Coding', '')}")
PY
}

fetch_wakatime_summary() {
  WAKATIME_API_URL="$WAKA_API_URL" TMUX_STATUS_WAKATIME_API_KEY="$api_key" python3 - <<'PY'
import base64
import json
import os
import sys
import urllib.error
import urllib.request

api_key = os.environ.get("TMUX_STATUS_WAKATIME_API_KEY", "")
url = os.environ.get("WAKATIME_API_URL", "")

if not api_key or not url:
    raise SystemExit(1)

token = base64.b64encode(api_key.encode("utf-8")).decode("ascii")
request = urllib.request.Request(
    url,
    headers={
        "Authorization": f"Basic {token}",
        "Accept": "application/json",
        "User-Agent": "wezterm-tmux-status",
    },
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
except (OSError, urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError):
    raise SystemExit(1)

categories = {}
for item in payload.get("data", {}).get("categories", []) or []:
    name = item.get("name")
    text = item.get("text")
    if isinstance(name, str) and isinstance(text, str):
        categories[name] = text

print(f"AI\t{categories.get('AI Coding', '')}")
print(f"CODE\t{categories.get('Coding', '')}")
PY
}

write_wakatime_cache() {
  local timestamp="$1"
  local summary="$2"

  printf '%s\n%s\n' "$timestamp" "$summary" > "$WAKA_CACHE"
}

refresh_wakatime_cache() {
  touch "$WAKA_LOCK"
  local summary=""
  summary="$(fetch_wakatime_summary 2>/dev/null || true)"
  if [[ -n "$summary" ]]; then
    write_wakatime_cache "$(date +%s)" "$summary"
  fi
  rm -f "$WAKA_LOCK"
}

load_cached_summary() {
  local cached_time="$1"
  local line2=""
  local line3=""
  local legacy_json=""
  local legacy_summary=""

  line2="$(sed -n '2p' "$WAKA_CACHE" 2>/dev/null || true)"
  line3="$(sed -n '3p' "$WAKA_CACHE" 2>/dev/null || true)"

  if [[ "$line2" == $'AI\t'* ]] && [[ "$line3" == $'CODE\t'* ]]; then
    printf 'AI=%s\n' "${line2#$'AI\t'}"
    printf 'CODE=%s\n' "${line3#$'CODE\t'}"
    return 0
  fi

  legacy_json="$(tail -n +2 "$WAKA_CACHE" 2>/dev/null || true)"
  [[ -n "$legacy_json" ]] || return 1

  legacy_summary="$(WAKA_JSON="$legacy_json" emit_wakatime_summary_from_json 2>/dev/null || true)"
  [[ -n "$legacy_summary" ]] || return 1

  write_wakatime_cache "$cached_time" "$legacy_summary"
  printf '%s\n' "$legacy_summary" | awk -F '\t' '
    $1 == "AI" { printf "AI=%s\n", substr($0, 4) }
    $1 == "CODE" { printf "CODE=%s\n", substr($0, 6) }
  '
}

if [[ "${TMUX_STATUS_WAKATIME_REFRESH_ONLY:-0}" == "1" ]]; then
  if is_wakatime_available; then
    refresh_wakatime_cache
  fi
  exit 0
fi

if ! is_wakatime_available; then
  printf '%s%s' "$padding" "$(style 'fg=#7f7a72' 'WakaTime unavailable')"
  exit 0
fi

cached_time=0
ai=""
code=""

if [[ -f "$WAKA_CACHE" ]]; then
  cached_time="$(head -n 1 "$WAKA_CACHE" 2>/dev/null || printf '0')"
  cached_day="$(epoch_to_day "$cached_time" 2>/dev/null || true)"
  today="$(date +%Y-%m-%d)"

  if [[ "$cached_day" == "$today" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        AI)
          ai="$value"
          ;;
        CODE)
          code="$value"
          ;;
      esac
    done < <(load_cached_summary "$cached_time" || true)
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
  TMUX_STATUS_WAKATIME_REFRESH_ONLY=1 nohup bash "$script_path" >/dev/null 2>&1 &
fi

if [[ -z "$ai" && -z "$code" ]]; then
  printf '%s%s%s' \
    "$padding" \
    "$(style 'fg=#7f7a72' 'WakaTime:')" \
    "$(style 'fg=#7f7a72' ' Ready to roll')"
  exit 0
fi

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
