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

local function parse_non_negative_number(value)
  local numeric = tonumber(value)
  if not numeric or numeric < 0 then
    return nil
  end

  return numeric
end

local function decode_helper_response_env(values)
  if not values then
    return nil
  end

  local response = {
    version = tonumber(values.version) or values.version,
    message_type = values.message_type,
    trace_id = values.trace_id,
    domain = values.domain,
    action = values.action,
    ok = values.ok == '1',
    status = values.status,
    decision_path = values.decision_path,
    result_type = values.result_type,
    helperctl_elapsed_ms = values.helperctl_elapsed_ms,
  }

  local result = {}
  for key, value in pairs(values) do
    local result_key = key:match '^result_(.+)$'
    if result_key then
      result[result_key] = value
    end
  end
  if next(result) ~= nil then
    response.result = result
  end

  if values.error_code or values.error_message then
    response.error = {
      code = values.error_code,
      message = values.error_message,
    }
  end

  return response
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

function M:helper_runtime_dir()
  local integration = self:helper_integration()
  return integration.runtime_dir or rawget(_G, 'WEZTERM_RUNTIME_DIR') or (self.wezterm.config_dir .. '\\.wezterm-x')
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
  local runtime_dir = self:helper_runtime_dir()
  local helper_script = integration.helper_script or 'scripts\\ensure-windows-runtime-helper.ps1'
  local diagnostics = self.constants.diagnostics and self.constants.diagnostics.wezterm or {}
  local helper_log_file = integration.helper_log_file or diagnostics.file or ''
  local clipboard = self:integration 'clipboard_image'
  local helper_category_enabled = diagnostics_capture_enabled(self.constants, 'host_helper')
    or diagnostics_capture_enabled(self.constants, 'alt_o')
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
    helper_log_file,
    '-DiagnosticsMaxBytes',
    tostring(diagnostics.max_bytes or 0),
    '-DiagnosticsMaxFiles',
    tostring(diagnostics.max_files or 0),
  }, nil
end

function M:helper_state_snapshot()
  if not self:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = self:helper_integration()
  local state_path = integration.helper_state_path
  if not state_path or state_path == '' then
    return nil, 'state_path_unconfigured'
  end

  local state = self.helpers.load_optional_env_file(state_path)
  if not state then
    return nil, 'state_unavailable'
  end

  return state, nil
end

function M:helper_state_preflight()
  if not self:supports_windows_helper() then
    return false, 'unsupported_runtime', {}
  end

  local integration = self:helper_integration()
  local expected_runtime_dir = self:helper_runtime_dir()
  local timeout_ms = (integration.helper_heartbeat_timeout_seconds or 5) * 1000
  local state, state_reason = self:helper_state_snapshot()
  if not state then
    return false, state_reason, {
      expected_runtime_dir = expected_runtime_dir,
      timeout_ms = tostring(timeout_ms),
    }
  end

  if state.ready ~= '1' then
    return false, 'state_not_ready', {
      expected_runtime_dir = expected_runtime_dir,
      ready = state.ready,
      timeout_ms = tostring(timeout_ms),
    }
  end

  if expected_runtime_dir ~= '' and state.runtime_dir ~= expected_runtime_dir then
    return false, 'runtime_dir_mismatch', {
      expected_runtime_dir = expected_runtime_dir,
      state_runtime_dir = state.runtime_dir,
      timeout_ms = tostring(timeout_ms),
    }
  end

  local heartbeat_at_ms = parse_non_negative_number(state.heartbeat_at_ms)
  if not heartbeat_at_ms then
    return false, 'heartbeat_missing', {
      expected_runtime_dir = expected_runtime_dir,
      heartbeat_at_ms = state.heartbeat_at_ms,
      timeout_ms = tostring(timeout_ms),
    }
  end

  local heartbeat_age_ms = math.max(self:current_epoch_ms() - heartbeat_at_ms, 0)
  if heartbeat_age_ms > timeout_ms then
    return false, 'heartbeat_stale', {
      expected_runtime_dir = expected_runtime_dir,
      heartbeat_at_ms = tostring(heartbeat_at_ms),
      heartbeat_age_ms = tostring(heartbeat_age_ms),
      timeout_ms = tostring(timeout_ms),
    }
  end

  return true, nil, {
    expected_runtime_dir = expected_runtime_dir,
    state_runtime_dir = state.runtime_dir,
    heartbeat_at_ms = tostring(heartbeat_at_ms),
    heartbeat_age_ms = tostring(heartbeat_age_ms),
    timeout_ms = tostring(timeout_ms),
  }
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

  self.logger.info('host_helper', 'ensuring windows runtime helper is running', {
    reason = reason,
  })

  local ok, err = pcall(self.wezterm.background_child_process, command)
  if not ok then
    self.logger.error('host_helper', 'failed to start windows runtime helper', {
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

  self.logger.info('host_helper', 'ensuring windows runtime helper synchronously', {
    reason = reason,
  })

  local ok, success, stdout, stderr = pcall(self.wezterm.run_child_process, command)
  if not ok then
    self.logger.error('host_helper', 'synchronous windows runtime helper launch raised an error', {
      error = success,
      reason = reason,
    })
    return false, 'spawn_error'
  end

  if not success then
    self.logger.warn('host_helper', 'synchronous windows runtime helper launch failed', {
      reason = reason,
      stdout = stdout,
      stderr = stderr,
    })
    return false, 'spawn_failed'
  end

  return true, nil
end

function M:write_request(trace_id, category, request_domain, request_action, payload_body_factory)
  local response, reason = self:write_request_with_response(trace_id, category, request_domain, request_action, payload_body_factory)
  if not response then
    return false, reason
  end

  if response.ok ~= true then
    return false, (response.error and response.error.code) or response.status or 'request_failed'
  end

  return true, nil
end

function M:invoke_helper_request(trace_id, category, request_domain, request_action, request_timeout_ms, request_command, phase)
  local started_at = self:current_epoch_ms()
  self.logger.info(category, 'sending request via windows runtime helper ipc', merge_fields(trace_id, {
    request_domain = request_domain,
    request_action = request_action,
    phase = phase or 'direct',
    timeout_ms = tostring(request_timeout_ms or 0),
  }))

  local ok, success, stdout, stderr = pcall(self.wezterm.run_child_process, request_command)
  local elapsed_ms = math.max(self:current_epoch_ms() - started_at, 0)
  if not ok then
    self.logger.warn(category, 'windows runtime helper ipc request raised an error', merge_fields(trace_id, {
      error = success,
      request_domain = request_domain,
      request_action = request_action,
      phase = phase or 'direct',
      elapsed_ms = tostring(elapsed_ms),
      timeout_ms = tostring(request_timeout_ms or 0),
    }))
    return nil, 'request_spawn_error'
  end

  if not success then
    self.logger.warn(category, 'windows runtime helper ipc request failed', merge_fields(trace_id, {
      stdout = stdout,
      stderr = stderr,
      request_domain = request_domain,
      request_action = request_action,
      phase = phase or 'direct',
      elapsed_ms = tostring(elapsed_ms),
      timeout_ms = tostring(request_timeout_ms or 0),
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
        request_domain = request_domain,
        request_action = request_action,
        phase = phase or 'direct',
        elapsed_ms = tostring(elapsed_ms),
        timeout_ms = tostring(request_timeout_ms or 0),
      }))
      return nil, 'response_parse_failed'
    end

    response = decode_helper_response_env(parsed_response)
  end

  self.logger.info(category, 'windows runtime helper ipc request completed', merge_fields(trace_id, {
    status = response and response.status or nil,
    decision_path = response and response.decision_path or nil,
    request_domain = request_domain,
    request_action = request_action,
    result_type = response and response.result_type or nil,
    phase = phase or 'direct',
    elapsed_ms = tostring(elapsed_ms),
    helperctl_elapsed_ms = response and response.helperctl_elapsed_ms or nil,
    timeout_ms = tostring(request_timeout_ms or 0),
  }))

  return response or { ok = true }, nil
end

function M:write_request_with_response(trace_id, category, request_domain, request_action, payload_body_factory)
  local request_trace_id = trace_id or tostring(os.time())
  local payload_body = payload_body_factory(request_trace_id)
  local request_body = table.concat {
    '{',
    '"version":2,',
    '"trace_id":', json_escape(request_trace_id), ',',
    '"message_type":"request",',
    '"domain":', json_escape(request_domain), ',',
    '"action":', json_escape(request_action), ',',
    '"payload":', payload_body,
    '}',
  }
  local request_command, request_command_reason = self:helper_request_command(request_body)
  if not request_command then
    return false, request_command_reason
  end
  local helper_integration = self:helper_integration()
  local request_timeout_ms = helper_integration.helper_request_timeout_ms or 5000
  local state_is_fresh, state_reason, state_fields = self:helper_state_preflight()
  local request_phase = 'direct'

  if not state_is_fresh then
    self.logger.info('host_helper', 'windows runtime helper state is stale before request; ensuring synchronously', merge_fields(trace_id, {
      request_domain = request_domain,
      request_action = request_action,
      preflight_reason = state_reason,
      phase = 'preflight',
      timeout_ms = tostring(request_timeout_ms),
      ready = state_fields.ready,
      heartbeat_at_ms = state_fields.heartbeat_at_ms,
      heartbeat_age_ms = state_fields.heartbeat_age_ms,
      expected_runtime_dir = state_fields.expected_runtime_dir,
      state_runtime_dir = state_fields.state_runtime_dir,
      helper_timeout_ms = state_fields.timeout_ms,
    }))

    local preflight_ensured, preflight_reason = self:ensure_helper_running_sync('preflight-' .. (state_reason or 'stale'))
    if not preflight_ensured then
      return nil, preflight_reason
    end

    request_phase = 'after_preflight_ensure'
  end

  local response, reason = self:invoke_helper_request(trace_id, category, request_domain, request_action, request_timeout_ms, request_command, request_phase)
  if response then
    return response, nil
  end

  local ensured, ensured_reason = self:ensure_helper_running_sync('request-' .. (reason or 'failed'))
  if not ensured then
    return nil, ensured_reason
  end

  return self:invoke_helper_request(trace_id, category, request_domain, request_action, request_timeout_ms, request_command, 'after_ensure')
end

return M
