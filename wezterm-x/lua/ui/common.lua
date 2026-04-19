local M = {}
local path_sep = package.config:sub(1, 1)

function M.join_path(...)
  return table.concat({ ... }, path_sep)
end

function M.windows_path_to_wsl_path(path)
  if not path or path == '' then
    return nil
  end

  local normalized = tostring(path):gsub('\\', '/')
  local drive, remainder = normalized:match '^([A-Za-z]):/?(.*)$'
  if not drive then
    return normalized
  end

  drive = drive:lower()
  if remainder == '' then
    return '/mnt/' .. drive
  end

  return '/mnt/' .. drive .. '/' .. remainder
end

function M.read_runtime_metadata_file(filename)
  local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
  if not runtime_dir or runtime_dir == '' then
    return nil
  end

  local file = io.open(M.join_path(runtime_dir, filename), 'r')
  if not file then
    return nil
  end

  local value = file:read '*l'
  file:close()
  if not value then
    return nil
  end

  value = tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
  if value == '' then
    return nil
  end

  return value
end

function M.runtime_script_roots(constants)
  local roots = {}
  local seen = {}

  for _, root in ipairs {
    constants.repo_root,
    constants.main_repo_root,
    M.read_runtime_metadata_file 'repo-root.txt',
    M.read_runtime_metadata_file 'repo-main-root.txt',
  } do
    if root and root ~= '' and not seen[root] then
      roots[#roots + 1] = root
      seen[root] = true
    end
  end

  return roots
end

function M.wsl_distro_from_domain(domain_name)
  if not domain_name then
    return nil
  end

  return domain_name:match '^WSL:(.+)$'
end

function M.active_workspace_name(window)
  local mux_window = window and window:mux_window()
  if mux_window then
    return mux_window:get_workspace()
  end

  return (window and window:active_workspace()) or 'default'
end

function M.file_path_from_cwd(cwd)
  if not cwd then
    return nil
  end

  local ok, file_path = pcall(function()
    return cwd.file_path
  end)
  if ok and file_path then
    return file_path
  end

  local cwd_text = tostring(cwd)
  return cwd_text:match '^file://[^/]*(/.*)$'
end

function M.basename(path)
  if not path or path == '' then
    return ''
  end

  return path:match('([^/\\]+)[/\\]?$') or path
end

function M.foreground_process_basename(pane)
  if not pane or not pane.get_foreground_process_name then
    return nil
  end

  local ok, process_name = pcall(function()
    return pane:get_foreground_process_name()
  end)
  if not ok or not process_name or process_name == '' then
    return nil
  end

  return M.basename(process_name)
end

function M.copy_args(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[#result + 1] = value
  end
  return result
end

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

function M.is_windows_host_path(path)
  if not path or path == '' then
    return false
  end

  return path:match '^/[A-Za-z]:/' ~= nil
end

return M
