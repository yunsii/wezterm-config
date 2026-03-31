# Workspaces

Use this doc when you need to understand or edit managed workspaces.

## Workspace Model

WezTerm workspaces are the top-level session unit.

- `default`: WezTerm built-in workspace
- `work`: managed business workspace
- `config`: managed config workspace

## Managed Workspace Behavior

- If the target workspace already exists, the shortcut switches to it.
- When a managed workspace already exists, the shortcut re-syncs its configured project tabs before switching to it.
- Tabs that no longer belong to the managed workspace definition are removed during that re-sync.
- If it does not exist, WezTerm creates it and opens the configured project tabs.
- Each managed project tab boots through `tmux`.
- Each managed git project tab now attaches to one tmux session per repo family, even when that repo has multiple linked worktrees.
- Inside that tmux session, each git worktree gets its own tmux window.
- The `worktree-task` skill creates linked task worktrees under the primary worktree's `.worktrees/` directory and opens them as additional tmux windows inside that same repo-family session.
- The left pane runs the configured primary command.
- The right pane stays as a shell in the same directory.
- `work` and `config` default to the managed launcher profile from `managed_cli.default_profile`.
- The tracked baseline currently uses the `codex` profile.
- Managed `codex` startup uses the default dark theme in `managed_cli.ui_variant = "dark"` and forces `tui.theme=github` in `managed_cli.ui_variant = "light"`.
- Raw `command = { ... }` overrides still bypass the managed launcher profile entirely.

## Public Vs Local Config

- `wezterm-x/workspaces.lua` is the tracked public baseline.
- `wezterm-x/local/workspaces.lua` is the gitignored private override file for your real project directories.
- `wezterm-x/local.example/workspaces.lua` is the tracked template you should copy before editing local values.
- `config` is defined in the tracked baseline and points at the primary worktree root for the synced repo family.
- The managed launcher scripts still run from the synced checkout while it exists, so testing a linked worktree does not add that linked worktree as another top-level WezTerm tab.
- If that synced linked checkout is later reclaimed, managed workspace launchers fall back to the repo family's primary worktree automatically.
- `work` is intentionally empty in the tracked baseline until you define your private directories in `wezterm-x/local/workspaces.lua`.

## Update Workspaces

Edit `wezterm-x/workspaces.lua` when you need to change:

- shared workspace semantics
- the default launcher for that workspace
- tracked workspace names such as `config`

Edit `wezterm-x/local/workspaces.lua` when you need to change:

- your private project directories
- machine-specific workspace overrides
- per-project launcher overrides that should not be committed
- raw per-project command overrides that should bypass the managed launcher

Example local override:

```lua
local wezterm = require 'wezterm'
local runtime_dir = wezterm.config_dir .. '/.wezterm-x'
local constants = dofile(runtime_dir .. '/lua/constants.lua')

local managed_launcher = nil
if constants.managed_cli and constants.managed_cli.default_profile then
  managed_launcher = constants.managed_cli.default_profile
end

return {
  work = {
    defaults = {
      launcher = managed_launcher,
    },
    items = {
      { cwd = '/home/your-user/work/project-a' },
      { cwd = '/home/your-user/work/project-b' },
      { cwd = '/home/your-user/work/project-c', command = { 'bash' } },
    },
  },
}
```

The tracked launcher profiles live in `wezterm-x/lua/constants.lua` under `managed_cli.profiles`, while machine-specific overrides belong in `wezterm-x/local/constants.lua`.

If you change the local file shape, update `wezterm-x/local.example/workspaces.lua` in the same edit.

After editing, follow [`maintenance.md`](./maintenance.md).
