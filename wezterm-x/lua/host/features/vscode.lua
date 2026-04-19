local function encode_string_array(runtime, values)
  local parts = {}

  for index, value in ipairs(values or {}) do
    if index > 1 then
      parts[#parts + 1] = ','
    end
    parts[#parts + 1] = runtime:json_escape(value)
  end

  return table.concat(parts)
end

return function(runtime)
  return {
    category = 'alt_o',
    recover_reason_prefix = 'alt_o',
    failure_notification = {
      title = 'WezTerm Alt+v',
      message = 'Windows helper failed to focus VS Code. Check wezterm diagnostics.',
    },
    request = function(trace_id, payload)
      return runtime:write_request(trace_id, 'alt_o', 'vscode_focus_or_open', function(_)
        return table.concat {
          '{',
          '"requested_dir":', runtime:json_escape(payload.cwd), ',',
          '"distro":', runtime:json_escape(payload.distro), ',',
          '"code_command":[', encode_string_array(runtime, payload.code_command), ']',
          '}',
        }
      end)
    end,
  }
end
