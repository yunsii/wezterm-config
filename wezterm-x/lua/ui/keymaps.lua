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
  local attention = opts.attention
  local usage = opts.usage

  -- Wrap a keymap entry so pressing the key first fires a fire-and-forget
  -- bump to the aggregate counter, then performs the original action. The
  -- bump is non-blocking, so the nested perform_action path still receives
  -- focus events in the same frame as an un-instrumented binding would.
  local function inst(hotkey_id, entry)
    if not usage or not usage.bump then return entry end
    local original_action = entry.action
    entry.action = wezterm.action_callback(function(window, pane)
      usage.bump(hotkey_id, { window = window, pane = pane })
      window:perform_action(original_action, pane)
    end)
    return entry
  end

  local function attention_jump_args(trailing_args, pane_ref, trace_id)
    return actions.attention_jump_args(constants, pane_ref, trailing_args, logger, trace_id)
  end

  -- Build fast-path args when the entry carries tmux coordinates. The
  -- caller will have already activated the WezTerm pane via the mux, so
  -- the script only needs to sync tmux selection — no state re-read, no
  -- jq, no wezterm.exe round-trip. Falls back to `--session` when the
  -- coordinates are missing (legacy entries without tmux bootstrap).
  local function attention_direct_args(entry, pane_ref, trace_id)
    local socket = entry.tmux_socket
    local window = entry.tmux_window
    if type(socket) == 'string' and socket ~= ''
      and type(window) == 'string' and window ~= '' then
      local trailing = {
        '--direct',
        '--tmux-socket', socket,
        '--tmux-window', window,
      }
      if type(entry.tmux_pane) == 'string' and entry.tmux_pane ~= '' then
        table.insert(trailing, '--tmux-pane')
        table.insert(trailing, entry.tmux_pane)
      end
      return attention_jump_args(trailing, pane_ref, trace_id)
    end
    return attention_jump_args({ '--session', entry.session_id }, pane_ref, trace_id)
  end

  -- Immediate auto-forget after a successful jump to a `done` entry —
  -- the jump itself is the acknowledgement, so the entry goes away
  -- without a grace window. The --only-if-ts guard still protects the
  -- ~50ms race where a fresher `done` (same session_id, new ts) could
  -- land between Lua scheduling and the subprocess executing.
  local function attention_forget_args(entry, pane_ref, trace_id)
    if not entry or type(entry.session_id) ~= 'string' or entry.session_id == '' then
      return nil
    end
    local trailing = {
      '--forget', entry.session_id,
    }
    if entry.ts ~= nil and tostring(entry.ts) ~= '' then
      table.insert(trailing, '--only-if-ts')
      table.insert(trailing, tostring(entry.ts))
    end
    return attention_jump_args(trailing, pane_ref, trace_id)
  end

  local entries = {
    {
      key = 'v',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('vscode')
        local cwd = common.file_path_from_cwd(pane:get_current_working_dir())
        local workspace_name = common.active_workspace_name(window)
        local foreground_process = common.foreground_process_basename(pane)
        local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
        local distro = common.wsl_distro_from_domain(pane:get_domain_name()) or common.wsl_distro_from_domain(constants.default_domain)
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)

        if tmux_backed then
          logger.info('vscode', 'forwarding Alt+v to tmux-backed pane', common.merge_fields(trace_id, {
            cwd = cwd,
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
            workspace = workspace_name,
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Alt+v', '\x1bv', logger, 'vscode', workspace_name, trace_id)
          return
        end

        if foreground_process == 'tmux' and (not cwd or cwd == '/') then
          logger.info('vscode', 'forwarding Alt+v to pane fallback', common.merge_fields(trace_id, {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          }))
          window:perform_action(wezterm.action.SendString '\x1bv', pane)
          return
        end

        if runtime_mode == 'hybrid-wsl' and distro and common.is_windows_host_path(cwd) then
          logger.info('vscode', 'forwarding Alt+v to pane fallback', common.merge_fields(trace_id, {
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
        actions.open_debug_chrome(wezterm, window, constants, logger, trace_id, host, true)
      end),
    },
    {
      key = 'B',
      mods = 'ALT|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('chrome')
        actions.open_debug_chrome(wezterm, window, constants, logger, trace_id, host, false)
      end),
    },
    {
      key = 'o',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('command_panel')
        local workspace_name = common.active_workspace_name(window)
        local tmux_backed, decision_path = actions.is_tmux_backed_pane(constants, window, pane)
        if tmux_backed then
          logger.info('command_panel', 'forwarding Alt+o to tmux-backed pane', common.merge_fields(trace_id, {
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            workspace = workspace_name,
          }))
          actions.forward_shortcut_to_pane(wezterm, window, pane, 'Alt+o', '\x1bo', logger, 'command_panel', workspace_name, trace_id)
          return
        end

        actions.tmux_only_shortcut(window, logger, 'Alt+o', trace_id)
      end),
    },
    {
      key = 'n',
      mods = 'ALT',
      action = wezterm.action.ActivateTabRelative(1),
    },
    {
      key = 'N',
      mods = 'ALT|SHIFT',
      action = wezterm.action.ActivateTabRelative(-1),
    },
    {
      key = ',',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('attention')
        if not attention then return end
        attention.reload_state()
        local current_pane_id = pane and pane:pane_id() or nil
        local entry = attention.pick_next(attention.STATUS_WAITING, current_pane_id)
        if not entry then
          return
        end
        logger.info('attention', 'alt-comma jump', {
          trace = trace_id,
          session_id = entry.session_id,
          wezterm_pane_id = entry.wezterm_pane_id,
        })
        attention.activate_in_gui(entry.wezterm_pane_id, window, pane)
        local args = attention_direct_args(entry, pane, trace_id)
        if args then wezterm.background_child_process(args) end
      end),
    },
    {
      key = '.',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('attention')
        if not attention then return end
        attention.reload_state()
        local current_pane_id = pane and pane:pane_id() or nil
        local entry = attention.pick_next(attention.STATUS_DONE, current_pane_id)
        if not entry then
          return
        end
        logger.info('attention', 'alt-dot jump', {
          trace = trace_id,
          session_id = entry.session_id,
          wezterm_pane_id = entry.wezterm_pane_id,
        })
        local activated = attention.activate_in_gui(entry.wezterm_pane_id, window, pane)
        local args = attention_direct_args(entry, pane, trace_id)
        if args then wezterm.background_child_process(args) end
        if activated then
          local forget_args = attention_forget_args(entry, pane, trace_id)
          if forget_args then wezterm.background_child_process(forget_args) end
        end
      end),
    },
    {
      key = '/',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('attention')
        if not attention then
          return
        end
        attention.reload_state()
        local entries = attention.list()
        if #entries == 0 then
          window:toast_notification('WezTerm', 'No pending agent attention', nil, 2000)
          return
        end

        local function format_age(ms)
          local s = math.floor((tonumber(ms) or 0) / 1000)
          if s < 60 then return s .. 's' end
          local m = math.floor(s / 60)
          if m < 60 then return m .. 'm' end
          local h = math.floor(m / 60)
          return h .. 'h'
        end

        local function nonempty(value)
          if value == nil then return false end
          if type(value) ~= 'string' then return true end
          return value ~= ''
        end

        local choices = {}
        for _, entry in ipairs(entries) do
          local marker
          if entry.status == attention.STATUS_WAITING then
            marker = '⚠'
          elseif entry.status == attention.STATUS_RUNNING then
            marker = '⟳'
          else
            marker = '✓'
          end
          local reason = nonempty(entry.reason) and entry.reason or entry.status

          local live = entry.live or {}
          local workspace_seg = nonempty(live.workspace) and live.workspace or '?'
          local tab_seg = '?'
          if live.tab_index then
            tab_seg = tostring(live.tab_index)
            if nonempty(live.tab_title) then
              tab_seg = tab_seg .. '_' .. live.tab_title
            end
          end
          local function strip_tmux_prefix(value)
            if type(value) ~= 'string' then return value end
            return (value:gsub('^[@%%]', ''))
          end
          local tmux_seg = '?'
          if nonempty(entry.tmux_window) then
            tmux_seg = strip_tmux_prefix(entry.tmux_window)
            if nonempty(entry.tmux_pane) then
              tmux_seg = tmux_seg .. '_' .. strip_tmux_prefix(entry.tmux_pane)
            end
          end
          local branch_seg = nonempty(entry.git_branch) and entry.git_branch or '?'

          local prefix = nil
          if workspace_seg ~= '?' or tab_seg ~= '?' or tmux_seg ~= '?' or branch_seg ~= '?' then
            prefix = workspace_seg .. '/' .. tab_seg .. '/' .. tmux_seg .. '/' .. branch_seg
          end

          local label
          if prefix then
            label = prefix .. '  ' .. marker .. ' ' .. reason
          else
            label = marker .. ' ' .. reason
          end
          local age_text = format_age(entry.age_ms)
          if not nonempty(entry.wezterm_pane_id) then
            age_text = age_text .. ', no pane'
          end
          label = label .. '  (' .. age_text .. ')'
          table.insert(choices, { label = label, id = entry.session_id })
        end

        local clear_all_sentinel = '__clear_all__'
        table.insert(choices, {
          label = '——  clear all · ' .. #entries .. ' entries  ——',
          id = clear_all_sentinel,
        })

        local function inject_tick(inner_pane)
          local tick
          local ok_b64, encoded = pcall(wezterm.encode_base64, tostring(os.time()))
          if ok_b64 and type(encoded) == 'string' then
            tick = encoded
          else
            tick = ''
          end
          local osc = '\027]1337;SetUserVar=attention_tick=' .. tick .. '\007'
          pcall(function() inner_pane:inject_output(osc) end)
        end

        window:perform_action(
          wezterm.action.InputSelector {
            title = 'Agent attention',
            choices = choices,
            fuzzy = true,
            action = wezterm.action_callback(function(inner_window, inner_pane, chosen_id, chosen_label)
              if not chosen_id or chosen_id == '' then
                return
              end

              if chosen_id == clear_all_sentinel then
                local args = attention_jump_args({ '--clear-all' }, inner_pane, trace_id)
                if not args then
                  return
                end
                logger.info('attention', 'alt-slash clear-all', { trace = trace_id })
                wezterm.run_child_process(args)
                if attention.reload_state then
                  attention.reload_state()
                end
                inject_tick(inner_pane)
                return
              end

              local chosen_entry
              for _, candidate in ipairs(entries) do
                if candidate.session_id == chosen_id then
                  chosen_entry = candidate
                  break
                end
              end
              local activated = false
              if chosen_entry then
                activated = attention.activate_in_gui(chosen_entry.wezterm_pane_id, inner_window, inner_pane)
              end

              local args
              if chosen_entry then
                args = attention_direct_args(chosen_entry, inner_pane, trace_id)
              else
                args = attention_jump_args({ '--session', chosen_id }, inner_pane, trace_id)
              end
              if not args then
                return
              end
              logger.info('attention', 'alt-slash jump', {
                trace = trace_id,
                session_id = chosen_id,
              })
              wezterm.background_child_process(args)
              if activated and chosen_entry and chosen_entry.status == attention.STATUS_DONE then
                local forget_args = attention_forget_args(chosen_entry, inner_pane, trace_id)
                if forget_args then wezterm.background_child_process(forget_args) end
              end
            end),
          },
          pane
        )
      end),
    },
    {
      key = '1',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(0),
    },
    {
      key = '2',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(1),
    },
    {
      key = '3',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(2),
    },
    {
      key = '4',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(3),
    },
    {
      key = '5',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(4),
    },
    {
      key = '6',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(5),
    },
    {
      key = '7',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(6),
    },
    {
      key = '8',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(7),
    },
    {
      key = '9',
      mods = 'ALT',
      action = wezterm.action.ActivateTab(8),
    },
    {
      key = 'l',
      mods = 'ALT',
      action = wezterm.action.QuickSelectArgs {
        label = 'open url',
        patterns = {
          'https?://\\S+',
        },
        action = wezterm.action_callback(function(window, pane)
          local url = window:get_selection_text_for_pane(pane)
          if not url or url == '' then
            return
          end
          local trace_id = logger.trace_id('link')
          logger.info('link', 'opening url via QuickSelect', common.merge_fields(trace_id, { url = url }))
          wezterm.open_with(url)
        end),
      },
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

  -- Paired with `entries` above in 1:1 order. When you add / remove /
  -- reorder an entry, update this list. Unknown ids still render in the
  -- report (as `(unregistered)`), but they won't cross-reference to
  -- manifest.json labels.
  local entry_ids = {
    'vscode.open-current-dir',          -- Alt+v
    'worktree.picker',                  -- Alt+g
    'worktree.cycle-next',              -- Alt+Shift+G
    'chrome.open-debug-profile',        -- Alt+b
    'pane.rotate-next',                 -- Alt+o
    'tab.next',                         -- Alt+n
    'tab.previous',                     -- Alt+Shift+N
    'attention.jump-waiting',           -- Alt+,
    'attention.jump-done',              -- Alt+.
    'attention.overlay',                -- Alt+/
    'tab.select-by-index',              -- Alt+1
    'tab.select-by-index',              -- Alt+2
    'tab.select-by-index',              -- Alt+3
    'tab.select-by-index',              -- Alt+4
    'tab.select-by-index',              -- Alt+5
    'tab.select-by-index',              -- Alt+6
    'tab.select-by-index',              -- Alt+7
    'tab.select-by-index',              -- Alt+8
    'tab.select-by-index',              -- Alt+9
    'link.open-in-viewport',            -- Alt+l
    'command-palette.open',             -- Ctrl+Shift+P
    'command-palette.chord-prefix',     -- Ctrl+k
    'command-palette.open-native',      -- Ctrl+Shift+;
    'command-palette.open-native',      -- Ctrl+Shift+:
    'workspace.switch-work',            -- Alt+w
    'workspace.switch-default',         -- Alt+d
    'workspace.cycle-next',             -- Alt+p
    'workspace.switch-config',          -- Alt+c
    'workspace.close-current',          -- Alt+Shift+X
    'app.quit',                         -- Alt+Shift+Q
    'clipboard.copy-or-sigint',         -- Ctrl+c
    'clipboard.copy-selection-strict',  -- Ctrl+Shift+C
    'clipboard.paste-smart',            -- Ctrl+v
    'clipboard.paste-plain',            -- Ctrl+Shift+V
  }

  if #entries ~= #entry_ids then
    logger.warn('usage', 'keymap entries/entry_ids length mismatch', {
      entries = #entries,
      entry_ids = #entry_ids,
    })
  end

  for i, entry in ipairs(entries) do
    inst(entry_ids[i], entry)
  end
  return entries
end

return M
