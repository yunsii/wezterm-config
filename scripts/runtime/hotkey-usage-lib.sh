#!/usr/bin/env bash
# Shared resolver for the hotkey usage counter file.
#
# The counter is pure WSL bash (writer = scripts/runtime/hotkey-usage-bump.sh,
# reader = scripts/dev/hotkey-usage-report.sh) — no Windows-side consumer
# touches it. Per the cross-FS routing rule, files with both writer and
# reader in WSL belong on WSL ext4, not on /mnt/c, so the resolver prefers
# `${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime/`.
#
# Legacy data on /mnt/c is migrated transparently on the next bump or read:
# `hotkey_usage_migrate_legacy` moves the old file (and its .lock sibling)
# over to the new home if the new home is empty. Callers should invoke it
# before reading/writing.

# Resolve the canonical counter path. Lives under
# ${XDG_STATE_HOME}/wezterm-runtime/state/ to mirror the
# wezterm-runtime/{state,logs,bin}/ layout the Windows side uses; see
# scripts/runtime/wsl-runtime-paths-lib.sh for the constant + rationale.
hotkey_usage_path() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$lib_dir/wsl-runtime-paths-lib.sh"
  printf '%s' "$WSL_HOTKEY_USAGE_FILE"
}

# Emit every legacy location the file may live at, oldest-to-newest, one
# per line. Used by the migration helper to chain through historical
# moves without losing data:
#   1. /mnt/c (pre-Phase-1: file was on Windows NTFS)
#   2. WSL flat (post-Phase-1, pre-state/: ~/.local/state/wezterm-runtime/hotkey-usage.json)
hotkey_usage_legacy_paths() {
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$lib_dir/windows-runtime-paths-lib.sh" 2>/dev/null
  if declare -F windows_runtime_detect_paths >/dev/null 2>&1 && \
     windows_runtime_detect_paths 2>/dev/null; then
    printf '%s/hotkey-usage.json\n' "$WINDOWS_RUNTIME_STATE_WSL"
  fi
  printf '%s/hotkey-usage.json\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
}

# One-time migration: walk the legacy path list and move whichever file
# is found into the canonical location. Idempotent + non-fatal; returns
# 0 either way so callers never abort over an mv failure.
hotkey_usage_migrate_legacy() {
  local new_path="$1" legacy_path
  [[ -n "$new_path" ]] || return 0
  while IFS= read -r legacy_path; do
    [[ -n "$legacy_path" ]] || continue
    [[ "$legacy_path" != "$new_path" ]] || continue
    [[ -f "$legacy_path" && ! -f "$new_path" ]] || continue

    mkdir -p "${new_path%/*}" 2>/dev/null || continue
    mv -f "$legacy_path" "$new_path" 2>/dev/null || continue
    [[ -f "${legacy_path}.lock" ]] && \
      mv -f "${legacy_path}.lock" "${new_path}.lock" 2>/dev/null
    return 0
  done < <(hotkey_usage_legacy_paths)
  return 0
}
