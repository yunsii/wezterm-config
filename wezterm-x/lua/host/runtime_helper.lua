local M = {}

function M.diagnostics_capture_enabled(constants, category)
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

function M.wsl_distro_from_domain(domain_name)
  if not domain_name then
    return nil
  end

  return domain_name:match '^WSL:(.+)$'
end

function M.helper_integration(constants)
  return constants.integrations and constants.integrations.vscode or {}
end

function M.build_helper_command(runtime)
  if not runtime:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = runtime:helper_integration()
  local runtime_dir = runtime:helper_runtime_dir()
  local helper_script = integration.helper_script or 'scripts\\ensure-windows-runtime-helper.ps1'
  local diagnostics = runtime.constants.diagnostics and runtime.constants.diagnostics.wezterm or {}
  local helper_log_file = integration.helper_log_file or diagnostics.file or ''
  local clipboard = runtime:integration 'clipboard_image'
  local helper_category_enabled = M.diagnostics_capture_enabled(runtime.constants, 'host_helper')
    or M.diagnostics_capture_enabled(runtime.constants, 'alt_o')
    or M.diagnostics_capture_enabled(runtime.constants, 'chrome')
    or M.diagnostics_capture_enabled(runtime.constants, 'clipboard')

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
    M.wsl_distro_from_domain(runtime.constants.default_domain) or '',
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

function M.helper_state_snapshot(runtime)
  if not runtime:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = runtime:helper_integration()
  local state_path = integration.helper_state_path
  if not state_path or state_path == '' then
    return nil, 'state_path_unconfigured'
  end

  local state = runtime.helpers.load_optional_env_file(state_path)
  if not state then
    return nil, 'state_unavailable'
  end

  return state, nil
end

function M.helper_state_preflight(runtime, parse_non_negative_number)
  if not runtime:supports_windows_helper() then
    return false, 'unsupported_runtime', {}
  end

  local integration = runtime:helper_integration()
  local expected_runtime_dir = runtime:helper_runtime_dir()
  local timeout_ms = (integration.helper_heartbeat_timeout_seconds or 5) * 1000
  local state, state_reason = M.helper_state_snapshot(runtime)
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

  local heartbeat_age_ms = math.max(runtime:current_epoch_ms() - heartbeat_at_ms, 0)
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

function M.helper_request_command(runtime, base64_encode, payload_json)
  if not runtime:supports_windows_helper() then
    return nil, 'unsupported_runtime'
  end

  local integration = runtime:helper_integration()
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

return M
