local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local module_dir = join_path(rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.', 'lua', 'ui')
local common = dofile(join_path(module_dir, 'common.lua'))
local actions = dofile(join_path(module_dir, 'actions.lua'))

local M = {}

function M.build(opts)
  local wezterm = opts.wezterm
  local workspace = opts.workspace
  local constants = opts.constants
  local logger = opts.logger
  local host = opts.host

  return {
    {
      key = 'v',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('alt_o')
        local cwd = common.file_path_from_cwd(pane:get_current_working_dir())
        local workspace_name = common.active_workspace_name(window)
        local foreground_process = common.foreground_process_basename(pane)
        local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
        local distro = common.wsl_distro_from_domain(pane:get_domain_name()) or common.wsl_distro_from_domain(constants.default_domain)
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)

        if tmux_backed then
          logger.info('alt_o', 'forwarding Alt+v to tmux-backed pane', common.merge_fields(trace_id, {
            cwd = cwd,
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
            workspace = workspace_name,
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Alt+v', '\x1bv', logger, 'alt_o', workspace_name, trace_id)
          return
        end

        if foreground_process == 'tmux' and (not cwd or cwd == '/') then
          logger.info('alt_o', 'forwarding Alt+v to pane fallback', common.merge_fields(trace_id, {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          }))
          window:perform_action(wezterm.action.SendString '\x1bv', pane)
          return
        end

        if runtime_mode == 'hybrid-wsl' and distro and common.is_windows_host_path(cwd) then
          logger.info('alt_o', 'forwarding Alt+v to pane fallback', common.merge_fields(trace_id, {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          }))
          window:perform_action(wezterm.action.SendString '\x1bv', pane)
          return
        end

        actions.open_current_dir_in_vscode(wezterm, window, pane, constants, logger, trace_id, host)
      end),
    },
    {
      key = 'g',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('workspace')
        local workspace_name = common.active_workspace_name(window)
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)
        if tmux_backed then
          logger.info('workspace', 'forwarding Alt+g to tmux-backed pane', common.merge_fields(trace_id, {
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            workspace = workspace_name,
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Alt+g', '\x1bg', logger, 'workspace', workspace_name, trace_id)
          return
        end

        actions.tmux_only_shortcut(window, logger, 'Alt+g', trace_id)
      end),
    },
    {
      key = 'G',
      mods = 'ALT|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('workspace')
        local workspace_name = common.active_workspace_name(window)
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)
        if tmux_backed then
          logger.info('workspace', 'forwarding Alt+Shift+g to tmux-backed pane', common.merge_fields(trace_id, {
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            workspace = workspace_name,
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Alt+Shift+g', '\x1bG', logger, 'workspace', workspace_name, trace_id)
          return
        end

        actions.tmux_only_shortcut(window, logger, 'Alt+Shift+g', trace_id)
      end),
    },
    {
      key = 'b',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('chrome')
        actions.open_debug_chrome(wezterm, window, constants, logger, trace_id, host)
      end),
    },
    {
      key = 'P',
      mods = 'CTRL|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = common.active_workspace_name(window)
        local trace_id = logger.trace_id('command_panel')
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)
        local foreground_process = common.foreground_process_basename(pane)

        if tmux_backed then
          logger.info('command_panel', 'forwarding Ctrl+Shift+P to tmux command palette via tmux user-key transport', common.merge_fields(trace_id, {
            decision_path = decision_path,
            transport = 'User0',
            foreground_process = foreground_process,
            workspace = workspace_name,
            domain = pane:get_domain_name(),
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Ctrl+Shift+P', '\x1b[20099~', logger, 'command_panel', workspace_name, trace_id)
          return
        end

        logger.info('command_panel', 'falling back to wezterm native command palette', common.merge_fields(trace_id, {
          decision_path = 'wezterm_native_palette',
          foreground_process = foreground_process,
          workspace = workspace_name,
          domain = pane:get_domain_name(),
        }))
        window:perform_action(wezterm.action.ActivateCommandPalette, pane)
      end),
    },
    {
      key = 'k',
      mods = 'CTRL',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = common.active_workspace_name(window)
        local trace_id = logger.trace_id('command_panel')
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)
        local foreground_process = common.foreground_process_basename(pane)

        if tmux_backed then
          logger.info('command_panel', 'forwarding Ctrl+k to tmux chord handler', common.merge_fields(trace_id, {
            decision_path = decision_path,
            foreground_process = foreground_process,
            workspace = workspace_name,
            domain = pane:get_domain_name(),
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Ctrl+k', '\x0b', logger, 'command_panel', workspace_name, trace_id)
          return
        end

        logger.warn('command_panel', 'shortcut requires tmux in current pane', common.merge_fields(trace_id, {
          foreground_process = foreground_process,
          workspace = workspace_name,
        }))
        window:toast_notification('WezTerm', 'Ctrl+k chords are only available when the current pane is running tmux', nil, 3000)
      end),
    },
    {
      key = ';',
      mods = 'CTRL|SHIFT',
      action = wezterm.action.ActivateCommandPalette,
    },
    {
      key = ':',
      mods = 'CTRL|SHIFT',
      action = wezterm.action.ActivateCommandPalette,
    },
    actions.workspace_keybinding(wezterm, workspace, 'w', 'work'),
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
    actions.workspace_keybinding(wezterm, workspace, 'c', 'config'),
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
        local trace_id = logger.trace_id('clipboard')
        actions.paste_clipboard_or_image_path(wezterm, window, pane, constants, logger, trace_id, host)
      end),
    },
    {
      key = 'v',
      mods = 'CTRL|SHIFT',
      action = wezterm.action.PasteFrom 'Clipboard',
    },
  }
end

return M
