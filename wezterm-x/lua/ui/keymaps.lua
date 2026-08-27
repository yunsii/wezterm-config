-- Keymap builder. Iterates `commands/manifest.json`, resolves each
-- wezterm-layer hotkey through `keybinding_overrides.lua`, dispatches the
-- action via `action_registry.lua`, and wraps the final entry with the
-- usage-counter bump plus latency timing (see lua/latency.lua).
--
-- This file owns no binding data anymore — adding a shortcut means adding
-- an item in manifest.json and a handler in action_registry.lua.

local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.'
local module_dir = join_path(runtime_dir, 'lua', 'ui')
local overrides_lib = dofile(join_path(module_dir, 'keybinding_overrides.lua'))
local action_registry = dofile(join_path(module_dir, 'action_registry.lua'))
local latency = dofile(join_path(runtime_dir, 'lua', 'latency.lua'))

local function load_manifest(wezterm)
  local path = join_path(runtime_dir, 'commands', 'manifest.json')
  local fd, open_err = io.open(path, 'r')
  if not fd then
    return nil, 'cannot open manifest at ' .. path .. ': ' .. tostring(open_err)
  end
  local content = fd:read('*a')
  fd:close()
  if not wezterm.serde or not wezterm.serde.json_decode then
    return nil, 'wezterm.serde.json_decode unavailable in this WezTerm build'
  end
  local ok, parsed = pcall(wezterm.serde.json_decode, content)
  if not ok then
    return nil, 'cannot parse manifest: ' .. tostring(parsed)
  end
  if type(parsed) ~= 'table' then
    return nil, 'manifest root must be an array, got ' .. type(parsed)
  end
  return parsed
end

local M = {}

function M.build(opts)
  local wezterm = opts.wezterm
  local workspace = opts.workspace
  local constants = opts.constants
  local logger = opts.logger
  local host = opts.host
  local attention = opts.attention
  local usage = opts.usage
  local raw_overrides = opts.raw_overrides or {}

  -- Wrap an entry so pressing the key:
  --   1. bumps the aggregate usage counter (fire-and-forget);
  --   2. emits hotkey/pressed then hotkey/dispatched audit rows so a
  --      "key did nothing" report can distinguish "binding never fired"
  --      from "binding fired but action was a no-op / queued behind a
  --      slow update-status";
  --   3. records threshold-gated latency (diagnostics.wezterm.latency).
  -- Stashes hotkey_id on _G for the duration of perform_action so
  -- nested action logs (e.g. workspace.open) can cite the same id.
  local lat_cfg = latency.config(constants)
  local function inst(hotkey_id, entry)
    local original_action = entry.action
    entry.action = wezterm.action_callback(function(window, pane)
      local ctx = { window = window, pane = pane }
      local t0 = latency.now_ms(wezterm)
      if usage and usage.bump then
        usage.bump(hotkey_id, ctx)
      end
      if usage and usage.log_event then
        usage.log_event('pressed', hotkey_id, ctx)
      elseif logger and logger.info then
        logger.info('hotkey', 'pressed', { hotkey_id = hotkey_id })
      end
      local prev_hotkey = rawget(_G, '__WEZTERM_ACTIVE_HOTKEY_ID')
      _G.__WEZTERM_ACTIVE_HOTKEY_ID = hotkey_id
      local ok_action, action_err = pcall(function()
        window:perform_action(original_action, pane)
      end)
      _G.__WEZTERM_ACTIVE_HOTKEY_ID = prev_hotkey
      local t1 = latency.now_ms(wezterm)
      local duration_ms = (t0 and t1) and (t1 - t0) or nil
      local dispatch_fields = {}
      if duration_ms then
        dispatch_fields.duration_ms = duration_ms
      end
      if not ok_action then
        dispatch_fields.ok = '0'
        dispatch_fields.err = tostring(action_err)
      else
        dispatch_fields.ok = '1'
      end
      if usage and usage.log_event then
        usage.log_event('dispatched', hotkey_id, ctx, dispatch_fields)
      elseif logger and logger.info then
        dispatch_fields.hotkey_id = hotkey_id
        logger.info('hotkey', 'dispatched', dispatch_fields)
      end
      if logger and duration_ms then
        latency.observe(logger, lat_cfg, {
          kind = 'hotkey',
          duration_ms = duration_ms,
          window = window,
          pane = pane,
          fields = { hotkey_id = hotkey_id },
        })
      end
    end)
    return entry
  end

  local manifest, err = load_manifest(wezterm)
  if not manifest then
    logger.warn('keybindings', 'manifest load failed, returning empty keymap', { reason = err })
    return {}
  end

  local registry = action_registry.new {
    wezterm = wezterm,
    constants = constants,
    logger = logger,
    host = host,
    attention = attention,
    workspace = workspace,
  }

  -- First pass: collect (id, args, layer) meta for every hotkey in the
  -- manifest so keybinding_overrides can disambiguate single- vs.
  -- multi-hotkey ids AND distinguish wezterm-layer bindings (which we
  -- consume here) from tmux-chord ones (handled by the bash renderer).
  local meta = {}
  for _, item in ipairs(manifest) do
    if item.binding and item.hotkeys then
      for _, hk in ipairs(item.hotkeys) do
        meta[#meta + 1] = { id = item.id, args = hk.args, layer = hk.layer }
      end
    end
  end

  local resolve_override, override_warnings = overrides_lib.build(raw_overrides, meta)
  for _, msg in ipairs(override_warnings) do
    logger.warn('keybindings', 'override ignored', { reason = msg })
  end

  -- Second pass: build the entries, applying overrides and the registry.
  local final = {}

  local function process_hotkey(item, hk)
    if hk.layer ~= 'wezterm' then return end
    local decision = resolve_override(item.id, hk.args)
    if decision and decision.disabled then
      logger.info('keybindings', 'binding disabled by override', {
        id = item.id,
        args = hk.args,
      })
      return
    end
    local key, mods
    if decision and decision.key then
      key, mods = decision.key, decision.mods
      logger.info('keybindings', 'binding remapped by override', {
        id = item.id,
        args = hk.args,
        key = key,
        mods = mods,
      })
    else
      local parsed, parse_err = overrides_lib.parse_key_string(hk.keys)
      if not parsed then
        logger.warn('keybindings', 'manifest hotkey unparseable', {
          id = item.id,
          keys = hk.keys,
          reason = parse_err,
        })
        return
      end
      key, mods = parsed.key, parsed.mods
    end
    local action = registry.get(item.binding.handler, item.binding.args, hk.args)
    if action == nil then
      logger.warn('keybindings', 'manifest handler not registered', {
        id = item.id,
        handler = item.binding.handler,
      })
      return
    end
    local entry = { key = key, mods = mods, action = action }
    inst(item.id, entry)
    final[#final + 1] = entry
  end

  for _, item in ipairs(manifest) do
    if item.binding and item.hotkeys then
      for _, hk in ipairs(item.hotkeys) do
        process_hotkey(item, hk)
      end
    end
  end

  return final
end

return M
