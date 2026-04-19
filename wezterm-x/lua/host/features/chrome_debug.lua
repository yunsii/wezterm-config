return function(runtime)
  return {
    category = 'chrome',
    recover_reason_prefix = 'chrome',
    failure_notification = {
      title = 'WezTerm Alt+b',
      message = 'Windows helper failed to focus debug Chrome. Check wezterm diagnostics.',
    },
    request = function(trace_id, payload)
      return runtime:write_request(trace_id, 'chrome', 'chrome', 'focus_or_start', function(_)
        return table.concat {
          '{',
          '"chrome_path":', runtime:json_escape(payload.executable), ',',
          '"remote_debugging_port":', tostring(payload.remote_debugging_port), ',',
          '"user_data_dir":', runtime:json_escape(payload.user_data_dir),
          '}',
        }
      end)
    end,
  }
end
