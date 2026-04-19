local M = {}

function M.merge_fields(trace_id, fields)
  local merged = {}

  for key, value in pairs(fields or {}) do
    merged[key] = value
  end
  if trace_id and trace_id ~= '' then
    merged.trace_id = trace_id
  end

  return merged
end

function M.json_escape(value)
  local text = tostring(value or '')
  text = text:gsub('\\', '\\\\')
  text = text:gsub('"', '\\"')
  text = text:gsub('\n', '\\n')
  text = text:gsub('\r', '\\r')
  text = text:gsub('\t', '\\t')
  return '"' .. text .. '"'
end

function M.base64_encode(data)
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

function M.current_epoch_ms()
  return os.time() * 1000
end

function M.parse_non_negative_number(value)
  local numeric = tonumber(value)
  if not numeric or numeric < 0 then
    return nil
  end

  return numeric
end

function M.decode_helper_response_env(values)
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

return M
