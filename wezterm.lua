local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local function detect_host_os()
  local triple = wezterm.target_triple or ''

  if triple:find('windows', 1, true) then
    return 'windows'
  end

  if triple:find('darwin', 1, true) or triple:find('apple', 1, true) then
    return 'macos'
  end

  return 'linux'
end

local function default_runtime_state_dir(config_dir)
  local host_os = detect_host_os()

  if host_os == 'windows' then
    local local_app_data = os.getenv 'LOCALAPPDATA'
    if local_app_data and local_app_data ~= '' then
      return join_path(local_app_data, 'wezterm-runtime')
    end

    return join_path(config_dir, '.wezterm-runtime')
  end

  local xdg_state_home = os.getenv 'XDG_STATE_HOME'
  if xdg_state_home and xdg_state_home ~= '' then
    return join_path(xdg_state_home, 'wezterm-runtime')
  end

  local home = os.getenv 'HOME'
  if home and home ~= '' then
    return join_path(home, '.local', 'state', 'wezterm-runtime')
  end

  return join_path(config_dir, '.wezterm-runtime')
end

local function apply_runtime_globals(spec)
  _G.WEZTERM_RUNTIME_RELEASE_ID = spec.release_id
  _G.WEZTERM_RUNTIME_RELEASE_ROOT = spec.release_root
  _G.WEZTERM_RUNTIME_DIR = spec.runtime_dir
  _G.WEZTERM_RUNTIME_STATE_DIR = spec.state_dir
end

local function runtime_spec(config_dir)
  local runtime_dir = join_path(config_dir, '.wezterm-x')
  return {
    release_id = 'stable',
    release_root = config_dir,
    runtime_dir = runtime_dir,
    state_dir = default_runtime_state_dir(config_dir),
  }
end

local config_dir = wezterm.config_dir
local release_spec = runtime_spec(config_dir)
apply_runtime_globals(release_spec)

return dofile(join_path(release_spec.runtime_dir, 'runtime-entry.lua'))
