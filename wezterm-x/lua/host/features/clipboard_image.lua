local function windows_path_to_generic_wsl_path(path)
  if not path or path == '' then
    return nil
  end

  local normalized = path:gsub('\\', '/')
  local drive, remainder = normalized:match '^([A-Za-z]):/?(.*)$'
  if not drive then
    return normalized
  end

  drive = drive:lower()
  if not remainder or remainder == '' then
    return '/mnt/' .. drive
  end

  return '/mnt/' .. drive .. '/' .. remainder
end

return function(runtime)
  return {
    category = 'clipboard',
    recover_reason_prefix = 'clipboard',
    read_state = function(trace_id)
      local integration = runtime:integration 'clipboard_image'
      local state_path = integration.state_path
      if not state_path or state_path == '' then
        return nil, 'state_path_unconfigured'
      end

      local ok, cached_state = pcall(runtime.helpers.load_optional_env_file, state_path)
      if not ok then
        runtime.logger.warn('clipboard', 'failed to parse clipboard image cache', runtime:merge_fields(trace_id, {
          error = cached_state,
          state_path = state_path,
        }))
        return nil, 'cache_parse_failed'
      end

      if not cached_state or not cached_state.kind or cached_state.kind == '' then
        return nil, 'cache_missing'
      end

      cached_state.__state_path = state_path
      return cached_state, nil
    end,
    state_is_fresh = function(cached_state)
      local integration = runtime:integration 'clipboard_image'
      local heartbeat_timeout = tonumber(integration.heartbeat_timeout_seconds or 3) or 3
      local heartbeat_at_ms = tonumber(cached_state.heartbeat_at_ms or '') or 0

      if heartbeat_at_ms <= 0 then
        return false, 'missing_heartbeat'
      end

      if runtime:current_epoch_ms() - heartbeat_at_ms > heartbeat_timeout * 1000 then
        return false, 'stale_heartbeat'
      end

      return true, nil
    end,
    windows_path_to_wsl_path = windows_path_to_generic_wsl_path,
  }
end
