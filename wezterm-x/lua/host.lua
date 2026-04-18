local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local source = debug.getinfo(1, 'S').source:match '^@(.+)$'
local module_dir = source and source:match('^(.*)[/\\][^/\\]+$') or '.'

local function load_module(name)
  return dofile(join_path(module_dir, 'host', name .. '.lua'))
end

local Runtime = load_module 'runtime'
local feature_registry = load_module 'feature_registry'

function M.new(opts)
  local runtime = Runtime.new(opts)
  return setmetatable({
    runtime = runtime,
    features = feature_registry.build(runtime),
  }, { __index = M })
end

function M:feature(name)
  return self.features[name]
end

function M:ensure_running(reason, sync)
  if sync then
    return self.runtime:ensure_helper_running_sync(reason)
  end

  return self.runtime:ensure_helper_running(reason)
end

function M:recover(feature_name, reason, sync)
  local feature = self:feature(feature_name)
  if not feature then
    return false, 'unknown_feature'
  end

  local prefix = feature.recover_reason_prefix or feature_name
  local full_reason = prefix
  if reason and reason ~= '' then
    full_reason = prefix .. '-' .. reason
  end

  return self:ensure_running(full_reason, sync)
end

function M:request(feature_name, trace_id, payload)
  local feature = self:feature(feature_name)
  if not feature or not feature.request then
    return false, 'unknown_feature'
  end

  local ok, reason = feature.request(trace_id, payload or {})
  if ok then
    return true, nil
  end

  if feature.failure_notification then
    self.runtime:show_windows_notification(
      feature.category or feature_name,
      trace_id,
      feature.failure_notification.title,
      feature.failure_notification.message
    )
  end

  return false, reason
end

function M:file_exists(path)
  return self.runtime.helpers.file_exists(path)
end

function M:read_state(feature_name, trace_id)
  local feature = self:feature(feature_name)
  if not feature or not feature.read_state then
    return nil, 'unsupported_feature'
  end

  return feature.read_state(trace_id)
end

function M:state_is_fresh(feature_name, state)
  local feature = self:feature(feature_name)
  if not feature or not feature.state_is_fresh then
    return false, 'unsupported_feature'
  end

  return feature.state_is_fresh(state)
end

return M
