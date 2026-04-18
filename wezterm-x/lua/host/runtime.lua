local M = {}
M.__index = M

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

local function json_escape(value)
  local text = tostring(value or '')
  text = text:gsub('\\', '\\\\')
  text = text:gsub('"', '\\"')
  text = text:gsub('\n', '\\n')
  text = text:gsub('\r', '\\r')
  text = text:gsub('\t', '\\t')
  return '"' .. text .. '"'
end

local function write_text_file_atomic(path, content)
  local temp_path = path .. '.tmp'
  local file, err = io.open(temp_path, 'w')
  if not file then
    return false, err
  end

  file:write(content)
  file:close()

  os.remove(path)
  local renamed, rename_err = os.rename(temp_path, path)
  if not renamed then
    os.remove(temp_path)
    return false, rename_err
  end

  return true, nil
end

local function current_epoch_ms()
  return os.time() * 1000
end

local function diagnostics_capture_enabled(constants, category)
  local diagnostics = constants and constants.diagnostics or {}
  local wezterm_diagnostics = diagnostics.wezterm or {}
  local categories = wezterm_diagnostics.categories or {}

  if wezterm_diagnostics.enabled ~= true then
    return false
  end

  if next(categories) == nil then
    return true
  end

  return categories[category] == true
end

local function wsl_distro_from_domain(domain_name)
  if not domain_name then
    return nil
  end

  return domain_name:match '^WSL:(.+)$'
end

local function helper_integration(constants)
  return constants.integrations and constants.integrations.vscode or {}
end

function M.new(opts)
  return setmetatable({
    wezterm = opts.wezterm,
    constants = opts.constants,
    helpers = opts.helpers,
    logger = opts.logger,
  }, M)
end

function M:integration(name)
  return self.constants.integrations and self.constants.integrations[name] or {}
end

function M:helper_integration()
  return helper_integration(self.constants)
end

function M:merge_fields(trace_id, fields)
  return merge_fields(trace_id, fields)
end

function M:json_escape(value)
  return json_escape(value)
end

function M:current_epoch_ms()
  return current_epoch_ms()
end

function M:supports_windows_helper()
  local runtime_mode = self.constants.runtime_mode or 'hybrid-wsl'
  return runtime_mode == 'hybrid-wsl' and self.constants.host_os == 'windows'
end

function M:windows_notification_command(title, message)
  if not self:supports_windows_helper() then
    return nil
  end

  local integration = self:helper_integration()
  local runtime_dir = integration.runtime_dir or (self.wezterm.config_dir .. '\\.wezterm-x')
  return {
    integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    runtime_dir .. '\\scripts\\show-windows-notification.ps1',
    '-Title',
    title,
    '-Message',
    message,
  }
end

function M:show_windows_notification(category, trace_id, title, message)
  local command = self:windows_notification_command(title, message)
  if not command then
    return
  end

  local ok, err = pcall(self.wezterm.background_child_process, command)
  if not ok then
    self.logger.warn(category, 'failed to show windows notification', merge_fields(trace_id, {
      error = err,
      title = title,
      message = message,
    }))
  end
end

function M:helper_command()
  if not self:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = self:helper_integration()
  local runtime_dir = integration.runtime_dir or (self.wezterm.config_dir .. '\\.wezterm-x')
  local helper_script = integration.helper_script or 'scripts\\ensure-windows-runtime-helper.ps1'
  local helper_worker_script = integration.helper_worker_script or 'scripts\\windows-runtime-helper.ps1'
  local diagnostics = self.constants.diagnostics and self.constants.diagnostics.wezterm or {}
  local clipboard = self:integration 'clipboard_image'
  local helper_category_enabled = diagnostics_capture_enabled(self.constants, 'alt_o')
    or diagnostics_capture_enabled(self.constants, 'chrome')
    or diagnostics_capture_enabled(self.constants, 'clipboard')

  return {
    integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    runtime_dir .. '\\' .. helper_script,
    '-WorkerScriptPath',
    runtime_dir .. '\\' .. helper_worker_script,
    '-Port',
    tostring(integration.helper_port or 45921),
    '-StatePath',
    integration.helper_state_path or '',
    '-RequestDir',
    integration.helper_request_dir or integration.helper_request_path or '',
    '-ClipboardListenerScriptPath',
    runtime_dir .. '\\' .. (clipboard.listener_script or 'scripts\\clipboard-image-listener.ps1'),
    '-ClipboardStatePath',
    clipboard.state_path or '',
    '-ClipboardLogPath',
    clipboard.log_path or '',
    '-ClipboardOutputDir',
    clipboard.output_dir or '',
    '-ClipboardWslDistro',
    wsl_distro_from_domain(self.constants.default_domain) or '',
    '-ClipboardHeartbeatIntervalSeconds',
    tostring(clipboard.heartbeat_interval_seconds or 1),
    '-ClipboardImageReadRetryCount',
    tostring(clipboard.image_read_retry_count or 12),
    '-ClipboardImageReadRetryDelayMs',
    tostring(clipboard.image_read_retry_delay_ms or 100),
    '-ClipboardCleanupMaxAgeHours',
    tostring(clipboard.cleanup_max_age_hours or 48),
    '-ClipboardCleanupMaxFiles',
    tostring(clipboard.cleanup_max_files or 32),
    '-HeartbeatTimeoutSeconds',
    tostring(integration.helper_heartbeat_timeout_seconds or 5),
    '-HeartbeatIntervalMs',
    tostring(integration.helper_heartbeat_interval_ms or 1000),
    '-PollIntervalMs',
    tostring(integration.helper_poll_interval_ms or 25),
    '-DiagnosticsEnabled',
    diagnostics.enabled == true and '1' or '0',
    '-DiagnosticsCategoryEnabled',
    helper_category_enabled and '1' or '0',
    '-DiagnosticsLevel',
    diagnostics.level or 'info',
    '-DiagnosticsFile',
    diagnostics.file or '',
    '-DiagnosticsMaxBytes',
    tostring(diagnostics.max_bytes or 0),
    '-DiagnosticsMaxFiles',
    tostring(diagnostics.max_files or 0),
  }, nil
end

function M:ensure_helper_running(reason)
  local command, command_reason = self:helper_command()
  if not command then
    return false, command_reason
  end

  self.logger.info('alt_o', 'ensuring windows runtime helper is running', {
    reason = reason,
  })

  local ok, err = pcall(self.wezterm.background_child_process, command)
  if not ok then
    self.logger.error('alt_o', 'failed to start windows runtime helper', {
      error = err,
      reason = reason,
    })
    return false, 'spawn_failed'
  end

  return true, nil
end

function M:ensure_helper_running_sync(reason)
  local command, command_reason = self:helper_command()
  if not command then
    return false, command_reason
  end

  self.logger.info('alt_o', 'ensuring windows runtime helper synchronously', {
    reason = reason,
  })

  local ok, success, stdout, stderr = pcall(self.wezterm.run_child_process, command)
  if not ok then
    self.logger.error('alt_o', 'synchronous windows runtime helper launch raised an error', {
      error = success,
      reason = reason,
    })
    return false, 'spawn_error'
  end

  if not success then
    self.logger.warn('alt_o', 'synchronous windows runtime helper launch failed', {
      reason = reason,
      stdout = stdout,
      stderr = stderr,
    })
    return false, 'spawn_failed'
  end

  return true, nil
end

function M:read_helper_state(trace_id)
  local integration = self:helper_integration()
  local state_path = integration.helper_state_path
  if not state_path or state_path == '' then
    return nil, 'state_path_unconfigured'
  end

  local ok, helper_state = pcall(self.helpers.load_optional_env_file, state_path)
  if not ok then
    self.logger.warn('alt_o', 'failed to parse windows runtime helper state', merge_fields(trace_id, {
      error = helper_state,
      state_path = state_path,
    }))
    return nil, 'state_parse_failed'
  end

  if not helper_state or next(helper_state) == nil then
    return nil, 'state_missing'
  end

  helper_state.__state_path = state_path
  return helper_state, nil
end

function M:helper_state_is_fresh(helper_state)
  local integration = self:helper_integration()
  local heartbeat_timeout = tonumber(integration.helper_heartbeat_timeout_seconds or 5) or 5
  local heartbeat_at_ms = tonumber(helper_state.heartbeat_at_ms or '') or 0
  local pid = tonumber(helper_state.pid or '') or 0

  if helper_state.ready ~= '1' then
    return false, 'not_ready'
  end

  if pid <= 0 then
    return false, 'missing_pid'
  end

  if heartbeat_at_ms <= 0 then
    return false, 'missing_heartbeat'
  end

  if current_epoch_ms() - heartbeat_at_ms > heartbeat_timeout * 1000 then
    return false, 'stale_heartbeat'
  end

  return true, nil
end

function M:write_request(trace_id, category, request_body_factory)
  local integration = self:helper_integration()
  local helper_state, helper_state_reason = self:read_helper_state(trace_id)
  local helper_ready = false
  local helper_ready_reason = helper_state_reason
  local ensure_reason = nil

  if helper_state then
    helper_ready, helper_ready_reason = self:helper_state_is_fresh(helper_state)
  end

  if not helper_ready then
    local ensured, ensured_reason = self:ensure_helper_running_sync('state-' .. (helper_ready_reason or 'missing'))
    if not ensured then
      return false, ensured_reason
    end

    ensure_reason = 'state_' .. (helper_ready_reason or 'missing')
    helper_state, helper_state_reason = self:read_helper_state(trace_id)
    if not helper_state then
      return false, helper_state_reason or 'state_missing_after_ensure'
    end

    helper_ready, helper_ready_reason = self:helper_state_is_fresh(helper_state)
    if not helper_ready then
      return false, helper_ready_reason or 'state_not_fresh_after_ensure'
    end
  end

  local request_dir = helper_state.request_dir or helper_state.request_path or integration.helper_request_dir or integration.helper_request_path
  if not request_dir or request_dir == '' then
    return false, 'request_dir_unconfigured'
  end
  request_dir = request_dir:gsub('[\\/]+$', '')

  local request_trace_id = trace_id or tostring(os.time())
  local request_path = request_dir .. '\\' .. request_trace_id .. '.json'
  local request_body = request_body_factory(request_trace_id)

  self.logger.info(category, 'sending request via windows runtime helper', merge_fields(trace_id, {
    request_dir = request_dir,
    request_path = request_path,
    ensure_reason = ensure_reason or helper_ready_reason or 'ready',
  }))

  local ok, err = write_text_file_atomic(request_path, request_body)
  if not ok then
    self:ensure_helper_running_sync 'request-enqueue-retry'
    helper_state = self:read_helper_state(trace_id)
    if helper_state and helper_state.request_dir and helper_state.request_dir ~= '' then
      request_dir = helper_state.request_dir:gsub('[\\/]+$', '')
      request_path = request_dir .. '\\' .. request_trace_id .. '.json'
    end
    ok, err = write_text_file_atomic(request_path, request_body)
  end

  if not ok then
    self.logger.warn(category, 'failed to enqueue request for windows runtime helper', merge_fields(trace_id, {
      error = err,
      request_path = request_path,
    }))
    return false, 'request_enqueue_failed'
  end

  return true, nil
end

return M
