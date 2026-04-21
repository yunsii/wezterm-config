local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.'
local module_dir = join_path(runtime_dir, 'lua', 'host')

local function load_feature(name)
  return dofile(join_path(module_dir, 'features', name .. '.lua'))
end

local feature_builders = {
  vscode = load_feature 'vscode',
  chrome_debug = load_feature 'chrome_debug',
  clipboard_image = load_feature 'clipboard_image',
  ime_state = load_feature 'ime_state',
}

function M.build(runtime)
  local features = {}

  for name, builder in pairs(feature_builders) do
    features[name] = builder(runtime)
  end

  return features
end

return M
