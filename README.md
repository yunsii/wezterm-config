# WezTerm Config

This repository is the source of truth for a managed WezTerm runtime built around WezTerm, tmux, and git-worktree-based task flow.

## Runtime Modes

Supported runtime modes:

- `hybrid-wsl`: Windows desktop WezTerm plus WSL/tmux runtime
- `posix-local`: Linux desktop or macOS local runtime

Generated runtime targets live under the chosen user home:

- `$HOME/.wezterm.lua`
- `$HOME/.wezterm-x/...`

On Windows hybrid setups, `$HOME` is typically `%USERPROFILE%`.

## What This Repo Owns

- WezTerm config and Lua runtime
- tmux layout and status behavior
- managed workspaces and launcher behavior
- runtime sync scripts and Windows host-helper integration
- linked worktree task workflow
- project documentation and agent rules

This repo also hosts versioned user-level agent profiles under [`agent-profiles/`](agent-profiles/). They are maintained here for reuse and version control, but they are not project-level WezTerm instructions and are not part of the synced runtime.

## Quick Start

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Fill in your machine-local values under `wezterm-x/local/`.
3. Sync the runtime with:

```bash
skills/wezterm-runtime-sync/scripts/sync-runtime.sh
```

The `wezterm-runtime-sync` skill owns runtime sync. It caches the chosen target home in `.sync-target` and publishes the runtime into the target user directory.

## Read Next

- Project docs start at [`docs/README.md`](docs/README.md).
- Agent rules start at [`AGENTS.md`](AGENTS.md).
- User-level reusable agent profiles live under [`agent-profiles/`](agent-profiles/).

Useful direct links:

- Setup and local config: [`docs/setup.md`](docs/setup.md)
- Daily sync and verification: [`docs/daily-workflow.md`](docs/daily-workflow.md)
- Workspaces: [`docs/workspaces.md`](docs/workspaces.md)
- Keybindings: [`docs/keybindings.md`](docs/keybindings.md)
- tmux UI and status: [`docs/tmux-ui.md`](docs/tmux-ui.md)
- Diagnostics: [`docs/diagnostics.md`](docs/diagnostics.md)
- Architecture: [`docs/architecture.md`](docs/architecture.md)
