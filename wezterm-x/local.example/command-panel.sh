#!/usr/bin/env bash

# This file is sourced by the tmux command panel runtime. Append machine-local
# `Ctrl+k` entries with command_panel_register_item.
#
# Supported flags:
#   --id VALUE
#   --label VALUE
#   --description VALUE
#   --runtime-mode VALUE    Repeat to limit an item to specific runtime modes.
#   --background            Fire-and-forget launcher.
#   --confirm-message VALUE
#   --success-message VALUE
#   --failure-message VALUE
#   --                      Remaining argv becomes the command to run.

# command_panel_register_item \
#   --id open-notepad \
#   --label 'Open Notepad' \
#   --description 'Example background launcher on the Windows host' \
#   --runtime-mode hybrid-wsl \
#   --background \
#   --success-message 'Opened Notepad.' \
#   -- notepad.exe
