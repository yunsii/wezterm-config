# Workspaces

Use this doc when you need to understand or edit managed workspaces.

## Workspace Model

WezTerm workspaces are the top-level session unit. For the full WezTerm-vs-tmux nesting picture and the cross-layer ownership rule, see [`architecture.md`](./architecture.md#interaction-layers).

- `default`: WezTerm built-in workspace
- `work`: managed business workspace
- `config`: managed config workspace

## Behavior

- If the target workspace already exists, the shortcut switches to it. The switch runs inside a synchronous WezTerm callback, so its cost shows up directly as key-to-repaint latency — WezTerm cannot repaint the new workspace until the callback returns.
- When the existing tabs already match the configured items in order, the switch fast-paths to `mux.set_active_workspace` and skips the reorder/prune loop, so repeated switches stay roughly constant-time regardless of item count. Without this, a 7-item workspace would pay O(N²) tab matching, per-item `set_title`, optional `MoveTab`, and a final stale-tab scan on every switch, and the delay scales with item count (single-item workspaces such as `config` stay fast either way).
- When the workspace is out of sync (worktree reclaimed, items added or reordered), the next switch pays the full reorder/prune pass once to realign tabs, then later switches return to the fast path.
- If it does not exist, WezTerm creates the workspace window first and then switches to it, opening the first configured project as that workspace's entry window.
- `default` stays the built-in WezTerm workspace at the top level. In `hybrid-wsl`, its WSL tabs still launch into a lightweight single-pane tmux session.
- Non-default managed workspaces use the managed tmux bootstrap with repo-aware session reuse and the shared status layout.
- Each managed project tab boots through `tmux`.
- Each managed git project tab attaches to one tmux session per repo family, even when that repo has multiple linked worktrees.
- Inside that tmux session, each git worktree gets its own tmux window.
- Worktree switching inside that tmux session follows the live git state of the current pane or window layout, so manually created linked worktrees are discoverable without prewritten tmux metadata.
- The `worktree-task` skill creates linked task worktrees under the repository parent's `.worktrees/<repo>/` directory and opens them as additional tmux windows inside that same repo-family session.
- The `worktree-task` runtime also ships an `open-task-window` script (`scripts/runtime/worktree/open-task-window`) as a quick-create entry, bound to the `Ctrl+k` `g` sub-chord (`g d` for dev-, `g t` for task-, `g h` for hotfix-, `g r` to reclaim the current pane's worktree; see [`keybindings.md`](./keybindings.md#panes)). The script forwards <name> to `worktree-task launch` as the task title and prepends the lifecycle prefix; a leading `task/` is stripped so `fix-auth` and `task/fix-auth` resolve to the same worktree. The configured agent starts in the new tmux window but receives no prompt (launched with `--no-prompt`), so it comes up idle.
- The left pane runs the configured primary command.
- The right pane stays as a shell in the same directory.
- `work` and `config` default to the managed launcher profile from `managed_cli.default_profile`.
- The tracked baseline resolves that profile from `MANAGED_AGENT_PROFILE` in `wezterm-x/local/shared.env` when present; otherwise it falls back through the shared `worktree-task` config and then the built-in Lua default.
- The managed agent startup uses the profile default, and switches to the light variant when `managed_cli.ui_variant = "light"`.
- Profile commands are forked into bare and `-resume` variants. Bare `claude` / `codex` start fresh on every pane open and are used for the main worktree (no stale cross-task context) and for `hotfix-*` worktrees (urgent context shouldn't be polluted). The `claude-resume` / `codex-resume` profiles auto-continue the cwd's most recent conversation (`claude --continue`, `sh -c 'codex resume --last || exec codex'`) and are used for `dev-*` long-lived worktrees and `task-*` short-lived worktrees where cross-session continuity is the asset. `open-task-window --type` picks the right profile per lifecycle automatically; main-worktree panes inherit the user's `MANAGED_AGENT_PROFILE` (default `claude`).
- Profile command strings are sourced from `config/worktree-task.env` (repo-level) and `~/.config/worktree-task/config.env` (user-level). The Lua baseline in `wezterm-x/lua/constants.lua` only carries bare fallbacks used when no env file populates them, so both WezTerm workspace panes and worktree-task quick-create windows read the same single source of truth; edit the env file to change every surface at once.
- Managed agent commands run inside the resolved login shell so workspace startup sees the same shell environment as your normal terminal sessions.
- Raw `command = { ... }` overrides still bypass the managed launcher profile entirely.
- Existing tmux worktree sessions are reused as-is. Changing the launcher affects newly created or recreated sessions.
- `workspace.open()` opens only its first configured entry window immediately. Wider navigation is expected to happen inside tmux.

## Task Worktree Lifecycle Model

The worktree-task runtime supports a two-tier model where directory naming encodes lifecycle, decoupled from git branch naming. Use this for projects with team collaboration and PR review cycles; **personal projects that work directly on master usually don't need it**.

### Directory prefixes (lifecycle)

| Prefix | Lifetime | Created by | Reclaimed by | Agent profile |
|---|---|---|---|---|
| `main/` (the primary worktree) | permanent | initial clone | never | bare `claude` / `codex` |
| `dev-*` | weeks–months | `Ctrl+k g d` | manual `git worktree remove` only — `worktree-task reclaim` refuses | `claude-resume` / `codex-resume` |
| `task-*` | hours–days | `Ctrl+k g t` | `Ctrl+k g r` after merge | `claude-resume` / `codex-resume` |
| `hotfix-*` | hours | `Ctrl+k g h` | `Ctrl+k g r` after merge | bare `claude` / `codex` |

Long-lived `dev-*` worktrees act like persistent parallel "workstations" — accumulated agent context, dev-server state, dependency caches survive across days. Reclaim is intentionally refused on them by both the CLI and the hotkey to prevent loss of that state.

### Branch naming is independent

Worktree directory prefix encodes lifecycle (your local UX), git branch name still follows the team's branch policy (their merge surface). The `WT_POLICY_BRANCH_PREFIX=task/` default places branches under `task/<slug>` regardless of directory prefix; override with `--branch` per launch when team policy differs.

### Base ref strategy

The default `WT_POLICY_BASE_REF_STRATEGY=origin-default-branch` performs `git fetch origin` then branches off `origin/HEAD`. This insulates new worktrees from the primary worktree's current checkout AND from local divergence with origin. **First-time setup**: run `git remote set-head origin -a` once per repo to populate `origin/HEAD`. Repos without a remote fall back to `WT_POLICY_BASE_REF_STRATEGY=primary-head` (set explicitly in their env file or pass `--base-ref HEAD` per launch).

### Reclaim safety

`worktree-task reclaim` (and the `Ctrl+k g r` wrapper) enforce: refuse on the primary worktree, refuse on `dev-*` slugs, refuse on uncommitted/untracked changes (use `--force` to override), and only delete the task branch when it's already merged into the primary worktree's HEAD. After removal: `git worktree prune` cleans any phantom admin entries git may still hold. The Claude Code transcript at `~/.claude/projects/<escaped-cwd>/` is intentionally left in place — when a later worktree happens to reuse the same slug (legitimate inside the lifecycle prefix model), `claude --continue` resumes the prior conversation; use `/clear` inside the resumed session if the carried-over context isn't wanted.

## File Ownership

- `wezterm-x/workspaces.lua` is the tracked public baseline.
- `wezterm-x/local/workspaces.lua` is the gitignored private override file for your real project directories.
- `wezterm-x/local.example/workspaces.lua` is the tracked template you should copy before editing local values.
- `config` is defined in the tracked baseline and points at the primary worktree root for the synced repo family.
- The managed launcher scripts still run from the synced checkout while it exists, so testing a linked worktree does not add another top-level WezTerm tab.
- If that synced linked checkout is later reclaimed, managed workspace launchers fall back to the repo family's primary worktree.
- `work` is intentionally empty in the tracked baseline until you define your private directories in `wezterm-x/local/workspaces.lua`.

## Edit Rules

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

- Launcher profiles live in `wezterm-x/lua/constants.lua` under `managed_cli.profiles`.
- Machine-local profile selection belongs in `wezterm-x/local/shared.env`.
- Shared profile registration may also come from `config/worktree-task.env` and `~/.config/worktree-task/config.env`.

If you change the local file shape, update `wezterm-x/local.example/workspaces.lua` in the same edit.

After editing, follow [`daily-workflow.md`](./daily-workflow.md).
