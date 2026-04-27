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
local attention = load_module 'attention'
local chrome_debug_status = load_module 'chrome_debug_status'
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

local vscode_integration = (constants.integrations and constants.integrations.vscode) or {}
chrome_debug_status.configure {
  state_file = constants.chrome_debug_browser and constants.chrome_debug_browser.state_file,
  fallback_port = constants.chrome_debug_browser and constants.chrome_debug_browser.remote_debugging_port,
  helper_state_file = vscode_integration.helper_state_path,
  helper_heartbeat_timeout_ms = (vscode_integration.helper_heartbeat_timeout_seconds or 5) * 1000,
}

titles.register {
  wezterm = wezterm,
  palette = constants.palette,
  attention = attention,
  chrome_debug_status = chrome_debug_status,
  host = host,
  logger = logger,
  constants = constants,
}

ui.apply {
  wezterm = wezterm,
  config = config,
  constants = constants,
  workspace = workspace,
  attention = attention,
  logger = logger,
  host = host,
}

return config
