local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
if not runtime_dir or runtime_dir == '' then
  runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
end
local constants = dofile(join_path(runtime_dir, 'lua', 'constants.lua'))

local managed_launcher = nil
if constants.managed_cli and constants.managed_cli.default_profile then
  managed_launcher = constants.managed_cli.default_profile
end

-- The `work` workspace is the primary entry into a company project's
-- two-tier worktree model (see docs/workspaces.md "Task Worktree Lifecycle
-- Model"). Each item below is a separate WezTerm tab pointing at either:
--   - the project's main worktree (bare claude profile, fresh on open), or
--   - a long-lived dev-* worktree (claude-resume profile, see notes below).
--
-- task-* and hotfix-* worktrees are NOT listed here — they're created on
-- demand via `Ctrl+k g t` / `Ctrl+k g h` and live as tmux windows inside
-- the repo-family session, not as WezTerm tabs.
return {
  work = {
    defaults = {
      launcher = managed_launcher,
    },
    items = {
      -- Primary checkout — keep this one for review, integration, hotfixes.
      { cwd = '/home/your-user/work/myproject/main' },

      -- Long-lived parallel dev workstations. Each maps to a worktree
      -- created once via `git worktree add` (manually) and lives weeks-
      -- to-months. Naming is up to you; recommended `dev-<area>` so the
      -- intent is obvious in tmux titles and `git worktree list`.
      { cwd = '/home/your-user/work/myproject/dev-billing' },
      { cwd = '/home/your-user/work/myproject/dev-search-rewrite' },

      -- Plain shell over a service repo, no managed agent.
      { cwd = '/home/your-user/work/project-c', command = { 'bash' } },
    },
  },
}
