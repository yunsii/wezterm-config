local wezterm = require 'wezterm'
local config = wezterm.config_builder()
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
if not runtime_dir or runtime_dir == '' then
  runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
end

local function load_module(name)
  return dofile(join_path(runtime_dir, 'lua', name .. '.lua'))
end

local constants = load_module 'constants'
local helpers = load_module 'helpers'
local titles = load_module 'titles'
local ui = load_module 'ui'
local workspace_manager = load_module 'workspace_manager'
local logger = load_module('logger').new {
  wezterm = wezterm,
  constants = constants,
}
local host = load_module('host').new {
  wezterm = wezterm,
  constants = constants,
  helpers = helpers,
  logger = logger,
}

config.debug_key_events = constants.diagnostics
  and constants.diagnostics.wezterm
  and constants.diagnostics.wezterm.debug_key_events == true
  or false

local workspace = workspace_manager.new {
  wezterm = wezterm,
  config = config,
  constants = constants,
}

titles.register {
  wezterm = wezterm,
  palette = constants.palette,
  host = host,
}

ui.apply {
  wezterm = wezterm,
  config = config,
  constants = constants,
  workspace = workspace,
  logger = logger,
  host = host,
}

return config
