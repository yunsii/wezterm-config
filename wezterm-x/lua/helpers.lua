local M = {}

local function trim(value)
  return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.file_exists(path)
  local file = io.open(path, 'r')
  if not file then
    return false
  end

  file:close()
  return true
end

function M.load_optional_table(path)
  if not M.file_exists(path) then
    return nil
  end

  local ok, value = pcall(dofile, path)
  if not ok then
    error('Failed to load ' .. path .. ': ' .. tostring(value))
  end

  return value
end

function M.load_optional_env_file(path)
  if not M.file_exists(path) then
    return nil
  end

  local file = io.open(path, 'r')
  if not file then
    return nil
  end

  local content = file:read '*a'
  file:close()

  return M.load_env_text(content, path)
end

function M.load_env_text(content, source)
  if not content or content == '' then
    return nil
  end

  local values = {}

  for line in tostring(content):gmatch '[^\r\n]+' do
    local raw = trim(line)
    if raw ~= '' and raw:sub(1, 1) ~= '#' then
      raw = raw:gsub('^export%s+', '', 1)
      local key, value = raw:match('^([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$')
      if not key then
        error('Failed to parse env line in ' .. (source or '<memory>') .. ': ' .. line)
      end

      local quote = value:sub(1, 1)
      if (#value >= 2) and (quote == "'" or quote == '"') and value:sub(-1) == quote then
        value = value:sub(2, -2)
      end

      values[key] = value
    end
  end

  return values
end

function M.deep_copy(value)
  if type(value) ~= 'table' then
    return value
  end

  local copy = {}
  for key, nested in pairs(value) do
    copy[key] = M.deep_copy(nested)
  end

  return copy
end

function M.deep_merge(base, override)
  if type(base) ~= 'table' then
    return M.deep_copy(override)
  end

  if type(override) ~= 'table' then
    return M.deep_copy(base)
  end

  local merged = M.deep_copy(base)

  for key, value in pairs(override) do
    if type(merged[key]) == 'table' and type(value) == 'table' then
      merged[key] = M.deep_merge(merged[key], value)
    else
      merged[key] = M.deep_copy(value)
    end
  end

  return merged
end

function M.cwd_to_path(cwd)
  if not cwd then
    return nil
  end

  if type(cwd) == 'userdata' or type(cwd) == 'table' then
    return cwd.file_path
  end

  if type(cwd) == 'string' then
    return cwd:gsub('^file://[^/]*', '')
  end

  return nil
end

function M.basename(path)
  if not path or path == '' then
    return ''
  end

  return path:match('([^/\\]+)[/\\]?$') or path
end

function M.copy_array(values)
  if not values then
    return nil
  end

  local result = {}
  for i, value in ipairs(values) do
    result[i] = value
  end
  return result
end

function M.unique_dirs_from_panes(panes)
  local dirs = {}
  local seen = {}

  for _, pane_like in ipairs(panes or {}) do
    local source = pane_like
    if type(pane_like) == 'table' and pane_like.pane then
      source = pane_like.pane
    end

    local cwd = nil
    if type(source) == 'table' then
      cwd = source.current_working_dir
    else
      local ok, value = pcall(function()
        return source.current_working_dir
      end)
      if ok then
        cwd = value
      end
    end

    if not cwd then
      local ok, getter = pcall(function()
        return source.get_current_working_dir
      end)
      if ok and getter then
        cwd = source:get_current_working_dir()
      end
    end

    local path = M.cwd_to_path(cwd)
    if path then
      local folder = M.basename(path)
      if folder ~= '' and not seen[folder] then
        dirs[#dirs + 1] = folder
        seen[folder] = true
      end
    end
  end

  return dirs
end

function M.summarize_dirs(dirs, max_width)
  if #dirs == 0 then
    return ''
  end

  if #dirs == 1 then
    return dirs[1]
  end

  local compact = dirs[1] .. ' +' .. (#dirs - 1)
  local expanded = dirs[1] .. ' | ' .. dirs[2]

  if #dirs == 2 and #expanded <= max_width then
    return expanded
  end

  if #dirs > 2 then
    local expanded_with_more = expanded .. ' | +' .. (#dirs - 2)
    if #expanded_with_more <= max_width then
      return expanded_with_more
    end
  end

  return compact
end

return M
