local M = {}
M.__index = M
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.'
local codec = dofile(join_path(runtime_dir, 'lua', 'host', 'runtime_codec.lua'))
local helper = dofile(join_path(runtime_dir, 'lua', 'host', 'runtime_helper.lua'))

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
  return helper.helper_integration(self.constants)
end

function M:helper_runtime_dir()
  local integration = self:helper_integration()
  return integration.runtime_dir or rawget(_G, 'WEZTERM_RUNTIME_DIR') or (self.wezterm.config_dir .. '\\.wezterm-x')
end

function M:merge_fields(trace_id, fields)
  return codec.merge_fields(trace_id, fields)
end

function M:json_escape(value)
  return codec.json_escape(value)
end

function M:current_epoch_ms()
  return codec.current_epoch_ms()
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

    self.logger.warn(category, 'failed to show wezterm toast notification', codec.merge_fields(trace_id, {
        error = err,
        title = title,
        message = message,
      }))
      return
    end
  end

  self.logger.warn(category, 'wezterm toast notification unavailable', codec.merge_fields(trace_id, {
    title = title,
    message = message,
  }))
end

function M:helper_command()
  return helper.build_helper_command(self)
end

function M:helper_state_snapshot()
  return helper.helper_state_snapshot(self)
end

function M:helper_state_preflight()
  return helper.helper_state_preflight(self, codec.parse_non_negative_number)
end

function M:helper_request_command(payload_json)
  return helper.helper_request_command(self, codec.base64_encode, payload_json)
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
  self.logger.info(category, 'sending request via windows runtime helper ipc', codec.merge_fields(trace_id, {
    request_domain = request_domain,
    request_action = request_action,
    phase = phase or 'direct',
    timeout_ms = tostring(request_timeout_ms or 0),
  }))

  local ok, success, stdout, stderr = pcall(self.wezterm.run_child_process, request_command)
  local elapsed_ms = math.max(self:current_epoch_ms() - started_at, 0)
  if not ok then
    self.logger.warn(category, 'windows runtime helper ipc request raised an error', codec.merge_fields(trace_id, {
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
    self.logger.warn(category, 'windows runtime helper ipc request failed', codec.merge_fields(trace_id, {
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
      self.logger.warn(category, 'failed to parse windows runtime helper ipc response', codec.merge_fields(trace_id, {
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

    response = codec.decode_helper_response_env(parsed_response)
  end

  self.logger.info(category, 'windows runtime helper ipc request completed', codec.merge_fields(trace_id, {
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
    '"trace_id":', codec.json_escape(request_trace_id), ',',
    '"message_type":"request",',
    '"domain":', codec.json_escape(request_domain), ',',
    '"action":', codec.json_escape(request_action), ',',
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
    self.logger.info('host_helper', 'windows runtime helper state is stale before request; ensuring synchronously', codec.merge_fields(trace_id, {
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
