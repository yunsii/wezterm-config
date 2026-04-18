local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local source = debug.getinfo(1, 'S').source:match '^@(.+)$'
local module_dir = source and source:match('^(.*)[/\\][^/\\]+$') or '.'

local function load_feature(name)
  return dofile(join_path(module_dir, 'features', name .. '.lua'))
end

local feature_builders = {
  vscode = load_feature 'vscode',
  chrome_debug = load_feature 'chrome_debug',
  clipboard_image = load_feature 'clipboard_image',
}

function M.build(runtime)
  local features = {}

  for name, builder in pairs(feature_builders) do
    features[name] = builder(runtime)
  end

  return features
end

return M
