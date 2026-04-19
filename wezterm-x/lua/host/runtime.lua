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

local function base64_encode(data)
  local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local result = {}
  local bytes = { data:byte(1, #data) }
  local padding = (3 - (#bytes % 3)) % 3

  for _ = 1, padding do
    bytes[#bytes + 1] = 0
  end

  for index = 1, #bytes, 3 do
    local chunk = bytes[index] * 65536 + bytes[index + 1] * 256 + bytes[index + 2]
    local a = math.floor(chunk / 262144) % 64 + 1
    local b = math.floor(chunk / 4096) % 64 + 1
    local c = math.floor(chunk / 64) % 64 + 1
    local d = chunk % 64 + 1
    result[#result + 1] = alphabet:sub(a, a)
    result[#result + 1] = alphabet:sub(b, b)
    result[#result + 1] = alphabet:sub(c, c)
    result[#result + 1] = alphabet:sub(d, d)
  end

  for index = 1, padding do
    result[#result - index + 1] = '='
  end

  return table.concat(result)
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

function M:show_windows_notification(category, trace_id, title, message)
  if self.wezterm.gui and self.wezterm.gui.gui_windows then
    local ok, windows = pcall(self.wezterm.gui.gui_windows)
    if ok and windows and windows[1] and windows[1].toast_notification then
      local shown, err = pcall(windows[1].toast_notification, windows[1], title or 'WezTerm', message or '', nil, 4000)
      if shown then
        return
      end

      self.logger.warn(category, 'failed to show wezterm toast notification', merge_fields(trace_id, {
        error = err,
        title = title,
        message = message,
      }))
      return
    end
  end

  self.logger.warn(category, 'wezterm toast notification unavailable', merge_fields(trace_id, {
    title = title,
    message = message,
  }))
end

function M:helper_command()
  if not self:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = self:helper_integration()
  local runtime_dir = integration.runtime_dir or rawget(_G, 'WEZTERM_RUNTIME_DIR') or (self.wezterm.config_dir .. '\\.wezterm-x')
  local helper_script = integration.helper_script or 'scripts\\ensure-windows-runtime-helper.ps1'
  local diagnostics = self.constants.diagnostics and self.constants.diagnostics.wezterm or {}
  local clipboard = self:integration 'clipboard_image'
  local helper_category_enabled = diagnostics_capture_enabled(self.constants, 'alt_o')
    or diagnostics_capture_enabled(self.constants, 'chrome')
    or diagnostics_capture_enabled(self.constants, 'clipboard')

  return {
    integration.powershell or 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    runtime_dir .. '\\' .. helper_script,
    '-StatePath',
    integration.helper_state_path or '',
    '-ClipboardOutputDir',
    clipboard.output_dir or '',
    '-ClipboardWslDistro',
    wsl_distro_from_domain(self.constants.default_domain) or '',
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

function M:helper_request_command(payload_json)
  if not self:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = self:helper_integration()
  local helper_client_exe = integration.helper_client_exe
  local helper_ipc_endpoint = integration.helper_ipc_endpoint
  if not helper_client_exe or helper_client_exe == '' then
    return nil, 'client_exe_unconfigured'
  end
  if not helper_ipc_endpoint or helper_ipc_endpoint == '' then
    return nil, 'ipc_endpoint_unconfigured'
  end

  return {
    helper_client_exe,
    'request',
    '--pipe',
    helper_ipc_endpoint,
    '--payload-base64',
    base64_encode(payload_json),
    '--timeout-ms',
    tostring(integration.helper_request_timeout_ms or 5000),
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

function M:write_request(trace_id, category, request_kind, payload_body_factory)
  local response, reason = self:write_request_with_response(trace_id, category, request_kind, payload_body_factory)
  if not response then
    return false, reason
  end

  if response.ok ~= '1' then
    return false, response.error_code or response.status or 'request_failed'
  end

  return true, nil
end

function M:invoke_helper_request(trace_id, category, request_command, phase)
  self.logger.info(category, 'sending request via windows runtime helper ipc', merge_fields(trace_id, {
    phase = phase or 'direct',
  }))

  local ok, success, stdout, stderr = pcall(self.wezterm.run_child_process, request_command)
  if not ok then
    self.logger.warn(category, 'windows runtime helper ipc request raised an error', merge_fields(trace_id, {
      error = success,
      phase = phase or 'direct',
    }))
    return nil, 'request_spawn_error'
  end

  if not success then
    self.logger.warn(category, 'windows runtime helper ipc request failed', merge_fields(trace_id, {
      stdout = stdout,
      stderr = stderr,
      phase = phase or 'direct',
    }))
    return nil, 'request_failed'
  end

  local response = nil
  if stdout and stdout ~= '' then
    local parsed_ok, parsed_response = pcall(self.helpers.load_env_text, stdout, '<helper-response>')
    if not parsed_ok then
      self.logger.warn(category, 'failed to parse windows runtime helper ipc response', merge_fields(trace_id, {
        error = parsed_response,
        stdout = stdout,
        phase = phase or 'direct',
      }))
      return nil, 'response_parse_failed'
    end

    response = parsed_response
  end

  self.logger.info(category, 'windows runtime helper ipc request completed', merge_fields(trace_id, {
    status = response and response.status or nil,
    decision_path = response and response.decision_path or nil,
    phase = phase or 'direct',
  }))

  return response or { ok = '1' }, nil
end

function M:write_request_with_response(trace_id, category, request_kind, payload_body_factory)
  local request_trace_id = trace_id or tostring(os.time())
  local payload_body = payload_body_factory(request_trace_id)
  local request_body = table.concat {
    '{',
    '"version":1,',
    '"trace_id":', json_escape(request_trace_id), ',',
    '"kind":', json_escape(request_kind), ',',
    '"payload":', payload_body,
    '}',
  }
  local request_command, request_command_reason = self:helper_request_command(request_body)
  if not request_command then
    return false, request_command_reason
  end

  local response, reason = self:invoke_helper_request(trace_id, category, request_command, 'direct')
  if response then
    return response, nil
  end

  local ensured, ensured_reason = self:ensure_helper_running_sync('request-' .. (reason or 'failed'))
  if not ensured then
    return nil, ensured_reason
  end

  return self:invoke_helper_request(trace_id, category, request_command, 'after_ensure')
end

return M
