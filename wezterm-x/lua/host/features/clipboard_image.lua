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
    resolve_for_paste = function(trace_id)
      local response, reason = runtime:write_request_with_response(
        trace_id,
        'clipboard',
        'clipboard',
        'resolve_for_paste',
        function(_)
          return '{}'
        end
      )

      if not response then
        return nil, reason
      end

      if response.ok ~= true then
        return nil, (response.error and response.error.code) or response.status or 'request_failed'
      end

      if not response.result_type or response.result_type == '' then
        return nil, 'response_missing_result_type'
      end

      return response, nil
    end,
    windows_path_to_wsl_path = windows_path_to_generic_wsl_path,
  }
end
