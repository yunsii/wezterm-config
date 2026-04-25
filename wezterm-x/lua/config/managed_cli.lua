local M = {}

-- Longer suffixes must precede shorter ones so `FOO_COMMAND_LIGHT` matches
-- `COMMAND_LIGHT` instead of being mis-parsed as profile name `FOO_COMMAND`
-- with suffix `LIGHT`. Lua patterns have no alternation, so match each.
local PROFILE_FIELD_SUFFIXES = { 'COMMAND_LIGHT', 'COMMAND_DARK', 'PROMPT_FLAG', 'COMMAND' }

local function match_profile_key(key)
  for _, suffix in ipairs(PROFILE_FIELD_SUFFIXES) do
    local raw_name = key:match('^WT_PROVIDER_AGENT_PROFILE_([A-Z0-9_]+)_' .. suffix .. '$')
    if raw_name then
      return raw_name, suffix
    end
  end
  return nil, nil
end

function M.normalize_agent_profile_name(name)
  if not name or name == '' then
    return nil
  end

  local normalized = name:lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if normalized == '' then
    return nil
  end

  return normalized
end

function M.parse_command_spec(spec)
  if not spec or spec == '' then
    return nil
  end

  local parts = {}
  local current = {}
  local quote = nil
  local escape = false

  local function push_current()
    if #current == 0 then
      return
    end
    parts[#parts + 1] = table.concat(current)
    current = {}
  end

  for i = 1, #spec do
    local char = spec:sub(i, i)
    if escape then
      current[#current + 1] = char
      escape = false
    elseif char == '\\' and quote ~= "'" then
      escape = true
    elseif quote then
      if char == quote then
        quote = nil
      else
        current[#current + 1] = char
      end
    elseif char == '"' or char == "'" then
      quote = char
    elseif char:match('%s') then
      push_current()
    else
      current[#current + 1] = char
    end
  end

  if escape then
    current[#current + 1] = '\\'
  end

  push_current()

  if #parts == 0 then
    return nil
  end

  return parts
end

function M.parse_managed_cli_env(env)
  local parsed = {
    active_profile = nil,
    profiles = {},
  }

  if not env then
    return parsed
  end

  parsed.active_profile = M.normalize_agent_profile_name(env.WT_PROVIDER_AGENT_PROFILE)

  for key, value in pairs(env) do
    local raw_name, field = match_profile_key(key)
    if raw_name and field then
      local profile_name = M.normalize_agent_profile_name(raw_name)
      if profile_name then
        local profile = parsed.profiles[profile_name] or {
          command = nil,
          variants = {},
          prompt_flag = nil,
        }
        parsed.profiles[profile_name] = profile

        if field == 'COMMAND' then
          profile.command = M.parse_command_spec(value)
        elseif field == 'COMMAND_LIGHT' then
          profile.variants.light = M.parse_command_spec(value)
        elseif field == 'COMMAND_DARK' then
          profile.variants.dark = M.parse_command_spec(value)
        elseif field == 'PROMPT_FLAG' then
          profile.prompt_flag = value ~= '' and value or nil
        end
      end
    end
  end

  for _, profile in pairs(parsed.profiles) do
    if not next(profile.variants) then
      profile.variants = {}
    end
  end

  return parsed
end

return M
