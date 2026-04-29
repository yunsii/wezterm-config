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
if constants.managed_cli then
  managed_launcher = constants.managed_cli.default_resume_profile
    or constants.managed_cli.default_profile
end

-- The `work` workspace is the primary entry into a company project's
-- two-tier worktree model (see docs/workspaces.md "Task Worktree Lifecycle
-- Model"). Each item below is a separate WezTerm tab pointing at either:
--   - the project's main worktree, or
--   - a long-lived dev-* worktree.
-- Both resolve to the `<base>-resume` profile (e.g. `claude --continue`)
-- so first-open of a workspace tab auto-resumes the cwd's last
-- conversation, falling back to a fresh session when none exists.
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

  -- The `opensource` workspace collects personal / open-source projects
  -- under ~/github, separate from the company `work` workspace. Bound to
  -- Alt+s. Same launcher resolution as `work` — first open auto-resumes
  -- the cwd's last conversation, falling back to a fresh agent.
  opensource = {
    defaults = {
      launcher = managed_launcher,
    },
    items = {
      { cwd = '/home/your-user/github/some-oss-repo' },
      { cwd = '/home/your-user/github/another-oss-repo' },
    },
  },
}
