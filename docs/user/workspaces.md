# Workspaces

Use this doc when you need to understand or edit managed workspaces.

## Workspace Model

WezTerm workspaces are the top-level session unit.

- `default`: WezTerm built-in workspace
- `work`: managed business workspace
- `config`: managed config workspace

## Managed Workspace Behavior

- If the target workspace already exists, the shortcut switches to it.
- If it does not exist, WezTerm creates the workspace window first and then switches to it, opening the first configured project as that workspace's entry window.
- `default` stays the built-in WezTerm workspace at the top level, but in `hybrid-wsl` its WSL tabs now launch straight into a single-pane tmux session so terminal rendering, copy-mode behavior, tmux-owned shortcut handling, and tmux status rendering stay unified there as well.
- Non-default managed workspaces still use the heavier managed tmux bootstrap with repo-aware session reuse, workspace tab sync, and the shared managed status layout.
- Each managed project tab boots through `tmux`.
- Each managed git project tab still attaches to one tmux session per repo family, even when that repo has multiple linked worktrees.
- Inside that tmux session, each git worktree gets its own tmux window.
- Worktree switching inside that tmux session now follows the live git state of the current pane or window layout, so manually created linked worktrees are discoverable without prewritten tmux metadata.
- The `worktree-task` skill creates linked task worktrees under the repository parent's `.worktrees/<repo>/` directory and opens them as additional tmux windows inside that same repo-family session.
- The left pane runs the configured primary command.
- The right pane stays as a shell in the same directory.
- `work` and `config` default to the managed launcher profile from `managed_cli.default_profile`.
- The tracked baseline resolves `managed_cli.default_profile` from the machine-local `MANAGED_AGENT_PROFILE` in `wezterm-x/local/shared.env` when present; otherwise it falls back through the shared `worktree-task` config and then the built-in Lua default in `wezterm-x/lua/constants.lua`.
- The managed agent startup uses the profile's default (dark) variant and switches to the `light` variant when `managed_cli.ui_variant = "light"`.
- In the tracked baseline, the `codex` profile uses `-c 'tui.theme="github"'` for the light variant and bare `codex` for the dark variant.
- Managed agent commands run inside the resolved login shell so workspace startup sees the same shell environment as your normal terminal sessions.
- Raw `command = { ... }` overrides still bypass the managed launcher profile entirely.
- To keep startup behavior consistent across managed workspaces, prefer `launcher = managed_launcher` in local workspace overrides instead of hard-coded wrapper commands such as `codex-github-theme`.
- Existing tmux worktree sessions are reused as-is; changing the launcher affects newly created or recreated worktree sessions, and the runtime logs now record both the desired launch command and the reused primary pane startup command to help spot stale panes.
- `workspace.open()` no longer auto-syncs additional top-level WezTerm tabs from the workspace definition. The top-level workspace switch now opens only its first configured entry window immediately; wider navigation is expected to happen inside tmux or through explicit follow-up opens instead of automatic tab fan-out during the initial switch.

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
local runtime_dir = _G.WEZTERM_RUNTIME_DIR or (wezterm.config_dir .. '/.wezterm-x')
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

The tracked launcher profiles live in `wezterm-x/lua/constants.lua` under `managed_cli.profiles`. Machine-local profile selection belongs in `wezterm-x/local/shared.env`, shared profile registration may also come from `config/worktree-task.env` (or legacy `.worktree-task/config.env`) and `~/.config/worktree-task/config.env`, and machine-specific Lua-only overrides still belong in `wezterm-x/local/constants.lua`.

If you change the local file shape, update `wezterm-x/local.example/workspaces.lua` in the same edit.

After editing, follow [`maintenance.md`](./maintenance.md).
