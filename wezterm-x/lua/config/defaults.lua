local M = {}

function M.detect_host_os(wezterm)
  local triple = wezterm.target_triple or ''

  if triple:find('windows', 1, true) then
    return 'windows'
  end

  if triple:find('darwin', 1, true) or triple:find('apple', 1, true) then
    return 'macos'
  end

  return 'linux'
end

function M.default_runtime_state_dir(host_os, join_path, wezterm)
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

function M.default_runtime_mode(host_os)
  if host_os == 'windows' then
    return 'hybrid-wsl'
  end

  return 'posix-local'
end

function M.default_terminal_font(wezterm, host_os)
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

function M.default_window_font(wezterm, host_os)
  if host_os == 'windows' then
    return wezterm.font { family = 'Segoe UI', weight = 'Bold' }
  end

  if host_os == 'macos' then
    return wezterm.font { family = 'SF Pro Text', weight = 'Bold' }
  end

  return wezterm.font { family = 'Noto Sans', weight = 'Bold' }
end

function M.default_chrome_debug_executable(host_os)
  if host_os == 'windows' then
    return 'chrome.exe'
  end

  if host_os == 'macos' then
    return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  end

  return 'google-chrome'
end

function M.default_vscode_command(host_os)
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

function M.default_clipboard_image_output_dir(host_os, runtime_state_dir, join_path)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'state', 'clipboard', 'exports')
end

function M.default_windows_runtime_helper_state_path(host_os, runtime_state_dir, join_path)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'state', 'helper', 'state.env')
end

function M.default_windows_runtime_helper_client_path(host_os, runtime_state_dir, join_path)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'bin', 'helperctl.exe')
end

function M.default_windows_helper_diagnostics_file(host_os, runtime_state_dir, join_path)
  if host_os ~= 'windows' then
    return nil
  end

  return join_path(runtime_state_dir, 'logs', 'helper.log')
end

function M.default_windows_runtime_helper_ipc_endpoint(host_os)
  if host_os ~= 'windows' then
    return nil
  end

  return '\\\\.\\pipe\\wezterm-host-helper-v1'
end

function M.default_launch_menu(host_os)
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

function M.default_diagnostics_file(runtime_state_dir, join_path)
  return join_path(runtime_state_dir, 'logs', 'wezterm.log')
end

function M.read_repo_root_override(runtime_dir, join_path)
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

function M.read_main_repo_root_override(runtime_dir, join_path)
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

function M.default_worktree_task_user_config_path(join_path)
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

return M
