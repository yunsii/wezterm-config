-- Agent attention — presentation side.
--
-- State lives in a JSON file managed by the hook (scripts/claude-hooks/
-- emit-agent-status.sh) and the jump orchestrator (scripts/runtime/
-- attention-jump.sh). See docs/tmux-ui.md#agent-attention.
--
-- This module only renders tab badges and the right-status segment. It
-- does not emit OSC, does not walk mux panes, and does not own jump.
-- The hook nudges us via OSC 1337 SetUserVar=attention_tick=<ms>, which
-- fires user-var-changed in Lua, at which point we re-read the state
-- file. update-status (driven by titles.lua) is the fallback refresher.

local wezterm = require 'wezterm'

local M = {}

M.USER_VAR_TICK = 'attention_tick'
M.STATUS_WAITING = 'waiting'
M.STATUS_DONE = 'done'

-- Aligned with scripts/runtime/attention-state-lib.sh (attention_state_prune
-- default). The Lua-side filter hides entries that passed the TTL even
-- before the periodic shell prune physically removes them from state.json.
M.TTL_MS = 1800000
-- Periodic prune pacing. update-status fires every `status_update_interval`
-- (250ms by default), but the actual shell spawn is self-throttled to at
-- most one every PRUNE_INTERVAL_MS.
M.PRUNE_INTERVAL_MS = 60000

local state_path = nil
local state_cache = { entries = {} }
local prune_spawner = nil
local last_prune_ms = 0
local module_logger = nil

local function now_ms()
  local ok, formatted = pcall(function()
    return wezterm.time.now():format '%s%3f'
  end)
  if ok and type(formatted) == 'string' and formatted:match '^%d+$' then
    return tonumber(formatted)
  end
  return os.time() * 1000
end

local function entry_is_live(entry, now)
  if type(entry) ~= 'table' then
    return false
  end
  local ts = tonumber(entry.ts)
  if not ts then
    -- Missing ts: treat as live. The shell-side prune will eventually
    -- normalize or drop the entry; we do not want a corrupt row to
    -- silently hide a valid one.
    return true
  end
  return (now - ts) <= M.TTL_MS
end

local function parse_json(text)
  if type(text) ~= 'string' or text == '' then
    return nil
  end
  if wezterm.json_parse then
    local ok, parsed = pcall(wezterm.json_parse, text)
    if ok then
      return parsed
    end
  end
  if wezterm.serde and wezterm.serde.json_decode then
    local ok, parsed = pcall(wezterm.serde.json_decode, text)
    if ok then
      return parsed
    end
  end
  return nil
end

function M.configure(opts)
  if opts and type(opts.state_file) == 'string' and opts.state_file ~= '' then
    state_path = opts.state_file
  end
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local content = f:read('*a')
  f:close()
  return content
end

function M.reload_state()
  if not state_path then
    state_cache = { entries = {} }
    return state_cache
  end
  local content = read_file(state_path)
  if not content or content == '' then
    state_cache = { entries = {} }
    return state_cache
  end
  local parsed = parse_json(content)
  if type(parsed) == 'table' and type(parsed.entries) == 'table' then
    state_cache = parsed
  else
    state_cache = { entries = {} }
  end
  return state_cache
end

function M.collect()
  local waiting, done = {}, {}
  local now = now_ms()
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) then
      if entry.status == M.STATUS_WAITING then
        table.insert(waiting, entry)
      elseif entry.status == M.STATUS_DONE then
        table.insert(done, entry)
      end
    end
  end
  return waiting, done
end

function M.render_status_segment(palette)
  local waiting, done = M.collect()
  local idle_bg = palette.tab_bar_background
  local idle_fg = palette.new_tab_fg

  local parts = {}
  if #waiting > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_waiting_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_waiting_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Bold' } })
    table.insert(parts, { Text = ' ⚠ ' .. #waiting .. ' waiting ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ⚠ 0 waiting ' })
  end

  -- Fixed one-cell gap so the segment width stays stable between idle and
  -- active states; prevents the right side of the tab bar from jittering.
  table.insert(parts, { Background = { Color = idle_bg } })
  table.insert(parts, { Text = ' ' })

  if #done > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_done_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_done_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ✓ ' .. #done .. ' done ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ✓ 0 done ' })
  end
  return wezterm.format(parts)
end

function M.tab_badge(tab_info)
  local active = tab_info and tab_info.active_pane
  if not active or active.pane_id == nil then
    return nil
  end
  local pane_id_str = tostring(active.pane_id)
  local has_waiting, has_done = false, false
  local now = now_ms()
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) and tostring(entry.wezterm_pane_id or '') == pane_id_str then
      if entry.status == M.STATUS_WAITING then
        has_waiting = true
      elseif entry.status == M.STATUS_DONE then
        has_done = true
      end
    end
  end
  if has_waiting then
    return { status = M.STATUS_WAITING, marker = '●' }
  elseif has_done then
    return { status = M.STATUS_DONE, marker = '○' }
  end
  return nil
end

function M.badge_colors(palette, status)
  if status == M.STATUS_WAITING then
    return palette.tab_attention_waiting_bg, palette.tab_attention_waiting_fg
  elseif status == M.STATUS_DONE then
    return palette.tab_attention_done_bg, palette.tab_attention_done_fg
  end
  return palette.tab_bar_background, palette.tab_accent
end

-- Walk the mux looking for the pane with id `wezterm_pane_id`. Returns
-- { workspace, tab_index, tab_title } when found, nil otherwise.
local function resolve_live_location(wezterm_pane_id)
  if wezterm_pane_id == nil or wezterm_pane_id == '' then
    return nil
  end
  local target = tostring(wezterm_pane_id)
  local ok_all, all_windows = pcall(wezterm.mux.all_windows)
  if not ok_all or type(all_windows) ~= 'table' then
    return nil
  end
  for _, mux_win in ipairs(all_windows) do
    local workspace
    if mux_win.get_workspace then
      local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
      if ok_ws then workspace = ws end
    end
    local ok_tabs, tabs = pcall(function() return mux_win:tabs() end)
    if ok_tabs and type(tabs) == 'table' then
      for tab_idx, mux_tab in ipairs(tabs) do
        local ok_panes, panes_with_info = pcall(function() return mux_tab:panes_with_info() end)
        if ok_panes and type(panes_with_info) == 'table' then
          for _, info in ipairs(panes_with_info) do
            local pane = info.pane
            local pid_ok, pid = pcall(function() return pane:pane_id() end)
            if pid_ok and tostring(pid) == target then
              local tab_title
              if mux_tab.get_title then
                local ok_title, title = pcall(function() return mux_tab:get_title() end)
                if ok_title then tab_title = title end
              end
              if (not tab_title or tab_title == '') and pane.get_title then
                local ok_ptitle, ptitle = pcall(function() return pane:get_title() end)
                if ok_ptitle then tab_title = ptitle end
              end
              return {
                workspace = workspace,
                tab_index = tab_idx,
                tab_title = tab_title,
              }
            end
          end
        end
      end
    end
  end
  return nil
end

-- Return a flat array of live entries, waiting first then done, ordered by
-- ascending ts within each group. Each element preserves the raw entry and
-- adds `age_ms` plus a resolved `.live` table with workspace / tab_index /
-- tab_title when the WezTerm pane id still resolves.
function M.list()
  local waiting, done = M.collect()
  local now = now_ms()
  local function enrich(arr)
    for _, entry in ipairs(arr) do
      entry.age_ms = now - (tonumber(entry.ts) or now)
      entry.live = resolve_live_location(entry.wezterm_pane_id)
    end
    table.sort(arr, function(a, b)
      return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0)
    end)
  end
  enrich(waiting)
  enrich(done)
  local result = {}
  for _, e in ipairs(waiting) do
    table.insert(result, e)
  end
  for _, e in ipairs(done) do
    table.insert(result, e)
  end
  return result
end

-- Locate and activate the WezTerm pane identified by `pane_id_value`.
-- Performs a workspace switch when the target lives in a different one
-- than the current GUI window, then activates the mux tab/pane so the
-- WezTerm window shows the right content.
-- Returns true when the pane was found.
function M.activate_in_gui(pane_id_value, window, source_pane)
  if pane_id_value == nil or pane_id_value == '' then
    return false
  end
  local target_id = tostring(pane_id_value)
  local ok_all, all_windows = pcall(wezterm.mux.all_windows)
  if not ok_all or type(all_windows) ~= 'table' then
    return false
  end
  for _, mux_win in ipairs(all_windows) do
    local ok_tabs, tabs = pcall(function() return mux_win:tabs() end)
    if ok_tabs and type(tabs) == 'table' then
      for _, mux_tab in ipairs(tabs) do
        local ok_panes, panes_with_info = pcall(function() return mux_tab:panes_with_info() end)
        if ok_panes and type(panes_with_info) == 'table' then
          for _, info in ipairs(panes_with_info) do
            local pid_ok, pid = pcall(function() return info.pane:pane_id() end)
            if pid_ok and tostring(pid) == target_id then
              local target_ws
              if mux_win.get_workspace then
                local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
                if ok_ws then target_ws = ws end
              end
              if window and target_ws and target_ws ~= '' then
                local current_ws
                if window.active_workspace then
                  local ok_cur, cur = pcall(function() return window:active_workspace() end)
                  if ok_cur then current_ws = cur end
                end
                if current_ws ~= target_ws then
                  pcall(function()
                    window:perform_action(
                      wezterm.action.SwitchToWorkspace { name = target_ws },
                      source_pane
                    )
                  end)
                end
              end
              pcall(function() mux_tab:activate() end)
              pcall(function() info.pane:activate() end)
              return true
            end
          end
        end
      end
    end
  end
  return false
end

-- Pick next entry matching `kind` ('waiting' or 'done'). Prefers entries
-- whose wezterm_pane_id differs from `current_pane_id` so repeated presses
-- cycle. Returns the entry or nil.
function M.pick_next(kind, current_pane_id)
  local waiting, done = M.collect()
  local pool = kind == M.STATUS_DONE and done or waiting
  if #pool == 0 then
    return nil
  end
  table.sort(pool, function(a, b)
    return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0)
  end)
  local current = current_pane_id and tostring(current_pane_id) or nil
  for _, entry in ipairs(pool) do
    if not current or tostring(entry.wezterm_pane_id or '') ~= current then
      return entry
    end
  end
  return pool[1]
end

-- Periodic shell-side prune. Called from titles.lua's update-status tick
-- (every `status_update_interval`, default 250ms). Self-throttles to one
-- background spawn per PRUNE_INTERVAL_MS so the wsl.exe → bash cold start
-- only happens at the configured cadence, not every frame. Does nothing
-- when no `prune_spawner` has been injected via register().
function M.maybe_prune()
  if type(prune_spawner) ~= 'function' then
    return
  end
  local now = now_ms()
  if (now - last_prune_ms) < M.PRUNE_INTERVAL_MS then
    return
  end
  last_prune_ms = now
  local args = prune_spawner({ '--prune', '--ttl', tostring(M.TTL_MS) })
  if type(args) == 'table' and #args > 0 then
    pcall(function() wezterm.background_child_process(args) end)
    if module_logger then
      module_logger.info('attention', 'periodic prune scheduled', {
        ttl_ms = M.TTL_MS,
        interval_ms = M.PRUNE_INTERVAL_MS,
      })
    end
  end
end

function M.register(opts)
  local logger = opts and opts.logger
  module_logger = logger
  if opts and type(opts.prune_spawner) == 'function' then
    prune_spawner = opts.prune_spawner
  end
  if opts and opts.constants and opts.constants.attention and opts.constants.attention.state_file then
    state_path = opts.constants.attention.state_file
  elseif opts and opts.state_file then
    state_path = opts.state_file
  end

  M.reload_state()

  wezterm.on('user-var-changed', function(window, pane, name, value)
    if name ~= M.USER_VAR_TICK then
      return
    end
    M.reload_state()
    if logger then
      logger.info('attention', 'tick received', {
        pane_id = pane and pane.pane_id and pane:pane_id() or nil,
        value = value,
      })
    end
  end)
end

return M
