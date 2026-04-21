return function(runtime)
  return {
    category = 'ime',
    recover_reason_prefix = 'ime',
    query = function(trace_id)
      if not runtime:supports_windows_helper() then
        return nil, 'unsupported_runtime'
      end

      local state_is_fresh, state_reason = runtime:helper_state_preflight()
      if not state_is_fresh then
        return nil, state_reason or 'helper_stale'
      end

      local state, snapshot_reason = runtime:helper_state_snapshot()
      if not state then
        return nil, snapshot_reason or 'state_unavailable'
      end

      local mode = state.ime_mode
      if not mode or mode == '' then
        return { mode = 'unknown', lang = nil, reason = 'state_missing_ime' }
      end

      local lang = state.ime_lang
      if lang == '' then lang = nil end
      local reason = state.ime_reason
      if reason == '' then reason = nil end

      return { mode = mode, lang = lang, reason = reason }
    end,
  }
end
