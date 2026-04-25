-- Agent attention — presentation side.
--
-- State lives in a JSON file managed by the hook (scripts/claude-hooks/
-- emit-agent-status.sh) and the jump orchestrator (scripts/runtime/
-- attention-jump.sh). See docs/tmux-ui.md#agent-attention.
--
-- This module only renders tab badges and the right-status segment. It
-- does not emit OSC, does not walk mux panes, and does not own jump.
-- The hook nudges us via OSC 1337 SetUserVar=attention_tick=<ms>;
-- titles.lua owns the user-var-changed handler so it can re-render
-- right-status in the same call (sub-frame latency). update-status
-- (driven by titles.lua at `status_update_interval`) is the fallback
-- refresher and owns periodic housekeeping: TTL prune and focus-ack.

local wezterm = require 'wezterm'

local M = {}

M.USER_VAR_TICK = 'attention_tick'
M.STATUS_RUNNING = 'running'
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
-- Focus-based auto-ack removes the entry with no grace window — focusing
-- the pane *is* the acknowledgement, so the counter should drop as soon
-- as the user's eyes are there. The `--only-if-ts` guard in the jump
-- script still protects against wiping a fresher entry (same session_id,
-- new ts) landed in the ~50ms subprocess window.
M.FOCUS_ACK_DELAY_SECONDS = 0

local state_path = nil
local state_cache = { entries = {} }
local prune_spawner = nil
local forget_spawner = nil
local focus_ack_scheduled = {}
-- Map of session_id → ts for entries we have scheduled for removal and
-- optimistically hidden from the in-memory cache. reload_state re-applies
-- the hide until the disk read confirms the entry is gone (or replaced
-- by a fresh ts, which means a new transition has superseded the hide).
local hidden_entries = {}
-- tmux-pane focus lookups, keyed by "<socket>|<session>". Reset on every
-- reload_state so a single render tick shares the file read across
-- is_entry_focused + maybe_ack_focused but successive ticks always
-- re-read the focus file.
local tmux_focus_cache = {}
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
  -- Clear the per-tick tmux-focus lookup cache so the next tick re-reads
  -- the focus files. State reloads happen at most once per tick (either
  -- on user-var-changed or at update-status cadence).
  tmux_focus_cache = {}
  if not state_path then
    state_cache = { entries = {} }
    return state_cache
  end
  local content = read_file(state_path)
  if not content or content == '' then
    state_cache = { entries = {} }
  else
    local parsed = parse_json(content)
    if type(parsed) == 'table' and type(parsed.entries) == 'table' then
      state_cache = parsed
    else
      state_cache = { entries = {} }
    end
  end
  -- Re-apply optimistic hides: until the background --forget finishes on
  -- disk, we keep the entry hidden so the visible counter does not bounce
  -- between "scheduled for remove" and "still there". When the disk shows
  -- the entry gone (or replaced by a fresh ts), the hide is cleared.
  if next(hidden_entries) ~= nil then
    for sid, ts in pairs(hidden_entries) do
      local current = state_cache.entries[sid]
      if current == nil then
        hidden_entries[sid] = nil
      elseif tostring(current.ts) == tostring(ts) then
        state_cache.entries[sid] = nil
      else
        hidden_entries[sid] = nil
      end
    end
  end
  return state_cache
end

function M.collect()
  local waiting, running, done = {}, {}, {}
  local now = now_ms()
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) then
      if entry.status == M.STATUS_WAITING then
        table.insert(waiting, entry)
      elseif entry.status == M.STATUS_RUNNING then
        table.insert(running, entry)
      elseif entry.status == M.STATUS_DONE then
        table.insert(done, entry)
      end
    end
  end
  return waiting, done, running
end

-- opts.active_pane_id (optional): when provided, entries on the
-- currently-focused `(wezterm_pane_id, tmux_pane)` are filtered out of
-- the `waiting` and `done` counters. This is a visual fallback for
-- maybe_ack_focused, which usually removes them outright in the same
-- tick. `running` is *not* filtered: the counter is meant to reflect
-- the total number of parallel turns in flight so the user can tell at
-- a glance how many tasks they are juggling — hiding the focused one
-- would make "⟳ N" under-count and defeat that purpose when switching
-- between parallel agents.
function M.render_status_segment(palette, opts)
  local waiting, done, running = M.collect()
  local active_pane_id = opts and opts.active_pane_id
  if active_pane_id ~= nil and active_pane_id ~= '' then
    local function drop_focused(list)
      local out = {}
      for _, entry in ipairs(list) do
        if not M.is_entry_focused(entry, active_pane_id) then
          table.insert(out, entry)
        end
      end
      return out
    end
    waiting = drop_focused(waiting)
    done = drop_focused(done)
  end
  local idle_bg = palette.tab_bar_background
  local idle_fg = palette.new_tab_fg

  local parts = {}

  -- Running first: rendered as soft always-on status so the user can see
  -- at a glance which panes are mid-turn. The segment dims to `idle_bg`
  -- when zero so the bar width stays stable.
  if #running > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_running_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_running_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ⟳ ' .. #running .. ' running ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ⟳ 0 running ' })
  end

  -- Fixed one-cell gap so the segment width stays stable between idle and
  -- active states; prevents the right side of the tab bar from jittering.
  table.insert(parts, { Background = { Color = idle_bg } })
  table.insert(parts, { Text = ' ' })

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
  local has_waiting, has_running, has_done = false, false, false
  local now = now_ms()
  -- When the tab is the active one in its window and the tmux-pane
  -- focus matches the entry, suppress `waiting` / `done` badges — the
  -- user is looking at that exact pane, so those would be noise.
  -- `running` is still shown even under focus so a parallel-task view
  -- across tabs stays truthful (consistent with the right-status
  -- counter rule).
  local tab_is_active = tab_info.is_active == true
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) and tostring(entry.wezterm_pane_id or '') == pane_id_str then
      local suppress_for_focus = tab_is_active and M.is_entry_focused(entry, pane_id_str)
      if entry.status == M.STATUS_WAITING then
        if not suppress_for_focus then has_waiting = true end
      elseif entry.status == M.STATUS_RUNNING then
        has_running = true
      elseif entry.status == M.STATUS_DONE then
        if not suppress_for_focus then has_done = true end
      end
    end
  end
  -- Priority: waiting (needs action) > running (live) > done (informational).
  -- Shapes progress from filled to hollow so the badge remains scannable
  -- without leaning only on color: ● waiting, ◐ running, ○ done.
  if has_waiting then
    return { status = M.STATUS_WAITING, marker = '●' }
  elseif has_running then
    return { status = M.STATUS_RUNNING, marker = '◐' }
  elseif has_done then
    return { status = M.STATUS_DONE, marker = '○' }
  end
  return nil
end

function M.badge_colors(palette, status)
  if status == M.STATUS_WAITING then
    return palette.tab_attention_waiting_bg, palette.tab_attention_waiting_fg
  elseif status == M.STATUS_RUNNING then
    return palette.tab_attention_running_bg, palette.tab_attention_running_fg
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
  local waiting, done, running = M.collect()
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
  enrich(running)
  enrich(done)
  local result = {}
  for _, e in ipairs(waiting) do
    table.insert(result, e)
  end
  for _, e in ipairs(running) do
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

-- Read the active tmux pane id for (socket, session), as recorded by
-- scripts/runtime/tmux-focus-emit.sh from tmux's pane-focus-in /
-- after-select-pane hooks. Returns nil when the state file does not
-- exist yet (no focus event has fired in that session since server
-- start) — callers treat that as "unknown" and fail closed.
local function read_tmux_active_pane(socket, session)
  if type(socket) ~= 'string' or socket == ''
    or type(session) ~= 'string' or session == '' then
    return nil
  end
  if not state_path then
    return nil
  end
  -- Strip the trailing filename. Accept either separator: state_path is
  -- built with the host's path separator (constants.lua / defaults.lua),
  -- so on Windows it is backslash-separated. Lua io.open accepts both
  -- on Windows but a `/`-only regex would silently miss and we would
  -- never read the focus file.
  local base_dir = state_path:match('^(.*)[/\\][^/\\]+$')
  if not base_dir then
    return nil
  end
  -- Mirror the filename transform in tmux-focus-emit.sh so both sides
  -- agree on the path without having to parse the full socket string.
  -- Use forward slash for the subdirectory join: Windows io.open
  -- accepts mixed separators, and this keeps the path readable in logs.
  local safe_socket = (socket:gsub('/', '_'))
  local safe_session = (session:gsub('^%$', ''))
  local path = base_dir .. '/tmux-focus/' .. safe_socket .. '__' .. safe_session .. '.txt'
  local content = read_file(path)
  if not content or content == '' then
    return nil
  end
  return (content:gsub('%s+$', ''))
end

-- Cached tmux-focus lookup. Keyed by "<socket>|<session>". Populated on
-- demand and cleared by reload_state so one render tick shares reads
-- across is_entry_focused + maybe_ack_focused but successive ticks
-- always see fresh focus state.
local function cached_tmux_focus(socket, session)
  local key = (socket or '') .. '|' .. (session or '')
  local cached = tmux_focus_cache[key]
  if cached == nil then
    cached = read_tmux_active_pane(socket, session)
    if cached == nil then cached = false end
    tmux_focus_cache[key] = cached
  end
  if cached == false then return nil end
  return cached
end

-- True when the entry belongs to the currently-focused (WezTerm pane +
-- tmux pane). When the entry carries tmux coordinates we require the
-- tmux-focus file to name the entry's pane; missing or mismatched focus
-- files fail closed (treated as "not focused") so entries are shown
-- when in doubt rather than hidden. Callers use this both in the render
-- path (skip the entry from right-status / tab badge — rule: focused
-- pane does not enter stats) and in the auto-ack path (schedule
-- --forget for waiting/done).
function M.is_entry_focused(entry, wezterm_pane_id)
  if not entry or wezterm_pane_id == nil or wezterm_pane_id == '' then
    return false
  end
  if tostring(entry.wezterm_pane_id or '') ~= tostring(wezterm_pane_id) then
    return false
  end
  if type(entry.tmux_socket) == 'string' and entry.tmux_socket ~= ''
    and type(entry.tmux_pane) == 'string' and entry.tmux_pane ~= '' then
    local active = cached_tmux_focus(entry.tmux_socket, entry.tmux_session)
    if active == nil then
      return false
    end
    return active == entry.tmux_pane
  end
  return true
end

-- Auto-ack: when the currently-focused pane matches a live `waiting` or
-- `done` entry, spawn --forget immediately (no grace window) and hide
-- the entry from the in-memory cache in the same tick so the counter
-- drops without waiting for the subprocess to land the write on disk.
-- Both states are user-action signals — sitting on the pane *is* the
-- acknowledgement, so the badge and counter clear without a second
-- gesture. `running` is excluded: it is a live indicator of current
-- work, not an action item, and it will transition to waiting or done
-- on its own as the agent progresses.
--
-- The --only-if-ts guard in the jump script still protects against the
-- ~50ms race where a fresh entry (same session_id, new ts) could land
-- between Lua scheduling the forget and the subprocess executing.
-- Dedup by (session_id, ts) so the tick loop does not re-spawn the
-- subprocess while focus stays put.
--
-- When the entry carries tmux coordinates, require tmux-pane-level focus
-- as well: one WezTerm pane commonly hosts an entire tmux session, so the
-- WezTerm pane_id alone cannot distinguish "user is looking at the agent
-- pane" from "user has moved to another tmux pane in the same session".
-- On tmux-focus mismatch or unknown focus, we skip *and* leave dedup
-- unset so the next tick re-checks after the user's tmux pane switch
-- fires pane-focus-in / after-select-pane and the state file catches up.
function M.maybe_ack_focused(window, pane)
  if type(forget_spawner) ~= 'function' then
    return
  end
  if not pane or type(pane.pane_id) ~= 'function' then
    return
  end
  local ok_pid, pane_id = pcall(function() return pane:pane_id() end)
  if not ok_pid or pane_id == nil then
    return
  end
  local pane_id_str = tostring(pane_id)
  local now = now_ms()
  local live_sids = {}
  -- Collect sids to hide after the iteration so we do not mutate
  -- state_cache.entries mid-`pairs`.
  local to_hide = {}
  for sid, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) then
      live_sids[sid] = true
      if (entry.status == M.STATUS_DONE or entry.status == M.STATUS_WAITING)
        and M.is_entry_focused(entry, pane_id_str) then
        local ts = entry.ts
        if ts ~= nil and focus_ack_scheduled[sid] ~= ts then
          focus_ack_scheduled[sid] = ts
          to_hide[sid] = ts
          local forget_args = {
            '--forget', sid,
            '--only-if-ts', tostring(ts),
          }
          if M.FOCUS_ACK_DELAY_SECONDS > 0 then
            table.insert(forget_args, '--delay')
            table.insert(forget_args, tostring(M.FOCUS_ACK_DELAY_SECONDS))
          end
          local args = forget_spawner(forget_args)
          if type(args) == 'table' and #args > 0 then
            pcall(function() wezterm.background_child_process(args) end)
            if module_logger then
              module_logger.info('attention', 'focus ack scheduled', {
                session_id = sid,
                pane_id = pane_id_str,
                status = entry.status,
                tmux_pane = entry.tmux_pane,
                delay_s = M.FOCUS_ACK_DELAY_SECONDS,
                ts = ts,
              })
            end
          end
        end
      end
    end
  end
  for sid, _ in pairs(focus_ack_scheduled) do
    if not live_sids[sid] then
      focus_ack_scheduled[sid] = nil
    end
  end
  -- Apply optimistic hides after the iteration: drop from the live
  -- cache and record the ts so reload_state keeps them hidden until
  -- the subprocess lands the write on disk.
  for sid, ts in pairs(to_hide) do
    hidden_entries[sid] = ts
    state_cache.entries[sid] = nil
  end
end

function M.register(opts)
  module_logger = opts and opts.logger
  if opts and type(opts.prune_spawner) == 'function' then
    prune_spawner = opts.prune_spawner
  end
  if opts and type(opts.forget_spawner) == 'function' then
    forget_spawner = opts.forget_spawner
  end
  if opts and opts.constants and opts.constants.attention and opts.constants.attention.state_file then
    state_path = opts.constants.attention.state_file
  elseif opts and opts.state_file then
    state_path = opts.state_file
  end

  M.reload_state()

  -- The user-var-changed handler lives in titles.lua so it can re-render
  -- the right-status segment in the same call that reloads state. This
  -- cuts the OSC-to-repaint latency from "up to 250ms" (next
  -- update-status tick) to one frame. Other modules that need to react
  -- to attention ticks should call M.reload_state() and read the cache.
end

return M
