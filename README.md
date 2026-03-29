# WezTerm Config

This repository is the source of truth for the managed WezTerm runtime.

Supported runtime modes:

- `hybrid-wsl`: Windows desktop WezTerm plus WSL/tmux runtime
- `posix-local`: Linux desktop or macOS local runtime

Generated runtime targets live under the chosen user home:

- `$HOME/.wezterm.lua`
- `$HOME/.wezterm-x/...`

On Windows hybrid setups, `$HOME` is typically `%USERPROFILE%`.

The `wezterm-runtime-sync` skill owns runtime sync. Its implementation lives under `skills/wezterm-runtime-sync/scripts/`, prompts once for the target user directory, caches the choice in `.sync-target`, and writes runtime metadata such as `repo-root.txt` into the target `.wezterm-x` folder so the synced runtime can still find the source repo.

All runtime files are synced from this repo by the `wezterm-runtime-sync` skill.

Before using managed workspaces, copy `wezterm-x/local.example/` to `wezterm-x/local/` and fill in your private machine-specific values there. The `wezterm-x/local/` directory is gitignored but still copied by the sync skill because sync works from the working tree.

## Read This Repo

This file is the user-facing entry point.

- Read this file first for navigation.
- Open only the user doc that matches the task.
- Do not treat `/docs` as a single manual to read end to end unless you are doing a full documentation pass.

User docs:

- [`docs/user/overview.md`](docs/user/overview.md): setup summary and repo entry points
- [`docs/user/workspaces.md`](docs/user/workspaces.md): workspace model and how to update `wezterm-x/workspaces.lua`
- [`docs/user/keybindings.md`](docs/user/keybindings.md): workspace and pane shortcuts
- [`docs/user/tmux-and-status.md`](docs/user/tmux-and-status.md): tab titles, tmux layout, and status behavior
- [`docs/user/maintenance.md`](docs/user/maintenance.md): sync, reload, and validation workflow

Agent rules live in [`AGENTS.md`](AGENTS.md).
