#!/usr/bin/env bash

# This file is sourced by the tmux command palette runtime. Append machine-local
# `Ctrl+Shift+P` entries with command_panel_register_item.
#
# Supported flags:
#   --id VALUE
#   --label VALUE
#   --accelerator VALUE
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
#   --accelerator 'n' \
#   --description 'Example background launcher on the Windows host' \
#   --runtime-mode hybrid-wsl \
#   --background \
#   --success-message 'Opened Notepad.' \
#   -- notepad.exe
