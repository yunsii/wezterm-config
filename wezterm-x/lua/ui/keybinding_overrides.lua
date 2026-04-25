-- Load and parse wezterm-x/local/keybindings.lua into a resolver that the
-- keymap builder consults when deciding the final (key, mods) for each
-- entry. Pure module: no wezterm calls, testable in isolation.
--
-- Phase 1 scope: only WezTerm-layer bindings are customizable. Overrides
-- that would require re-rendering tmux chord tables are out of scope for
-- now and will be surfaced as warnings at the call site.

local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir_hint = rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.'
local helpers = dofile(join_path(runtime_dir_hint, 'lua', 'helpers.lua'))

local M = {}

local MOD_ALIASES = {
  ctrl = 'CTRL', control = 'CTRL',
  shift = 'SHIFT',
  alt = 'ALT', opt = 'ALT', option = 'ALT', meta = 'ALT',
  cmd = 'SUPER', super = 'SUPER', win = 'SUPER', windows = 'SUPER',
}

local SINGLE_SENTINEL = '__single__'

local function args_key(args)
  if args == nil then
    return '__nil__'
  end
  return type(args) .. ':' .. tostring(args)
end

local function split_on_plus(raw)
  local parts = {}
  for piece in raw:gmatch('[^+]+') do
    parts[#parts + 1] = piece
  end
  return parts
end

function M.parse_key_string(raw)
  if type(raw) ~= 'string' or raw == '' then
    return nil, 'key must be a non-empty string'
  end
  if raw:find(' ', 1, true) then
    return nil, 'chord keys (space-separated segments) are not supported in this phase; override chord leaves via tmux directly'
  end
  local pieces = split_on_plus(raw)
  if #pieces == 0 then
    return nil, 'empty key expression'
  end
  local key = pieces[#pieces]
  if key == '' then
    return nil, 'key token is empty'
  end
  local seen, mods = {}, {}
  for i = 1, #pieces - 1 do
    local token = pieces[i]:lower()
    local canonical = MOD_ALIASES[token]
    if not canonical then
      return nil, 'unknown modifier: ' .. pieces[i]
    end
    if not seen[canonical] then
      seen[canonical] = true
      mods[#mods + 1] = canonical
    end
  end
  table.sort(mods)
  return { key = key, mods = table.concat(mods, '|') }
end

-- Read wezterm-x/local/keybindings.lua. Missing file -> empty table. A
-- syntax error in the user file propagates (helpers.load_optional_table
-- uses pcall+error) so the startup log shows the file and line.
function M.load(runtime_dir)
  if not runtime_dir or runtime_dir == '' then
    return {}
  end
  local path = join_path(runtime_dir, 'local', 'keybindings.lua')
  local raw = helpers.load_optional_table(path)
  if raw == nil then
    return {}
  end
  if type(raw) ~= 'table' then
    return {}
  end
  return raw
end

-- Given the raw override table and the meta list from keymaps.lua
-- (`{ { id, args, layer }, ... }`), return:
--   resolve(id, args) -> nil | { disabled = true } | { key, mods }
--   warnings          -> list of human-readable warning strings
--
-- Overrides for tmux-chord layer ids are silently accepted (no warnings
-- emitted): the tmux side has its own bash parser (render-tmux-bindings.sh)
-- that consumes the same local/keybindings.lua file at runtime-sync time.
-- We still register the ids as "known" so users don't see spurious
-- "unknown id" warnings for valid chord overrides.
function M.build(raw, id_meta)
  raw = raw or {}
  local warnings = {}
  local disabled_ids = {}
  local per_entry = {}

  local count_by_id = {}        -- how many hotkeys across all layers
  local wezterm_count_by_id = {} -- how many hotkeys on the wezterm layer only
  for _, meta in ipairs(id_meta or {}) do
    count_by_id[meta.id] = (count_by_id[meta.id] or 0) + 1
    if meta.layer == nil or meta.layer == 'wezterm' then
      wezterm_count_by_id[meta.id] = (wezterm_count_by_id[meta.id] or 0) + 1
    end
  end

  local function warn(msg) warnings[#warnings + 1] = msg end

  local function register(id, key_for_lookup, parsed)
    per_entry[id] = per_entry[id] or {}
    per_entry[id][key_for_lookup] = parsed
  end

  local function handle_table_element(id, i, element, hotkey_count)
    if type(element) ~= 'table' or type(element.key) ~= 'string' then
      warn(string.format('override for %q: element #%d must be a table with a `key` string', id, i))
      return
    end
    local parsed, err = M.parse_key_string(element.key)
    if not parsed then
      warn(string.format('override for %q element #%d: %s', id, i, err))
      return
    end
    if element.args == nil then
      if hotkey_count ~= 1 then
        warn(string.format(
          'override for %q element #%d: id has %d default hotkeys, `args` is required to disambiguate',
          id, i, hotkey_count))
        return
      end
      register(id, SINGLE_SENTINEL, parsed)
    else
      register(id, args_key(element.args), parsed)
    end
  end

  for id, value in pairs(raw) do
    if type(id) ~= 'string' or id == '' then
      warn('override key must be a non-empty string; got ' .. type(id))
    elseif count_by_id[id] == nil then
      warn(string.format(
        'override references unknown id %q; it is not registered in commands/manifest.json', id))
    elseif wezterm_count_by_id[id] == nil then
      -- Id exists in manifest but not on the wezterm layer (e.g. tmux-chord
      -- leaf). Accept silently; the bash renderer handles it at sync time.
      if value == false then
        disabled_ids[id] = true
      end
    elseif value == false then
      disabled_ids[id] = true
    elseif type(value) == 'string' then
      if wezterm_count_by_id[id] ~= 1 then
        warn(string.format(
          'override for %q uses a single string but the id has %d default hotkeys; use the list form { { key = "...", args = N }, ... }',
          id, wezterm_count_by_id[id]))
      else
        local parsed, err = M.parse_key_string(value)
        if not parsed then
          warn(string.format('override for %q: %s', id, err))
        else
          register(id, SINGLE_SENTINEL, parsed)
        end
      end
    elseif type(value) == 'table' then
      for i, element in ipairs(value) do
        handle_table_element(id, i, element, wezterm_count_by_id[id])
      end
    else
      warn(string.format('override for %q: unsupported value type %s', id, type(value)))
    end
  end

  local function resolve(id, args)
    if disabled_ids[id] then
      return { disabled = true }
    end
    local per = per_entry[id]
    if not per then
      return nil
    end
    local target = per[args_key(args)] or per[SINGLE_SENTINEL]
    if target == nil then
      return nil
    end
    return { key = target.key, mods = target.mods }
  end

  return resolve, warnings
end

return M
