#!/usr/bin/env bash
# Canonical WSL-native runtime path constants.
#
# Mirrors the role of windows-runtime-paths-lib.sh on the WSL side:
# every script that reads or writes a WSL-native state / cache / log
# file should source this and use the exported constants instead of
# re-deriving the XDG_STATE_HOME + wezterm-runtime/{state,logs,bin}
# layout per script.
#
# Layout intentionally mirrors %LOCALAPPDATA%/wezterm-runtime/
# {state,logs,bin}/ on the Windows side, so a file's role in the
# system is recognizable regardless of which FS it lives on. The
# cross-FS routing rule (docs/performance.md) decides WHICH side a
# file belongs to; this convention decides WHERE inside that side.
#
#   ~/.local/state/wezterm-runtime/         ← WSL_RUNTIME_STATE_ROOT (XDG_STATE)
#     ├── state/                            ← WSL_RUNTIME_STATE_DIR  (durable state)
#     │   └── hotkey-usage.json             ← WSL_HOTKEY_USAGE_FILE
#     ├── logs/                             ← WSL_RUNTIME_LOGS_DIR
#     │   └── runtime.log                   ← WSL_RUNTIME_LOG_FILE
#     └── bin/                              ← WSL_RUNTIME_BIN_DIR (reserved; picker
#                                              binary lives in repo for now)
#
#   ~/.cache/wezterm-runtime/               ← WSL_RUNTIME_CACHE_ROOT (XDG_CACHE,
#                                              files here are safe to lose)
#     └── windows-paths.env                 ← WSL_WINDOWS_PATHS_CACHE_FILE
#
# Adding a new WSL-native file means:
#   1. Decide state vs cache (data loss tolerance, not size).
#   2. Add a `WSL_<NAME>_FILE` constant here.
#   3. Consumer sources this lib + uses the constant.

WSL_RUNTIME_STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime"
WSL_RUNTIME_STATE_DIR="$WSL_RUNTIME_STATE_ROOT/state"
WSL_RUNTIME_LOGS_DIR="$WSL_RUNTIME_STATE_ROOT/logs"
WSL_RUNTIME_BIN_DIR="$WSL_RUNTIME_STATE_ROOT/bin"
WSL_RUNTIME_CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/wezterm-runtime"

WSL_RUNTIME_LOG_FILE="$WSL_RUNTIME_LOGS_DIR/runtime.log"
WSL_HOTKEY_USAGE_FILE="$WSL_RUNTIME_STATE_DIR/hotkey-usage.json"
WSL_WINDOWS_PATHS_CACHE_FILE="$WSL_RUNTIME_CACHE_ROOT/windows-paths.env"
