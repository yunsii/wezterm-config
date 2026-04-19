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

local host_os = detect_host_os()

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
if not runtime_dir or runtime_dir == '' then
  runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
end

local function default_runtime_state_dir()
  if host_os == 'windows' then
    local local_app_data = os.getenv 'LOCALAPPDATA'
    if local_app_data and local_app_data ~= '' then
      return join_path(local_app_data, 'wezterm-runtime')
    end

    return join_path(wezterm.config_dir, '.wezterm-runtime')
  end

  local xdg_state_home = os.getenv 'XDG_STATE_HOME'
  if xdg_state_home and xdg_state_home ~= '' then
    return join_path(xdg_state_home, 'wezterm-runtime')
  end

  local home = os.getenv 'HOME'
  if home and home ~= '' then
    return join_path(home, '.local', 'state', 'wezterm-runtime')
  end

  return join_path(wezterm.config_dir, '.wezterm-runtime')
end

local runtime_state_dir = rawget(_G, 'WEZTERM_RUNTIME_STATE_DIR')
if not runtime_state_dir or runtime_state_dir == '' then
  runtime_state_dir = default_runtime_state_dir()
end

local helpers = dofile(join_path(runtime_dir, 'lua', 'helpers.lua'))

local function default_runtime_mode(host_os)
  if host_os == 'windows' then
    return 'hybrid-wsl'
  end

  return 'posix-local'
end

local function default_terminal_font(host_os)
  local fallbacks = { 'Fira Code Retina' }

  if host_os == 'windows' then
    fallbacks[#fallbacks + 1] = 'Cascadia Code'
    fallbacks[#fallbacks + 1] = 'Consolas'
    fallbacks[#fallbacks + 1] = { family = 'Microsoft YaHei', weight = 'Regular' }
  elseif host_os == 'macos' then
    fallbacks[#fallbacks + 1] = 'Menlo'
    fallbacks[#fallbacks + 1] = { family = 'PingFang SC', weight = 'Regular' }
    fallbacks[#fallbacks + 1] = { family = 'Hiragino Sans GB', weight = 'Regular' }
  else
    fallbacks[#fallbacks + 1] = 'DejaVu Sans Mono'
  end

  fallbacks[#fallbacks + 1] = { family = 'Noto Sans CJK SC', weight = 'Regular' }
  return wezterm.font_with_fallback(fallbacks)
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
      local user_install = local_app_data .. '\\Programs\\Microsoft VS Code\\Code.exe'
      local file = io.open(user_install, 'r')
      if file then
        file:close()
        return { user_install }
      end
    end

    return { 'C:\\Program Files\\Microsoft VS Code\\Code.exe' }
  end

  return { 'code' }
end

local function default_clipboard_image_output_dir(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'state', 'clipboard', 'exports')
end

local function default_windows_runtime_helper_state_path(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'state', 'helper', 'state.env')
end

local function default_windows_runtime_helper_client_path(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'bin', 'helperctl.exe')
end

local function default_windows_helper_diagnostics_file(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'logs', 'helper.log')
end

local function default_windows_runtime_helper_ipc_endpoint(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return '\\\\.\\pipe\\wezterm-host-helper-v1'
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
  return join_path(runtime_state_dir, 'logs', 'wezterm.log')
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

local function default_worktree_task_user_config_path()
  local xdg_config_home = os.getenv 'XDG_CONFIG_HOME'
  if xdg_config_home and xdg_config_home ~= '' then
    return join_path(xdg_config_home, 'worktree-task', 'config.env')
  end

  local home = os.getenv 'HOME'
  if home and home ~= '' then
    return join_path(home, '.config', 'worktree-task', 'config.env')
  end

  return nil
end

local function normalize_agent_profile_name(name)
  if not name or name == '' then
    return nil
  end

  local normalized = name:lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if normalized == '' then
    return nil
  end

  return normalized
end

local function parse_command_spec(spec)
  if not spec or spec == '' then
    return nil
  end

  local parts = {}
  local current = {}
  local quote = nil
  local escape = false

  local function push_current()
    if #current == 0 then
      return
    end
    parts[#parts + 1] = table.concat(current)
    current = {}
  end

  for i = 1, #spec do
    local char = spec:sub(i, i)
    if escape then
      current[#current + 1] = char
      escape = false
    elseif char == '\\' and quote ~= "'" then
      escape = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        current[#current + 1] = char
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char:match('%s') then
      push_current()
    else
      current[#current + 1] = char
    end
  end

  if escape then
    current[#current + 1] = '\\'
  end

  push_current()

  if #parts == 0 then
    return nil
  end

  return parts
end

local function parse_managed_cli_env(env)
  local parsed = {
    active_profile = nil,
    profiles = {},
  }

  if not env then
    return parsed
  end

  parsed.active_profile = normalize_agent_profile_name(env.WT_PROVIDER_AGENT_PROFILE)

  for key, value in pairs(env) do
    local raw_name, field = key:match('^WT_PROVIDER_AGENT_PROFILE_([A-Z0-9_]+)_(COMMAND|COMMAND_LIGHT|COMMAND_DARK|PROMPT_FLAG)$')
    if raw_name and field then
      local profile_name = normalize_agent_profile_name(raw_name)
      if profile_name then
        local profile = parsed.profiles[profile_name] or {
          command = nil,
          variants = {},
          prompt_flag = nil,
        }
        parsed.profiles[profile_name] = profile

        if field == 'COMMAND' then
          profile.command = parse_command_spec(value)
        elseif field == 'COMMAND_LIGHT' then
          profile.variants.light = parse_command_spec(value)
        elseif field == 'COMMAND_DARK' then
          profile.variants.dark = parse_command_spec(value)
        elseif field == 'PROMPT_FLAG' then
          profile.prompt_flag = value ~= '' and value or nil
        end
      end
    end
  end

  for _, profile in pairs(parsed.profiles) do
    if not next(profile.variants) then
      profile.variants = {}
    end
  end

  return parsed
end

local local_constants = helpers.load_optional_table(join_path(runtime_dir, 'local', 'constants.lua')) or {}
local shared_env = helpers.load_optional_env_file(join_path(runtime_dir, 'local', 'shared.env')) or {}
local repo_root_override = read_repo_root_override()
local repo_worktree_task_env = repo_root_override and (
  helpers.load_optional_env_file(join_path(repo_root_override, 'config', 'worktree-task.env'))
  or helpers.load_optional_env_file(join_path(repo_root_override, '.worktree-task', 'config.env'))
) or {}
local user_worktree_task_env = helpers.load_optional_env_file(default_worktree_task_user_config_path() or '') or {}
local repo_managed_cli_env = parse_managed_cli_env(repo_worktree_task_env)
local user_managed_cli_env = parse_managed_cli_env(user_worktree_task_env)
local local_managed_cli_profile = normalize_agent_profile_name(shared_env.MANAGED_AGENT_PROFILE)

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
    terminal = default_terminal_font(host_os),
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
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
      helper_script = 'scripts\\ensure-windows-runtime-helper.ps1',
      helper_client_exe = default_windows_runtime_helper_client_path(host_os),
      helper_log_file = default_windows_helper_diagnostics_file(host_os),
      helper_ipc_endpoint = default_windows_runtime_helper_ipc_endpoint(host_os),
      helper_state_path = default_windows_runtime_helper_state_path(host_os),
      helper_request_timeout_ms = 5000,
      helper_heartbeat_timeout_seconds = 5,
      helper_heartbeat_interval_ms = 1000,
      posix_shell = '/bin/bash',
      posix_script = wezterm.config_dir .. '/scripts/runtime/open-current-dir-in-vscode.sh',
    },
    chrome_debug = {
      cmd = 'cmd.exe',
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
    },
    clipboard_image = {
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
      output_dir = default_clipboard_image_output_dir(host_os),
      image_read_retry_count = 12,
      image_read_retry_delay_ms = 100,
      cleanup_max_age_hours = 48,
      cleanup_max_files = 32,
    },
  },
  managed_cli = {
    default_profile = 'claude',
    ui_variant = 'light',
    profiles = {
      claude = {
        command = { 'claude' },
        variants = {},
      },
      codex = {
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
      enabled = true,
      level = 'info',
      file = default_diagnostics_file(host_os),
      max_bytes = 5242880,
      max_files = 5,
      debug_key_events = false,
      categories = {},
    },
  },
}

local constants = helpers.deep_merge(base_constants, local_constants)
constants.managed_cli = constants.managed_cli or {}
constants.managed_cli.profiles = helpers.deep_merge(constants.managed_cli.profiles or {}, repo_managed_cli_env.profiles or {})
constants.managed_cli.profiles = helpers.deep_merge(constants.managed_cli.profiles or {}, user_managed_cli_env.profiles or {})
if repo_managed_cli_env.active_profile then
  constants.managed_cli.default_profile = repo_managed_cli_env.active_profile
end
if user_managed_cli_env.active_profile then
  constants.managed_cli.default_profile = user_managed_cli_env.active_profile
end
if local_managed_cli_profile then
  constants.managed_cli.default_profile = local_managed_cli_profile
end
if shared_env.WAKATIME_API_KEY and shared_env.WAKATIME_API_KEY ~= '' then
  constants.wakatime = constants.wakatime or {}
  constants.wakatime.api_key = shared_env.WAKATIME_API_KEY
end
constants.repo_root = repo_root_override or constants.repo_root
constants.main_repo_root = read_main_repo_root_override() or constants.main_repo_root or constants.repo_root

return constants
