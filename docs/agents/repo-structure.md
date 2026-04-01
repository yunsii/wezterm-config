# Repo Structure

Use this doc when you need ownership boundaries or file entry points.

## Source Of Truth

- This repository is the source of truth.
- Windows runtime files are generated from this repo by the `wezterm-runtime-sync` skill in `skills/wezterm-runtime-sync/`.
- Live targets include:
  - `%USERPROFILE%\.wezterm.lua`
  - `%USERPROFILE%\.wezterm-x\...`

## Entry Points

- `wezterm-x/workspaces.lua`: managed workspace definitions
- `wezterm.lua`: top-level WezTerm config and keybindings
- `wezterm-x/lua/`: supporting Lua modules loaded by `wezterm.lua`
- `wezterm-x/lua/logger.lua`: WezTerm-side structured diagnostics helper
- `wezterm-x/local.example/`: tracked templates for machine-local overrides
- `wezterm-x/local/`: gitignored machine-local overrides copied by the sync skill when present
- `.worktree-task/config.env`: tracked repo profile for the self-contained `worktree-task` skill, including the explicit `wezterm-config` repo pointer used to collect shared launch conventions
- `skills/wezterm-runtime-sync/`: skill-owned runtime sync workflow, prompt rendering, and prompt regression scripts
- `skills/worktree-task/`: self-contained linked worktree task skill with unified CLI, core libraries, and built-in providers
- `scripts/runtime/runtime-log-lib.sh`: shared runtime logging helper for WSL-side scripts
- `scripts/runtime/open-current-dir-in-vscode.sh`: pane-aware VS Code launcher used by tmux `Alt+o`
- `scripts/runtime/open-project-session.sh`: tmux bootstrap for managed project tabs
- `scripts/runtime/run-managed-command.sh`: managed startup command launcher
- `wezterm-x/scripts/`: runtime launcher scripts copied by the runtime sync skill
- `scripts/dev/`: repo-local helper scripts that are not synced to Windows
- `tmux.conf`: tmux layout and status rendering

## Diagnostics Ownership

- WezTerm diagnostics are configured in `wezterm-x/local/constants.lua` under `diagnostics.wezterm`.
- Runtime script diagnostics are configured in `wezterm-x/local/runtime-logging.sh`, starting from `wezterm-x/local.example/runtime-logging.sh`.
- Keep diagnostics logic centralized in `wezterm-x/lua/logger.lua` and `scripts/runtime/runtime-log-lib.sh` rather than open-coding ad hoc logging in individual files.

## Loading Rule

- Start with the single owning file for the task.
- Open additional files only if the owning file delegates behavior there.
- Do not load all Lua modules or all scripts preemptively.
