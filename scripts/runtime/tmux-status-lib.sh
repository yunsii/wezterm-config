#!/usr/bin/env bash
set -euo pipefail

is_enabled() {
  local value="${1:-1}"
  [[ "$value" != "0" && "$value" != "false" && "$value" != "off" && "$value" != "no" ]]
}

join_with_separator() {
  local separator="$1"
  shift

  local first=1
  local part
  for part in "$@"; do
    if (( first )); then
      printf '%s' "$part"
      first=0
    else
      printf '%s%s' "$separator" "$part"
    fi
  done
}

style() {
  local spec="$1"
  local text="$2"
  printf '#[%s]%s#[default]' "$spec" "$text"
}

epoch_to_day() {
  local value="$1"

  if date -d "@$value" +%Y-%m-%d >/dev/null 2>&1; then
    date -d "@$value" +%Y-%m-%d
    return
  fi

  date -r "$value" +%Y-%m-%d
}

file_mtime() {
  local path="$1"

  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
    return
  fi

  stat -f %m "$path"
}
