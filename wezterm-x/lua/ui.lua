local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local function workspace_keybinding(wezterm, workspace, key, name)
  return {
    key = key,
    mods = 'ALT',
    action = wezterm.action_callback(function(window, pane)
      workspace.open(window, pane, name)
    end),
  }
end

local function active_workspace_name(window)
  local mux_window = window and window:mux_window()
  if mux_window then
    return mux_window:get_workspace()
  end

  return (window and window:active_workspace()) or 'default'
end

local function is_managed_workspace(workspace_name)
  return workspace_name ~= nil and workspace_name ~= 'default'
end

local function file_path_from_cwd(cwd)
  if not cwd then
    return nil
  end

  local ok, file_path = pcall(function()
    return cwd.file_path
  end)
  if ok and file_path then
    return file_path
  end

  local cwd_text = tostring(cwd)
  return cwd_text:match '^file://[^/]*(/.*)$'
end

local function basename(path)
  if not path or path == '' then
    return ''
  end

  return path:match('([^/\\]+)[/\\]?$') or path
end

local function foreground_process_basename(pane)
  if not pane or not pane.get_foreground_process_name then
    return nil
  end

  local ok, process_name = pcall(function()
    return pane:get_foreground_process_name()
  end)
  if not ok or not process_name or process_name == '' then
    return nil
  end

  return basename(process_name)
end

local function copy_args(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[#result + 1] = value
  end
  return result
end

local function trim_text(value)
  if not value then
    return nil
  end

  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function is_windows_host_path(path)
  if not path or path == '' then
    return false
  end

  return path:match '^/[A-Za-z]:/' ~= nil
end

local function wsl_distro_from_domain(domain_name)
  if not domain_name then
    return nil
  end

  return domain_name:match '^WSL:(.+)$'
end

local function forward_shortcut_to_pane(wezterm, window, pane, shortcut, sequence, logger, category, workspace_name)
  logger.info(category, 'forwarding shortcut to pane', {
    shortcut = shortcut,
    workspace = workspace_name,
    domain = pane:get_domain_name(),
  })
  window:perform_action(wezterm.action.SendString(sequence), pane)
end

local function managed_workspace_only_shortcut(window, logger, shortcut)
  logger.warn('workspace', 'shortcut requires a managed workspace', {
    shortcut = shortcut,
    workspace = active_workspace_name(window),
  })
  window:toast_notification('WezTerm', shortcut .. ' is only available in managed tmux workspaces', nil, 3000)
end

local function paste_clipboard_or_image_path(wezterm, window, pane, constants, logger)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  if runtime_mode ~= 'hybrid-wsl' then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local domain_name = pane:get_domain_name()
  local distro = wsl_distro_from_domain(domain_name) or wsl_distro_from_domain(constants.default_domain)
  if not distro then
    logger.info('clipboard', 'falling back to plain clipboard paste outside WSL', {
      domain = domain_name,
      runtime_mode = runtime_mode,
    })
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local integration = constants.integrations and constants.integrations.clipboard_image or {}
  local runtime_dir = integration.runtime_dir or (wezterm.config_dir .. '\\.wezterm-x')
  local script_path = integration.script or 'scripts\\export-clipboard-image-to-wsl.ps1'
  local command = {
    integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
    '-NoProfile',
    '-NonInteractive',
    '-STA',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    runtime_dir .. '\\' .. script_path,
    '-WslDistro',
    distro,
  }

  if integration.output_dir and integration.output_dir ~= '' then
    command[#command + 1] = '-OutputDir'
    command[#command + 1] = integration.output_dir
  end

  logger.info('clipboard', 'checking clipboard image export helper', {
    command = table.concat(command, ' '),
    distro = distro,
    domain = domain_name,
  })

  local ok, stdout, stderr = wezterm.run_child_process(command)
  local image_path = trim_text(stdout and stdout:gsub('\r', ''))
  local error_text = trim_text(stderr and stderr:gsub('\r', ''))

  if ok and image_path and image_path ~= '' and image_path ~= 'NO_IMAGE' then
    pane:send_paste(image_path)
    logger.info('clipboard', 'pasted exported clipboard image path', {
      distro = distro,
      domain = domain_name,
      image_path = image_path,
    })
    return
  end

  if not ok or (error_text and error_text ~= '') then
    logger.warn('clipboard', 'clipboard image export failed, falling back to plain paste', {
      distro = distro,
      domain = domain_name,
      error = error_text,
      helper_output = image_path,
    })
  else
    logger.info('clipboard', 'no clipboard image found, falling back to plain paste', {
      distro = distro,
      domain = domain_name,
    })
  end

  window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
end

local function open_current_dir_in_vscode(wezterm, window, pane, constants, logger)
  local raw_cwd = pane:get_current_working_dir()
  local cwd = file_path_from_cwd(raw_cwd)
  local domain_name = pane:get_domain_name()
  local workspace_name = active_workspace_name(window)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  local integration = constants.integrations and constants.integrations.vscode or {}

  if not cwd or cwd == '/' then
    logger.warn('alt_o', 'current pane working directory is unavailable', {
      domain = domain_name,
      raw_cwd = tostring(raw_cwd),
      workspace = workspace_name,
    })
    window:toast_notification('WezTerm', 'Alt+o failed: current pane working directory is unavailable', nil, 3000)
    return
  end

  local command
  if runtime_mode == 'hybrid-wsl' then
    local distro = wsl_distro_from_domain(domain_name) or wsl_distro_from_domain(constants.default_domain)
    if not distro then
      logger.warn('alt_o', 'current pane is not backed by a WSL domain', {
        cwd = cwd,
        domain = domain_name,
      })
      window:toast_notification('WezTerm', 'Alt+o failed: current pane is not backed by a WSL domain', nil, 3000)
      return
    end

    local hybrid_command = copy_args(integration.hybrid_wsl_command)
    if not hybrid_command or #hybrid_command == 0 then
      hybrid_command = { 'code' }
    end

    local runtime_dir = integration.runtime_dir or (wezterm.config_dir .. '\\.wezterm-x')
    local script_path = integration.script or 'scripts\\open-current-dir-in-vscode.ps1'
    command = {
      integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      runtime_dir .. '\\' .. script_path,
      '-RequestedDir',
      cwd,
      '-Distro',
      distro,
    }

    for _, part in ipairs(hybrid_command) do
      command[#command + 1] = '-CodeArg'
      command[#command + 1] = part
    end
  else
    local posix_command = copy_args(integration.posix_command)
    if not posix_command or #posix_command == 0 then
      posix_command = { 'code' }
    end

    command = {
      integration.posix_shell or '/bin/bash',
      integration.posix_script or (wezterm.config_dir .. '/scripts/runtime/open-current-dir-in-vscode.sh'),
      '--code-command',
    }

    for _, part in ipairs(posix_command) do
      command[#command + 1] = part
    end

    command[#command + 1] = '--'
    command[#command + 1] = cwd
  end

  logger.info('alt_o', 'opening current dir via WezTerm', {
    command = table.concat(command, ' '),
    cwd = cwd,
    domain = domain_name,
    runtime_mode = runtime_mode,
  })
  local ok, err = pcall(wezterm.background_child_process, command)
  if not ok then
    window:toast_notification('WezTerm', 'Alt+o failed. Check WezTerm logs.', nil, 3000)
    logger.error('alt_o', 'background_child_process failed', {
      error = err,
    })
  end
end

local function open_debug_chrome(wezterm, window, constants, logger)
  local chrome = constants.chrome_debug_browser or {}
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  local integration = constants.integrations and constants.integrations.chrome_debug or {}
  local command

  if not chrome.user_data_dir or chrome.user_data_dir == '' then
    logger.warn('chrome', 'missing chrome debug browser user_data_dir', {
      runtime_mode = runtime_mode,
    })
    window:toast_notification('WezTerm', 'Alt+b failed: configure chrome_debug_browser.user_data_dir in wezterm-x/local/constants.lua', nil, 4000)
    return
  end

  if runtime_mode == 'hybrid-wsl' then
    local runtime_dir = integration.runtime_dir or (wezterm.config_dir .. '\\.wezterm-x')
    local script_path = integration.script or 'scripts\\focus-or-start-debug-chrome.ps1'
    command = {
      integration.cmd or 'cmd.exe',
      '/c',
      integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      runtime_dir .. '\\' .. script_path,
      '-ChromePath',
      chrome.executable,
      '-RemoteDebuggingPort',
      tostring(chrome.remote_debugging_port),
      '-UserDataDir',
      chrome.user_data_dir,
    }
  else
    local runtime_dir = integration.posix_runtime_dir or (wezterm.config_dir .. '/.wezterm-x')
    local script_path = integration.posix_script or 'scripts/focus-or-start-debug-chrome.sh'
    command = {
      integration.posix_shell or '/bin/sh',
      runtime_dir .. '/' .. script_path,
      chrome.executable,
      tostring(chrome.remote_debugging_port),
      chrome.user_data_dir,
    }
  end

  logger.info('chrome', 'opening or focusing debug chrome', {
    command = table.concat(command, ' '),
    executable = chrome.executable,
    port = chrome.remote_debugging_port,
    runtime_mode = runtime_mode,
    user_data_dir = chrome.user_data_dir,
  })
  local ok, err = pcall(wezterm.background_child_process, command)
  if not ok then
    window:toast_notification('WezTerm', 'Alt+b failed. Check WezTerm logs.', nil, 3000)
    logger.error('chrome', 'background_child_process failed', {
      error = err,
    })
  end
end

function M.apply(opts)
  local wezterm = opts.wezterm
  local config = opts.config
  local constants = opts.constants
  local palette = constants.palette
  local workspace = opts.workspace
  local runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
  local logger = dofile(join_path(runtime_dir, 'lua', 'logger.lua')).new {
    wezterm = wezterm,
    constants = constants,
  }

  config.font = constants.fonts.terminal
  config.font_size = 12.0
  config.line_height = 1.0
  config.front_end = 'WebGpu'
  if constants.default_domain and constants.default_domain ~= '' then
    config.default_domain = constants.default_domain
  end
  config.notification_handling = 'NeverShow'
  config.audible_bell = 'Disabled'
  config.visual_bell = { fade_in_duration_ms = 0, fade_out_duration_ms = 0 }
  config.bypass_mouse_reporting_modifiers = 'ALT'
  -- Let focus clicks pass through so tmux/TUIs receive the first click too.
  config.swallow_mouse_click_on_window_focus = false
  config.swallow_mouse_click_on_pane_focus = false
  config.launch_menu = constants.launch_menu or {}
  local set_environment_variables = {
    COLORFGBG = '0;15',
    WEZTERM_RUNTIME_MODE = constants.runtime_mode or 'hybrid-wsl',
  }
  if constants.shell and constants.shell.program and constants.shell.program ~= '' then
    set_environment_variables.WEZTERM_MANAGED_SHELL = constants.shell.program
  end
  config.set_environment_variables = set_environment_variables

  config.window_decorations = 'RESIZE'
  config.window_padding = {
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
  }
  config.use_fancy_tab_bar = false
  config.enable_tab_bar = true
  config.show_tabs_in_tab_bar = true
  config.tab_bar_at_bottom = true
  config.tab_max_width = 24
  config.show_new_tab_button_in_tab_bar = true
  config.colors = {
    foreground = palette.foreground,
    background = palette.background,
    cursor_bg = palette.cursor_bg,
    cursor_fg = palette.cursor_fg,
    cursor_border = palette.cursor_border,
    selection_bg = palette.selection_bg,
    selection_fg = palette.selection_fg,
    scrollbar_thumb = palette.scrollbar_thumb,
    split = palette.split,
    ansi = palette.ansi,
    brights = palette.brights,
    tab_bar = {
      background = palette.tab_bar_background,
      inactive_tab_edge = palette.tab_bar_background,
      active_tab = {
        bg_color = palette.tab_active_bg,
        fg_color = palette.tab_active_fg,
      },
      inactive_tab = {
        bg_color = palette.tab_inactive_bg,
        fg_color = palette.tab_inactive_fg,
      },
      inactive_tab_hover = {
        bg_color = palette.tab_hover_bg,
        fg_color = palette.tab_hover_fg,
      },
      new_tab = {
        bg_color = palette.new_tab_bg,
        fg_color = palette.new_tab_fg,
      },
      new_tab_hover = {
        bg_color = palette.new_tab_hover_bg,
        fg_color = palette.new_tab_hover_fg,
      },
    },
  }
  config.window_frame = {
    font = constants.fonts.window,
    font_size = 10.0,
    active_titlebar_bg = palette.tab_bar_background,
    inactive_titlebar_bg = palette.tab_bar_background,
  }
  config.command_palette_bg_color = palette.background
  config.command_palette_fg_color = palette.foreground

  config.keys = {
    { key = 'v', mods = 'ALT', action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' } },
    { key = 's', mods = 'ALT', action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' } },
    {
      key = 'o',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local cwd = file_path_from_cwd(pane:get_current_working_dir())
        local workspace_name = active_workspace_name(window)
        local foreground_process = foreground_process_basename(pane)
        local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
        local distro = wsl_distro_from_domain(pane:get_domain_name()) or wsl_distro_from_domain(constants.default_domain)

        if is_managed_workspace(workspace_name) then
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+o', '\x1bo', logger, 'alt_o', workspace_name)
          return
        end

        -- Outside managed workspaces, WezTerm owns Alt+o and only delegates when its cwd view is unusable.
        if foreground_process == 'tmux' and (not cwd or cwd == '/') then
          logger.info('alt_o', 'forwarding Alt+o to pane fallback', {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          })
          window:perform_action(wezterm.action.SendString '\x1bo', pane)
          return
        end

        if runtime_mode == 'hybrid-wsl' and distro and is_windows_host_path(cwd) then
          logger.info('alt_o', 'forwarding Alt+o to pane fallback', {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          })
          window:perform_action(wezterm.action.SendString '\x1bo', pane)
          return
        end

        open_current_dir_in_vscode(wezterm, window, pane, constants, logger)
      end),
    },
    {
      key = 'g',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = active_workspace_name(window)
        if is_managed_workspace(workspace_name) then
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+g', '\x1bg', logger, 'workspace', workspace_name)
          return
        end

        managed_workspace_only_shortcut(window, logger, 'Alt+g')
      end),
    },
    {
      key = 'G',
      mods = 'ALT|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = active_workspace_name(window)
        if is_managed_workspace(workspace_name) then
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+Shift+g', '\x1bG', logger, 'workspace', workspace_name)
          return
        end

        managed_workspace_only_shortcut(window, logger, 'Alt+Shift+g')
      end),
    },
    {
      key = 'b',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        open_debug_chrome(wezterm, window, constants, logger)
      end),
    },
    {
      key = 'k',
      mods = 'CTRL',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = active_workspace_name(window)
        local foreground_process = foreground_process_basename(pane)

        if is_managed_workspace(workspace_name) or foreground_process == 'tmux' then
          forward_shortcut_to_pane(wezterm, window, pane, 'Ctrl+k', '\x0b', logger, 'command_panel', workspace_name)
          return
        end

        logger.warn('command_panel', 'shortcut requires tmux in current pane', {
          foreground_process = foreground_process,
          workspace = workspace_name,
        })
        window:toast_notification('WezTerm', 'Ctrl+k is only available when the current pane is running tmux', nil, 3000)
      end),
    },
    workspace_keybinding(wezterm, workspace, 'w', 'work'),
    {
      key = 'd',
      mods = 'ALT',
      action = wezterm.action.SwitchToWorkspace { name = 'default' },
    },
    {
      key = 'p',
      mods = 'ALT',
      action = wezterm.action.SwitchWorkspaceRelative(1),
    },
    workspace_keybinding(wezterm, workspace, 'c', 'config'),
    {
      key = 'X',
      mods = 'ALT|SHIFT',
      action = wezterm.action.Confirmation {
        message = '🛑 Close the current workspace?',
        action = wezterm.action_callback(function(window, pane)
          workspace.close(window, pane)
        end),
      },
    },
    {
      key = 'Q',
      mods = 'ALT|SHIFT',
      action = wezterm.action.QuitApplication,
    },
    {
      key = 'c',
      mods = 'CTRL',
      action = wezterm.action_callback(function(window, pane)
        local has_selection = window:get_selection_text_for_pane(pane) ~= ''
        if has_selection then
          window:perform_action(wezterm.action.CopyTo 'Clipboard', pane)
          window:perform_action(wezterm.action.ClearSelection, pane)
        else
          window:perform_action(wezterm.action.SendString '\003', pane)
        end
      end),
    },
    {
      key = 'c',
      mods = 'CTRL|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local has_selection = window:get_selection_text_for_pane(pane) ~= ''
        if has_selection then
          window:perform_action(wezterm.action.CopyTo 'Clipboard', pane)
          window:perform_action(wezterm.action.ClearSelection, pane)
        else
          window:perform_action(wezterm.action.SendKey { key = 'c', mods = 'CTRL|SHIFT' }, pane)
        end
      end),
    },
    {
      key = 'v',
      mods = 'CTRL',
      action = wezterm.action_callback(function(window, pane)
        paste_clipboard_or_image_path(wezterm, window, pane, constants, logger)
      end),
    },
    {
      key = 'v',
      mods = 'CTRL|SHIFT',
      action = wezterm.action.PasteFrom 'Clipboard',
    },
  }

  config.mouse_bindings = {
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = wezterm.action.OpenLinkAtMouseCursor,
    },
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = wezterm.action.Nop,
    },
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      mouse_reporting = true,
      action = wezterm.action.OpenLinkAtMouseCursor,
    },
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      mouse_reporting = true,
      action = wezterm.action.Nop,
    },
  }

  config.default_cursor_style = 'BlinkingBlock'
  config.cursor_blink_rate = 600
  config.use_ime = true
  config.ime_preedit_rendering = 'Builtin'
  config.cell_width = 1.0
end

return M
