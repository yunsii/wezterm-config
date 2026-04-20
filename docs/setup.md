# Setup

Use this doc when you need prerequisites and local setup.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `tmux` must be available in the runtime environment that will host managed project tabs.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY` in `wezterm-x/local/shared.env`.
- Repo-local helper wrappers such as `scripts/runtime/agent-clipboard.sh` require `hybrid-wsl`, `cmd.exe`, `powershell.exe`, `wslpath`, and a synced Windows helper runtime.

## Local Setup

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Edit `wezterm-x/local/constants.lua` for `runtime_mode`, runtime shell, UI variant, and OS-specific integrations such as `default_domain` or Chrome debug profile path.
3. Edit `wezterm-x/local/shared.env` for shared scalar values such as `WAKATIME_API_KEY` and `MANAGED_AGENT_PROFILE`.
4. Edit `wezterm-x/local/workspaces.lua` for your private project directories.
5. Optionally create `~/.config/worktree-task/config.env` when you need to point globally installed `worktree-task` back at a tracked `wezterm-config` repo with `WEZTERM_CONFIG_REPO=/absolute/path`.
6. Optionally edit `wezterm-x/local/command-panel.sh` for machine-local tmux command palette entries exposed through `Ctrl+Shift+P`.

## File Boundaries

- `wezterm-x/workspaces.lua`: tracked shared workspace defaults
- `wezterm-x/local/workspaces.lua`: private directories and machine-local workspace overrides
- `wezterm-x/local/shared.env`: shared scalar values used by Lua and shell code
- `wezterm-x/local/constants.lua`: machine-local structured Lua settings
- `wezterm-x/local.example/`: tracked templates for `wezterm-x/local/`

## Repo-Local Runtime Wrappers

- When your automation can already resolve the repository root, prefer repo-local wrappers under `scripts/runtime/` over rebuilding helper IPC or Windows bootstrap logic.
- `scripts/runtime/agent-clipboard.sh` is the current agent-facing clipboard wrapper. It stays in WSL, ensures the Windows helper is healthy, and then writes text or an image file to the Windows clipboard.
- If that wrapper reports that the helper bootstrap is missing, sync the runtime first, then rerun the command.
- `sync-runtime.sh` writes `~/.wezterm-x/agent-tools.env` on the target home. That marker is the primary discovery contract for external agent platforms.
- Read `agent_clipboard` from `~/.wezterm-x/agent-tools.env` instead of inferring wrapper paths from the current task repository or AGENTS symlinks.

## Windows Launch Hotkey

For `hybrid-wsl` on Windows, pin WezTerm to the taskbar together with the two apps you reach most often so the built-in `Win+N` shortcut can launch or focus them without a background hotkey daemon. Recommended layout:

- `Win+1`: WezTerm
- `Win+2`: primary browser
- `Win+3`: primary IM client (Feishu, Slack, Teams, etc.)

Pin each app, then drag the icons so WezTerm sits in slot 1, the browser in slot 2, and the IM client in slot 3. The binding survives reboots, needs no extra tooling, and stays out of the in-WezTerm keymap documented in [`keybindings.md`](./keybindings.md).

## Windows Script Execution

- For Windows-facing shell automation in this repo, source `scripts/runtime/windows-shell-lib.sh` and run PowerShell through `windows_run_powershell_script_utf8` or `windows_run_powershell_command_utf8`.
- Prefer checked-in `.ps1` entrypoints over ad-hoc inline `powershell.exe -Command ...`; when inline PowerShell is unavoidable, keep the body inside the shared UTF-8 wrapper instead of calling `powershell.exe` directly.
- Do not use `cmd.exe /c dir`, `cmd.exe /c type`, or similar commands for file inspection. Resolve the Windows runtime paths with `scripts/runtime/windows-runtime-paths-lib.sh`, convert to WSL paths there, and then use WSL-native tools such as `ls`, `cat`, and `rg`.
- Keep `cmd.exe` usage limited to ASCII-safe environment discovery such as `%LOCALAPPDATA%` or `%USERPROFILE%`.

## Read Next

- Workspace semantics and config shape:
  Read [`workspaces.md`](./workspaces.md).
- Sync, reload, and verification:
  Read [`daily-workflow.md`](./daily-workflow.md).
- Runtime ownership and entry points:
  Read [`architecture.md`](./architecture.md).
