local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local module_dir = join_path(rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.', 'lua', 'ui')
local common = dofile(join_path(module_dir, 'common.lua'))

local M = {}

-- Build argv for spawning `scripts/runtime/attention-jump.sh` with the
-- given trailing arguments. Handles the hybrid-wsl case by wrapping the
-- call in `wsl.exe -d <distro> -- bash <script> ...`. `pane_ref` is only
-- used to resolve a WSL distro hint; when nil the builder falls back to
-- `constants.default_domain`. Returns nil (and logs a warn) when the
-- script path or WSL distro cannot be resolved.
function M.attention_jump_args(constants, pane_ref, trailing_args, logger, trace_id)
  local repo_root = constants and constants.repo_root
  if not repo_root or repo_root == '' then
    if logger then
      logger.warn('attention', 'no repo_root to resolve jump script', { trace = trace_id })
    end
    return nil
  end
  local script_path = repo_root .. '/scripts/runtime/attention-jump.sh'
  local runtime_mode = (constants and constants.runtime_mode) or 'hybrid-wsl'
  if runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    local distro = common.wsl_distro_from_domain(pane_ref and pane_ref:get_domain_name())
      or common.wsl_distro_from_domain(constants.default_domain)
    if not distro then
      if logger then
        logger.warn('attention', 'unable to resolve WSL distro for attention jump', { trace = trace_id })
      end
      return nil
    end
    local args = { 'wsl.exe', '-d', distro, '--', 'bash', script_path }
    for _, a in ipairs(trailing_args) do
      table.insert(args, a)
    end
    return args
  end
  local args = { 'bash', script_path }
  for _, a in ipairs(trailing_args) do
    table.insert(args, a)
  end
  return args
end

function M.workspace_keybinding(wezterm, workspace, key, name)
  return {
    key = key,
    mods = 'ALT',
    action = wezterm.action_callback(function(window, pane)
      workspace.open(window, pane, name)
    end),
  }
end

function M.is_tmux_backed_pane(constants, window, pane)
  local workspace_name = common.active_workspace_name(window)
  if workspace_name ~= nil and workspace_name ~= 'default' then
    return true, 'managed_workspace'
  end

  if constants.runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    local domain_name = pane and pane:get_domain_name() or nil
    if common.wsl_distro_from_domain(domain_name) then
      return true, 'hybrid_wsl_domain'
    end
  end

  local foreground_process = common.foreground_process_basename(pane)
  if foreground_process == 'tmux' then
    return true, 'foreground_tmux'
  end

  return false, 'not_tmux_backed'
end

function M.forward_shortcut_to_pane(wezterm, window, pane, shortcut, sequence, logger, category, workspace_name, trace_id)
  logger.info(category, 'forwarding shortcut to pane', common.merge_fields(trace_id, {
    shortcut = shortcut,
    sequence = sequence,
    workspace = workspace_name,
    domain = pane:get_domain_name(),
  }))
  window:perform_action(wezterm.action.SendString(sequence), pane)
end

function M.tmux_only_shortcut(window, logger, shortcut, trace_id)
  logger.warn('workspace', 'shortcut requires a tmux-backed pane', common.merge_fields(trace_id, {
    shortcut = shortcut,
    workspace = common.active_workspace_name(window),
  }))
  window:toast_notification('WezTerm', shortcut .. ' is only available when the current pane is running tmux', nil, 3000)
end

function M.paste_clipboard_or_image_path(wezterm, window, pane, constants, logger, trace_id, host)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  if runtime_mode ~= 'hybrid-wsl' or constants.host_os ~= 'windows' then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local domain_name = pane:get_domain_name()
  local distro = common.wsl_distro_from_domain(domain_name) or common.wsl_distro_from_domain(constants.default_domain)
  if not distro then
    logger.info('clipboard', 'falling back to plain clipboard paste outside WSL', common.merge_fields(trace_id, {
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
    logger.warn('clipboard', 'failed to resolve clipboard state via windows helper', common.merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      reason = resolve_reason,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  if resolved_state.result_type ~= 'clipboard_image' then
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  local result = resolved_state.result or {}
  local image_path = result.wsl_path
  if (not image_path or image_path == '') and result.windows_path and result.windows_path ~= '' then
    image_path = clipboard_feature.windows_path_to_wsl_path(result.windows_path)
  end

  if not image_path or image_path == '' then
    logger.warn('clipboard', 'resolved clipboard image is missing a WSL path', common.merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      windows_path = result.windows_path,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  if result.windows_path and result.windows_path ~= '' and not host:file_exists(result.windows_path) then
    logger.warn('clipboard', 'resolved clipboard image file is missing on disk', common.merge_fields(trace_id, {
      domain = domain_name,
      distro = distro,
      image_path = image_path,
      windows_path = result.windows_path,
    }))
    window:perform_action(wezterm.action.PasteFrom 'Clipboard', pane)
    return
  end

  pane:send_paste(image_path)
  logger.info('clipboard', 'pasted resolved clipboard image path', common.merge_fields(trace_id, {
    distro = distro,
    domain = domain_name,
    image_path = image_path,
    sequence = resolved_state.sequence,
  }))
end

function M.open_current_dir_in_vscode(wezterm, window, pane, constants, logger, trace_id, host)
  local raw_cwd = pane:get_current_working_dir()
  local cwd = common.file_path_from_cwd(raw_cwd)
  local domain_name = pane:get_domain_name()
  local workspace_name = common.active_workspace_name(window)
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'
  local integration = constants.integrations and constants.integrations.vscode or {}
  local command

  if not cwd or cwd == '/' then
    logger.warn('vscode', 'current pane working directory is unavailable', common.merge_fields(trace_id, {
      domain = domain_name,
      raw_cwd = tostring(raw_cwd),
      workspace = workspace_name,
    }))
    window:toast_notification('WezTerm', 'Alt+v failed: current pane working directory is unavailable', nil, 3000)
    return
  end

  if runtime_mode == 'hybrid-wsl' then
    local distro = common.wsl_distro_from_domain(domain_name) or common.wsl_distro_from_domain(constants.default_domain)
    if not distro then
      logger.warn('vscode', 'current pane is not backed by a WSL domain', common.merge_fields(trace_id, {
        cwd = cwd,
        domain = domain_name,
      }))
      window:toast_notification('WezTerm', 'Alt+v failed: current pane is not backed by a WSL domain', nil, 3000)
      return
    end

    local hybrid_command = common.copy_args(integration.hybrid_wsl_command)
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

    logger.error('vscode', 'windows helper Alt+v request failed', common.merge_fields(trace_id, {
      reason = helper_reason,
      cwd = cwd,
      distro = distro,
    }))
    window:toast_notification('WezTerm', 'Alt+v failed. Check WezTerm logs.', nil, 3000)
    return
  else
    local posix_command = common.copy_args(integration.posix_command)
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

  logger.info('vscode', 'opening current dir via WezTerm', common.merge_fields(trace_id, {
    command = table.concat(command, ' '),
    cwd = cwd,
    domain = domain_name,
    runtime_mode = runtime_mode,
  }))
  local ok, err = pcall(wezterm.background_child_process, command)
  if not ok then
    window:toast_notification('WezTerm', 'Alt+v failed. Check WezTerm logs.', nil, 3000)
    logger.error('vscode', 'background_child_process failed', common.merge_fields(trace_id, {
      error = err,
    }))
  end
end

function M.open_debug_chrome(wezterm, window, constants, logger, trace_id, host)
  local chrome = constants.chrome_debug_browser or {}
  local runtime_mode = constants.runtime_mode or 'hybrid-wsl'

  if not chrome.user_data_dir or chrome.user_data_dir == '' then
    logger.warn('chrome', 'missing chrome debug browser user_data_dir', common.merge_fields(trace_id, {
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

    logger.error('chrome', 'windows helper Alt+b request failed', common.merge_fields(trace_id, {
      reason = helper_reason,
      runtime_mode = runtime_mode,
      port = chrome.remote_debugging_port,
      user_data_dir = chrome.user_data_dir,
    }))
    window:toast_notification('WezTerm', 'Alt+b failed. Check WezTerm logs.', nil, 3000)
    return
  end

  logger.warn('chrome', 'Alt+b is unavailable without a native host helper', common.merge_fields(trace_id, {
    runtime_mode = runtime_mode,
    executable = chrome.executable,
    port = chrome.remote_debugging_port,
  }))
  window:toast_notification('WezTerm', 'Alt+b is only available when a native host helper is configured.', nil, 4000)
end

return M
