local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
local helpers = dofile(join_path(runtime_dir, 'lua', 'helpers.lua'))

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

local function default_runtime_mode(host_os)
  if host_os == 'windows' then
    return 'hybrid-wsl'
  end

  return 'posix-local'
end

local function default_window_font(host_os)
  if host_os == 'windows' then
    return wezterm.font { family = 'Segoe UI', weight = 'Bold' }
  end

  if host_os == 'macos' then
    return wezterm.font { family = 'SF Pro Text', weight = 'Bold' }
  end

  return wezterm.font { family = 'Noto Sans', weight = 'Bold' }
end

local function default_chrome_debug_executable(host_os)
  if host_os == 'windows' then
    return 'chrome.exe'
  end

  if host_os == 'macos' then
    return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  end

  return 'google-chrome'
end

local function default_vscode_command(host_os)
  if host_os == 'windows' then
    local local_app_data = os.getenv 'LOCALAPPDATA'
    if local_app_data and local_app_data ~= '' then
      return { local_app_data .. '\\Programs\\Microsoft VS Code\\Code.exe' }
    end
  end

  return { 'code' }
end

local function default_launch_menu(host_os)
  if host_os ~= 'windows' then
    return {}
  end

  return {
    {
      label = 'Windows PowerShell',
      args = { 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe', '-NoLogo' },
      domain = { DomainName = 'local' },
    },
  }
end

local function default_diagnostics_file(host_os)
  if host_os == 'windows' then
    return wezterm.config_dir .. '\\.wezterm-x\\wezterm-debug.log'
  end

  return wezterm.config_dir .. '/.wezterm-x/wezterm-debug.log'
end

local function read_repo_root_override()
  local override_path = join_path(runtime_dir, 'repo-root.txt')
  local file = io.open(override_path, 'r')
  if not file then
    return nil
  end
  local value = file:read('*l')
  file:close()
  if value and value ~= '' then
    return value
  end
  return nil
end

local function read_main_repo_root_override()
  local override_path = join_path(runtime_dir, 'repo-main-root.txt')
  local file = io.open(override_path, 'r')
  if not file then
    return nil
  end
  local value = file:read('*l')
  file:close()
  if value and value ~= '' then
    return value
  end
  return nil
end

local local_constants = helpers.load_optional_table(join_path(runtime_dir, 'local', 'constants.lua')) or {}
local shared_env = helpers.load_optional_env_file(join_path(runtime_dir, 'local', 'shared.env')) or {}
local host_os = detect_host_os()

local base_constants = {
  host_os = host_os,
  runtime_mode = default_runtime_mode(host_os),
  repo_root = nil,
  main_repo_root = nil,
  default_domain = nil,
  shell = {
    program = nil,
  },
  fonts = {
    terminal = wezterm.font 'Fira Code Retina',
    window = default_window_font(host_os),
  },
  palette = {
    background = '#f1f0e9',
    foreground = '#393a34',
    cursor_bg = '#8c6c3e',
    cursor_fg = '#f8f5ee',
    cursor_border = '#8c6c3e',
    selection_bg = '#e6e0d4',
    selection_fg = '#2f302c',
    scrollbar_thumb = '#d8d3c9',
    split = '#e3ded3',
    ansi = {
      '#393a34',
      '#ab5959',
      '#5f8f62',
      '#b07d48',
      '#4d699b',
      '#7e5d99',
      '#4c8b8b',
      '#d7d1c6',
    },
    brights = {
      '#6f706a',
      '#c96b6b',
      '#73a56e',
      '#c7925b',
      '#6b86b7',
      '#9a79b4',
      '#68a5a5',
      '#f6f3eb',
    },
    tab_bar_background = '#f1f0e9',
    tab_inactive_bg = '#f1f0e9',
    tab_inactive_fg = '#6f685f',
    tab_hover_bg = '#e2dbcd',
    tab_hover_fg = '#2f302c',
    tab_active_bg = '#d2c5ae',
    tab_active_fg = '#221f1a',
    new_tab_bg = '#f1f0e9',
    new_tab_fg = '#908b83',
    new_tab_hover_bg = '#e2dbcd',
    new_tab_hover_fg = '#2f302c',
    tab_edge = '#ddd8cd',
    tab_accent = '#b07d48',
    workspace_badges = {
      default = {
        bg = '#e5dfd3',
        fg = '#5f5a52',
      },
      managed = {
        bg = '#ddd0bb',
        fg = '#614321',
      },
      work = {
        bg = '#dbc39e',
        fg = '#4f3516',
      },
      config = {
        bg = '#d7dfed',
        fg = '#294267',
      },
    },
  },
  launch_menu = default_launch_menu(host_os),
  integrations = {
    vscode = {
      hybrid_wsl_command = default_vscode_command(host_os),
      posix_command = { 'code' },
    },
    chrome_debug = {
      cmd = 'cmd.exe',
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = wezterm.config_dir .. '\\.wezterm-x',
      script = 'scripts\\focus-or-start-debug-chrome.ps1',
    },
  },
  managed_cli = {
    default_profile = 'codex',
    ui_variant = 'light',
    profiles = {
      codex = {
        bootstrap = 'nvm',
        command = { 'codex' },
        variants = {
          light = { 'codex', '-c', 'tui.theme="github"' },
          dark = { 'codex' },
        },
      },
    },
  },
  chrome_debug_browser = {
    executable = default_chrome_debug_executable(host_os),
    remote_debugging_port = 9222,
    user_data_dir = nil,
  },
  wakatime = {
    api_key = nil,
  },
  diagnostics = {
    wezterm = {
      enabled = false,
      level = 'info',
      file = default_diagnostics_file(host_os),
      debug_key_events = false,
      categories = {},
    },
  },
}

local constants = helpers.deep_merge(base_constants, local_constants)
if shared_env.WAKATIME_API_KEY and shared_env.WAKATIME_API_KEY ~= '' then
  constants.wakatime = constants.wakatime or {}
  constants.wakatime.api_key = shared_env.WAKATIME_API_KEY
end
constants.repo_root = read_repo_root_override() or constants.repo_root
constants.main_repo_root = read_main_repo_root_override() or constants.main_repo_root or constants.repo_root

return constants
