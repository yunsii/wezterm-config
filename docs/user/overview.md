# Overview

Use this doc when you need the minimum setup and navigation context.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `tmux` must be available in the runtime environment that will host managed project tabs.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY` in `wezterm-x/local/shared.env`.

## Local Setup

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Edit `wezterm-x/local/constants.lua` for your `runtime_mode`, runtime shell, managed CLI theme variant, and any optional OS-specific integrations such as `default_domain` or Chrome debug profile path. `Alt+b` uses the synced launcher scripts under `wezterm-x/scripts/` and requires `chrome_debug_browser.user_data_dir`.
3. Edit `wezterm-x/local/shared.env` for shared scalar values that both Lua and shell scripts need, such as `WAKATIME_API_KEY`.
4. Edit `wezterm-x/local/workspaces.lua` for your private project directories.

 ## Repo Entry Points

- `wezterm.lua`: main WezTerm config
- `wezterm-x/workspaces.lua`: shared public workspace baseline and per-project startup defaults
- `wezterm-x/local.example/`: tracked templates for private machine-local overrides
- `wezterm-x/local.example/shared.env`: tracked template for simple shared scalar values used by both Lua and shell runtime code
- `wezterm-x/local/`: gitignored machine-local overrides that are still copied by the sync skill
- `.worktree-task/config.env`: tracked repo profile for the self-contained worktree-task skill
- `wezterm-x/lua/`: WezTerm Lua modules synced under the target home directory's `.wezterm-x`
- `skills/wezterm-runtime-sync/`: Codex skill and scripts that own runtime sync and prompt regression checks
- `skills/worktree-task/`: agent skill, core libraries, and built-in providers for linked task worktrees
- `tmux.conf`: tmux layout and status line rendering
- `scripts/runtime/open-project-session.sh`: tmux session bootstrap for managed project tabs
- `scripts/runtime/run-managed-command.sh`: launcher for managed workspace startup commands
- `skills/worktree-task/scripts/worktree-task`: unified linked worktree task CLI
- `wezterm-x/scripts/`: runtime launcher scripts synced for Chrome and other desktop integrations
- `scripts/dev/`: repo-local maintenance helpers
- `skills/wezterm-runtime-sync/scripts/sync-runtime.sh`: skill-owned sync implementation; the public workflow is to use the `wezterm-runtime-sync` skill
- `skills/worktree-task/scripts/providers/tmux-agent.sh`: built-in tmux agent provider for linked task worktrees

## Read Next

- For workspace behavior or editing workspace items, read [`workspaces.md`](./workspaces.md).
- For shortcuts, read [`keybindings.md`](./keybindings.md).
- For tmux or tab behavior, read [`tmux-and-status.md`](./tmux-and-status.md).
- For syncing and verification, read [`maintenance.md`](./maintenance.md).
