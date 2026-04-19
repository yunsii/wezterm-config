local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local function current_runtime_dir(config_dir)
  local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
  if runtime_dir and runtime_dir ~= '' then
    return runtime_dir
  end

  return join_path(config_dir, '.wezterm-x')
end

local function windows_path_to_wsl_path(path)
  if not path or path == '' then
    return nil
  end

  local normalized = tostring(path):gsub('\\', '/')
  local drive, remainder = normalized:match '^([A-Za-z]):/?(.*)$'
  if not drive then
    return normalized
  end

  drive = drive:lower()
  if remainder == '' then
    return '/mnt/' .. drive
  end

  return '/mnt/' .. drive .. '/' .. remainder
end

local function read_runtime_metadata_file(filename)
  local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
  if not runtime_dir or runtime_dir == '' then
    return nil
  end

  local file = io.open(join_path(runtime_dir, filename), 'r')
  if not file then
    return nil
  end

  local value = file:read '*l'
  file:close()
  if not value then
    return nil
  end

  value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' then
    return nil
  end

  return value
end

local function runtime_script_roots(constants)
  local roots = {}
  local seen = {}

  for _, root in ipairs {
    constants.repo_root,
    constants.main_repo_root,
    read_runtime_metadata_file 'repo-root.txt',
    read_runtime_metadata_file 'repo-main-root.txt',
  } do
    if root and root ~= '' and not seen[root] then
      roots[#roots + 1] = root
      seen[root] = true
    end
  end

  return roots
end

local function wsl_distro_from_domain(domain_name)
  if not domain_name then
    return nil
  end

  return domain_name:match '^WSL:(.+)$'
end

local function default_wsl_tmux_program(constants)
  if constants.runtime_mode ~= 'hybrid-wsl' or constants.host_os ~= 'windows' then
    return nil
  end

  if not constants.default_domain or constants.default_domain == '' then
    return nil
  end

  local roots = runtime_script_roots(constants)
  if #roots == 0 then
    return nil
  end

  local primary_script = roots[1] and (roots[1] .. '/scripts/runtime/open-default-shell-session.sh') or ''
  local fallback_script = roots[2] and (roots[2] .. '/scripts/runtime/open-default-shell-session.sh') or ''

  return {
    '/bin/sh',
    '-lc',
    [[
primary_script="$1"
fallback_script="$2"
cwd="${PWD:-}"
if [ -z "$cwd" ] || printf '%s' "$cwd" | grep -Eq '^/mnt/[a-z]/Users/[^/]+$'; then
  cwd="$HOME"
fi
shift 2

run_script() {
  script_path="$1"
  shift

  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    exec bash "$script_path" "$@"
  fi
}

run_script "$primary_script" "$cwd"
run_script "$fallback_script" "$cwd"

printf 'Default WSL tmux runtime script is unavailable: %s\n' "$primary_script" >&2
if [ -n "$fallback_script" ]; then
  printf 'Fallback default WSL tmux runtime script is unavailable: %s\n' "$fallback_script" >&2
fi
exit 1
    ]],
    'sh',
    primary_script,
    fallback_script,
  }
end

local function configured_wsl_domains(wezterm, constants)
  local ok, domains = pcall(wezterm.default_wsl_domains)
  if not ok or type(domains) ~= 'table' then
    return nil
  end

  local default_program = default_wsl_tmux_program(constants)
  if not default_program then
    return domains
  end

  local target_distro = wsl_distro_from_domain(constants.default_domain)
  if not target_distro or target_distro == '' then
    return domains
  end

  local configured = {}
  local matched = false
  for _, domain in ipairs(domains) do
    local item = {}
    for key, value in pairs(domain) do
      item[key] = value
    end
    if item.name == constants.default_domain or item.distribution == target_distro then
      local program = {}
      for _, part in ipairs(default_program) do
        program[#program + 1] = part
      end
      item.default_prog = program
      matched = true
    end
    configured[#configured + 1] = item
  end

  if not matched and wezterm.log_warn then
    wezterm.log_warn(
      'default WSL tmux program was not applied because no WSL domain matched default_domain='
        .. tostring(constants.default_domain)
        .. ' distribution='
        .. tostring(target_distro)
    )
  end

  return configured
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

local function is_tmux_backed_pane(constants, window, pane)
  local workspace_name = active_workspace_name(window)
  if is_managed_workspace(workspace_name) then
    return true, 'managed_workspace'
  end

  if constants.runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    local domain_name = pane and pane:get_domain_name() or nil
    if wsl_distro_from_domain(domain_name) then
      return true, 'hybrid_wsl_domain'
    end
  end

  local foreground_process = foreground_process_basename(pane)
  if foreground_process == 'tmux' then
    return true, 'foreground_tmux'
  end

  return false, 'not_tmux_backed'
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

local function trim(text)
  if not text then
    return ''
  end

  return (tostring(text):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function merge_fields(trace_id, fields)
  local merged = {}

  for key, value in pairs(fields or {}) do
    merged[key] = value
  end
  if trace_id and trace_id ~= '' then
    merged.trace_id = trace_id
  end

  return merged
end

local function runtime_script_command(constants, script_rel_path, script_args, trace_id)
  local roots = runtime_script_roots(constants)
  local primary_script = roots[1] and (roots[1] .. '/' .. script_rel_path) or ''
  local fallback_script = roots[2] and (roots[2] .. '/' .. script_rel_path) or ''
  local runner = [[
primary_script="${WEZTERM_RUNTIME_PRIMARY_SCRIPT:-}"
fallback_script="${WEZTERM_RUNTIME_FALLBACK_SCRIPT:-}"
trace_id="${WEZTERM_RUNTIME_TRACE_ID:-}"

run_script() {
  script_path="$1"
  shift

  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    if [ -n "$trace_id" ]; then
      exec env WEZTERM_RUNTIME_TRACE_ID="$trace_id" bash "$script_path" "$@"
    fi
    exec bash "$script_path" "$@"
  fi
}

run_script "$primary_script" "$@"
run_script "$fallback_script" "$@"

printf 'Runtime script is unavailable: %s\n' "$primary_script" >&2
if [ -n "$fallback_script" ]; then
  printf 'Fallback runtime script is unavailable: %s\n' "$fallback_script" >&2
fi
exit 1
    ]]
  local command

  if constants.runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    local distro = wsl_distro_from_domain(constants.default_domain)
    primary_script = windows_path_to_wsl_path(primary_script) or ''
    fallback_script = windows_path_to_wsl_path(fallback_script) or ''
    local script_to_run = primary_script
    if script_to_run == '' then
      script_to_run = fallback_script
    end
    command = { 'wsl.exe' }
    if distro and distro ~= '' then
      command[#command + 1] = '-d'
      command[#command + 1] = distro
    end
    command[#command + 1] = '--'
    if script_to_run == '' then
      command[#command + 1] = 'bash'
      command[#command + 1] = '-lc'
      command[#command + 1] = "printf 'Runtime script is unavailable\\n' >&2; exit 1"
    else
      command[#command + 1] = 'env'
      command[#command + 1] = 'WEZTERM_RUNTIME_TRACE_ID=' .. (trace_id or '')
      command[#command + 1] = 'bash'
      command[#command + 1] = script_to_run
    end
  else
    command = {
      'env',
      'WEZTERM_RUNTIME_PRIMARY_SCRIPT=' .. primary_script,
      'WEZTERM_RUNTIME_FALLBACK_SCRIPT=' .. fallback_script,
      'WEZTERM_RUNTIME_TRACE_ID=' .. (trace_id or ''),
      '/bin/sh',
      '-lc',
      runner,
      'sh',
    }
  end

  for _, value in ipairs(script_args or {}) do
    command[#command + 1] = value
  end

  return command
end

local function run_runtime_script_capture(wezterm, constants, logger, trace_id, category, script_rel_path, script_args)
  local command = runtime_script_command(constants, script_rel_path, script_args, trace_id)
  local ok, success, stdout, stderr = pcall(wezterm.run_child_process, command)
  if not ok then
    logger.warn(category, 'runtime script raised an error', merge_fields(trace_id, {
      script = script_rel_path,
      error = success,
    }))
    return nil, 'spawn_error'
  end

  if not success then
    logger.warn(category, 'runtime script failed', merge_fields(trace_id, {
      script = script_rel_path,
      stdout = stdout,
      stderr = stderr,
    }))
    return nil, 'script_failed'
  end

  return stdout or '', nil
end

local function split_nonempty_lines(text)
  local lines = {}
  local normalized = trim(text)
  if normalized == '' then
    return lines
  end

  for line in normalized:gmatch '[^\r\n]+' do
    local value = trim(line)
    if value ~= '' then
      lines[#lines + 1] = value
    end
  end

  return lines
end

local function cwd_matches_root(cwd, root)
  if not cwd or not root or cwd == '' or root == '' then
    return false
  end

  return cwd == root or cwd:match('^' .. root:gsub('([^%w])', '%%%1') .. '/')
end

local function current_managed_item(items, cwd)
  local best_item = nil
  local best_length = -1

  for _, item in ipairs(items or {}) do
    if item.cwd and cwd_matches_root(cwd, item.cwd) and #item.cwd > best_length then
      best_item = item
      best_length = #item.cwd
    end
  end

  return best_item
end

local function is_windows_host_path(path)
  if not path or path == '' then
    return false
  end

  return path:match '^/[A-Za-z]:/' ~= nil
end

local function forward_shortcut_to_pane(wezterm, window, pane, shortcut, sequence, logger, category, workspace_name, trace_id)
  logger.info(category, 'forwarding shortcut to pane', merge_fields(trace_id, {
    shortcut = shortcut,
    sequence = sequence,
    workspace = workspace_name,
    domain = pane:get_domain_name(),
  }))
  window:perform_action(wezterm.action.SendString(sequence), pane)
end

local function tmux_only_shortcut(window, logger, shortcut, trace_id)
  logger.warn('workspace', 'shortcut requires a tmux-backed pane', merge_fields(trace_id, {
    shortcut = shortcut,
    workspace = active_workspace_name(window),
  }))
  window:toast_notification('WezTerm', shortcut .. ' is only available when the current pane is running tmux', nil, 3000)
end

local function paste_clipboard_or_image_path(wezterm, window, pane, constants, logger, trace_id, host)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  if runtime_mode ~= 'hybrid-wsl' or constants.host_os ~= 'windows' then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local domain_name = pane:get_domain_name()
  local distro = wsl_distro_from_domain(domain_name) or wsl_distro_from_domain(constants.default_domain)
  if not distro then
    logger.info('clipboard', 'falling back to plain clipboard paste outside WSL', merge_fields(trace_id, {
      domain = domain_name,
      runtime_mode = runtime_mode,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local clipboard_feature = host:feature 'clipboard_image'
  if not clipboard_feature or not clipboard_feature.resolve_for_paste then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local resolved_state, resolve_reason = clipboard_feature.resolve_for_paste(trace_id)
  if not resolved_state then
    logger.warn('clipboard', 'failed to resolve clipboard state via windows helper', merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      reason = resolve_reason,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  if resolved_state.kind ~= 'image' then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local image_path = resolved_state.wsl_path
  if (not image_path or image_path == '') and resolved_state.windows_path and resolved_state.windows_path ~= '' then
    image_path = clipboard_feature.windows_path_to_wsl_path(resolved_state.windows_path)
  end

  if not image_path or image_path == '' then
    logger.warn('clipboard', 'resolved clipboard image is missing a WSL path', merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      windows_path = resolved_state.windows_path,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  if resolved_state.windows_path and resolved_state.windows_path ~= '' and not host:file_exists(resolved_state.windows_path) then
    logger.warn('clipboard', 'resolved clipboard image file is missing on disk', merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      image_path = image_path,
      windows_path = resolved_state.windows_path,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  pane:send_paste(image_path)
  logger.info('clipboard', 'pasted resolved clipboard image path', merge_fields(trace_id, {
    distro = distro,
    domain = domain_name,
    image_path = image_path,
    sequence = resolved_state.sequence,
  }))
  return
end

local function open_current_dir_in_vscode(wezterm, window, pane, constants, logger, trace_id, host)
  local raw_cwd = pane:get_current_working_dir()
  local cwd = file_path_from_cwd(raw_cwd)
  local domain_name = pane:get_domain_name()
  local workspace_name = active_workspace_name(window)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  local integration = constants.integrations and constants.integrations.vscode or {}
  local command

  if not cwd or cwd == '/' then
    logger.warn('alt_o', 'current pane working directory is unavailable', merge_fields(trace_id, {
      domain = domain_name,
      raw_cwd = tostring(raw_cwd),
      workspace = workspace_name,
    }))
    window:toast_notification('WezTerm', 'Alt+v failed: current pane working directory is unavailable', nil, 3000)
    return
  end

  if runtime_mode == 'hybrid-wsl' then
    local distro = wsl_distro_from_domain(domain_name) or wsl_distro_from_domain(constants.default_domain)
    if not distro then
      logger.warn('alt_o', 'current pane is not backed by a WSL domain', merge_fields(trace_id, {
        cwd = cwd,
        domain = domain_name,
      }))
      window:toast_notification('WezTerm', 'Alt+v failed: current pane is not backed by a WSL domain', nil, 3000)
      return
    end

    local hybrid_command = copy_args(integration.hybrid_wsl_command)
    if not hybrid_command or #hybrid_command == 0 then
      hybrid_command = { 'code' }
    end

    local helper_sent, helper_reason = host:request('vscode', trace_id, {
      cwd = cwd,
      distro = distro,
      code_command = hybrid_command,
    })
    if helper_sent then
      return
    end

    logger.error('alt_o', 'windows helper Alt+v request failed', merge_fields(trace_id, {
      reason = helper_reason,
      cwd = cwd,
      distro = distro,
    }))
    window:toast_notification('WezTerm', 'Alt+v failed. Check WezTerm logs.', nil, 3000)
    return
  else
    local posix_command = copy_args(integration.posix_command)
    if not posix_command or #posix_command == 0 then
      posix_command = { 'code' }
    end

    command = {
      'env',
      'WEZTERM_RUNTIME_TRACE_ID=' .. (trace_id or ''),
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

  logger.info('alt_o', 'opening current dir via WezTerm', merge_fields(trace_id, {
    command = table.concat(command, ' '),
    cwd = cwd,
    domain = domain_name,
    runtime_mode = runtime_mode,
  }))
  local ok, err = pcall(wezterm.background_child_process, command)
  if not ok then
    window:toast_notification('WezTerm', 'Alt+v failed. Check WezTerm logs.', nil, 3000)
    logger.error('alt_o', 'background_child_process failed', merge_fields(trace_id, {
      error = err,
    }))
  end
end

local function open_debug_chrome(wezterm, window, constants, logger, trace_id, host)
  local chrome = constants.chrome_debug_browser or {}
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'

  if not chrome.user_data_dir or chrome.user_data_dir == '' then
    logger.warn('chrome', 'missing chrome debug browser user_data_dir', merge_fields(trace_id, {
      runtime_mode = runtime_mode,
    }))
    window:toast_notification('WezTerm', 'Alt+b failed: configure chrome_debug_browser.user_data_dir in wezterm-x/local/constants.lua', nil, 4000)
    return
  end

  if runtime_mode == 'hybrid-wsl' then
    local helper_sent, helper_reason = host:request('chrome_debug', trace_id, chrome)
    if helper_sent then
      return
    end

    logger.error('chrome', 'windows helper Alt+b request failed', merge_fields(trace_id, {
      reason = helper_reason,
      runtime_mode = runtime_mode,
      port = chrome.remote_debugging_port,
      user_data_dir = chrome.user_data_dir,
    }))
    window:toast_notification('WezTerm', 'Alt+b failed. Check WezTerm logs.', nil, 3000)
    return
  end

  logger.warn('chrome', 'Alt+b is unavailable without a native host helper', merge_fields(trace_id, {
    runtime_mode = runtime_mode,
    executable = chrome.executable,
    port = chrome.remote_debugging_port,
  }))
  window:toast_notification('WezTerm', 'Alt+b is only available when a native host helper is configured.', nil, 4000)
end

function M.apply(opts)
  local wezterm = opts.wezterm
  local config = opts.config
  local constants = opts.constants
  local palette = constants.palette
  local workspace = opts.workspace
  local runtime_dir = current_runtime_dir(wezterm.config_dir)
  local helpers = dofile(join_path(runtime_dir, 'lua', 'helpers.lua'))
  local logger = dofile(join_path(runtime_dir, 'lua', 'logger.lua')).new {
    wezterm = wezterm,
    constants = constants,
  }
  local host = dofile(join_path(runtime_dir, 'lua', 'host.lua')).new {
    wezterm = wezterm,
    constants = constants,
    helpers = helpers,
    logger = logger,
  }
  local helper_prewarm_started = false

  if constants.runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    wezterm.on('gui-startup', function()
      if helper_prewarm_started then
        return
      end

      helper_prewarm_started = true
      logger.info('host_helper', 'prewarming windows helper in background', {
        reason = 'gui-startup',
      })

      local ensured, ensure_reason = host:ensure_running('gui-startup-prewarm', false)
      if ensured then
        return
      end

      logger.warn('host_helper', 'background prewarm for windows helper failed', {
        reason = 'gui-startup',
        ensure_reason = ensure_reason,
      })
    end)
  end

  config.font = constants.fonts.terminal
  config.font_size = 12.0
  config.line_height = 1.0
  config.front_end = 'WebGpu'
  if constants.default_domain and constants.default_domain ~= '' then
    config.default_domain = constants.default_domain
  end
  local default_program = default_wsl_tmux_program(constants)
  if default_program then
    config.default_prog = default_program
  end
  local wsl_domains = configured_wsl_domains(wezterm, constants)
  if wsl_domains then
    config.wsl_domains = wsl_domains
  end
  config.notification_handling = 'NeverShow'
  config.audible_bell = 'Disabled'
  config.visual_bell = { fade_in_duration_ms = 0, fade_out_duration_ms = 0 }
  -- Park mouse-reporting bypass on a rarely used modifier; pane-local selection
  -- should stay tmux-owned instead of exposing a terminal-wide drag path.
  config.bypass_mouse_reporting_modifiers = 'SUPER'
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
    {
      key = 'v',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('alt_o')
        local cwd = file_path_from_cwd(pane:get_current_working_dir())
        local workspace_name = active_workspace_name(window)
        local foreground_process = foreground_process_basename(pane)
        local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
        local distro = wsl_distro_from_domain(pane:get_domain_name()) or wsl_distro_from_domain(constants.default_domain)
        local tmux_backed, decision_path = is_tmux_backed_pane(constants, window, pane)

        if tmux_backed then
          logger.info('alt_o', 'forwarding Alt+v to tmux-backed pane', merge_fields(trace_id, {
            cwd = cwd,
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
            workspace = workspace_name,
          }))
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+v', '\x1bv', logger, 'alt_o', workspace_name, trace_id)
          return
        end

        -- Outside tmux-backed panes, WezTerm owns Alt+v and only delegates when its cwd view is unusable.
        if foreground_process == 'tmux' and (not cwd or cwd == '/') then
          logger.info('alt_o', 'forwarding Alt+v to pane fallback', merge_fields(trace_id, {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          }))
          window:perform_action(wezterm.action.SendString '\x1bv', pane)
          return
        end

        if runtime_mode == 'hybrid-wsl' and distro and is_windows_host_path(cwd) then
          logger.info('alt_o', 'forwarding Alt+v to pane fallback', merge_fields(trace_id, {
            cwd = cwd,
            domain = pane:get_domain_name(),
            foreground_process = foreground_process,
          }))
          window:perform_action(wezterm.action.SendString '\x1bv', pane)
          return
        end

        open_current_dir_in_vscode(wezterm, window, pane, constants, logger, trace_id, host)
      end),
    },
    {
      key = 'g',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('workspace')
        local workspace_name = active_workspace_name(window)
        local tmux_backed, decision_path = is_tmux_backed_pane(constants, window, pane)
        if tmux_backed then
          logger.info('workspace', 'forwarding Alt+g to tmux-backed pane', merge_fields(trace_id, {
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            workspace = workspace_name,
          }))
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+g', '\x1bg', logger, 'workspace', workspace_name, trace_id)
          return
        end

        tmux_only_shortcut(window, logger, 'Alt+g', trace_id)
      end),
    },
    {
      key = 'G',
      mods = 'ALT|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('workspace')
        local workspace_name = active_workspace_name(window)
        local tmux_backed, decision_path = is_tmux_backed_pane(constants, window, pane)
        if tmux_backed then
          logger.info('workspace', 'forwarding Alt+Shift+g to tmux-backed pane', merge_fields(trace_id, {
            decision_path = decision_path,
            domain = pane:get_domain_name(),
            workspace = workspace_name,
          }))
          forward_shortcut_to_pane(wezterm, window, pane, 'Alt+Shift+g', '\x1bG', logger, 'workspace', workspace_name, trace_id)
          return
        end

        tmux_only_shortcut(window, logger, 'Alt+Shift+g', trace_id)
      end),
    },
    {
      key = 'b',
      mods = 'ALT',
      action = wezterm.action_callback(function(window, pane)
        local trace_id = logger.trace_id('chrome')
        open_debug_chrome(wezterm, window, constants, logger, trace_id, host)
      end),
    },
    {
      key = 'P',
      mods = 'CTRL|SHIFT',
      action = wezterm.action_callback(function(window, pane)
        local workspace_name = active_workspace_name(window)
        local trace_id = logger.trace_id('command_panel')
        local tmux_backed, decision_path = is_tmux_backed_pane(constants, window, pane)
        local foreground_process = foreground_process_basename(pane)

        if tmux_backed then
          logger.info('command_panel', 'forwarding Ctrl+Shift+P to tmux command palette via tmux user-key transport', merge_fields(trace_id, {
            decision_path = decision_path,
            transport = 'User0',
            foreground_process = foreground_process,
            workspace = workspace_name,
            domain = pane:get_domain_name(),
          }))
          forward_shortcut_to_pane(wezterm, window, pane, 'Ctrl+Shift+P', '\x1b[20099~', logger, 'command_panel', workspace_name, trace_id)
          return
        end

        logger.info('command_panel', 'falling back to wezterm native command palette', merge_fields(trace_id, {
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
        local workspace_name = active_workspace_name(window)
        local trace_id = logger.trace_id('command_panel')
        local tmux_backed, decision_path = is_tmux_backed_pane(constants, window, pane)
        local foreground_process = foreground_process_basename(pane)

        if tmux_backed then
          logger.info('command_panel', 'forwarding Ctrl+k to tmux chord handler', merge_fields(trace_id, {
            decision_path = decision_path,
            foreground_process = foreground_process,
            workspace = workspace_name,
            domain = pane:get_domain_name(),
          }))
          forward_shortcut_to_pane(wezterm, window, pane, 'Ctrl+k', '\x0b', logger, 'command_panel', workspace_name, trace_id)
          return
        end

        logger.warn('command_panel', 'shortcut requires tmux in current pane', merge_fields(trace_id, {
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
        local trace_id = logger.trace_id('clipboard')
        paste_clipboard_or_image_path(wezterm, window, pane, constants, logger, trace_id, host)
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
