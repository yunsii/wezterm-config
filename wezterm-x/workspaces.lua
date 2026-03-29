local wezterm = require 'wezterm'
local runtime_dir = wezterm.config_dir .. '/.wezterm-x'
local constants = dofile(runtime_dir .. '/lua/constants.lua')
local helpers = dofile(runtime_dir .. '/lua/helpers.lua')

local managed_launcher = nil
if constants.managed_cli and constants.managed_cli.default_profile then
  managed_launcher = constants.managed_cli.default_profile
end

local public_workspaces = {
  work = {
    defaults = {
      launcher = managed_launcher,
    },
    items = {},
  },
  config = {
    defaults = {
      launcher = managed_launcher,
    },
    items = constants.repo_root and {
      { cwd = constants.repo_root },
    } or {},
  },
}

local local_workspaces = helpers.load_optional_table(runtime_dir .. '/local/workspaces.lua') or {}
for name, workspace in pairs(local_workspaces) do
  public_workspaces[name] = workspace
end

return public_workspaces
