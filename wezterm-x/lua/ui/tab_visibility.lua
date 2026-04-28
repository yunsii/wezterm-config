-- Tab-visibility brain. Reads scripts/runtime/tab-stats-lib.sh's per-
-- workspace JSON files on the WezTerm `update-status` tick (throttled to
-- recompute_interval_ms), computes the top-N frequency set, and assigns
-- sessions to sticky slots. Producers (titles.lua, workspace_manager.lua,
-- the future overflow picker) consume via get_slot_for_tab / visible_set
-- / warm_set.
--
-- Sticky slot algorithm:
--   1. compute visible = top-N sessions by (weight desc, raw_count desc, name asc)
--   2. for each existing slot:
--        if slot.session_name still in visible → keep, mark "stable"
--        else → mark "stale" (the existing session fell out)
--   3. for each session in visible not yet placed:
--        assign to the oldest stale slot (or the lowest empty slot index)
--        record swap timestamp on that slot
--   4. record warm = next M sessions after visible (for warm-spawn driver)
--
-- The set never shrinks below the existing slot count — once a slot has
-- been initialized, it keeps holding its session even if the session
-- ranking moves down, until a new top-N entrant explicitly displaces it.
-- Empty slots only exist before any session has ever been bumped (cold
-- start).

local M = {}

local DEFAULTS = {
  visible_count = 5,
  warm_count = 3,
  half_life_days = 7,
  recompute_interval_ms = 5000,
  swap_flash_ms = 800,
}

local function copy_with_defaults(opts, defaults)
  local out = {}
  for k, v in pairs(defaults) do out[k] = v end
  if type(opts) == 'table' then
    for k, v in pairs(opts) do out[k] = v end
  end
  return out
end

-- Same slug rule as scripts/runtime/tab-stats-lib.sh tab_stats_workspace_slug.
-- Lower-case, replace any char outside [a-z0-9_-] with `_`. Empty input
-- buckets to `_unknown`.
function M.workspace_slug(name)
  if name == nil or name == '' then return '_unknown' end
  local lowered = string.lower(name)
  local out = {}
  for i = 1, #lowered do
    local b = lowered:sub(i, i)
    if b:match('[a-z0-9_-]') then
      out[#out + 1] = b
    else
      out[#out + 1] = '_'
    end
  end
  return table.concat(out)
end

-- Pretty-print a tmux session_name for the tab bar. Sessions minted by
-- scripts/runtime/tmux-worktree/git.sh follow:
--     wezterm_<workspace>_<repo_label>_<10hex>
-- Strip the workspace prefix and the trailing hash so the user sees the
-- repo label as the slot title. For session names that don't follow the
-- pattern (legacy / hand-created), return the raw name unchanged.
function M.pretty_session_label(session_name, workspace_name)
  if not session_name or session_name == '' then return session_name end
  local label = session_name
  -- Strip trailing _<10hex> hash
  local trimmed = label:match('^(.+)_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$')
  if trimmed then label = trimmed end
  -- Strip wezterm_<workspace>_ prefix when present
  if workspace_name and workspace_name ~= '' then
    local ws_slug = M.workspace_slug(workspace_name)
    local prefix = 'wezterm_' .. ws_slug .. '_'
    if label:sub(1, #prefix) == prefix then
      label = label:sub(#prefix + 1)
    end
  end
  -- Bare "wezterm_" residual prefix without a workspace match → still strip
  if label:sub(1, 8) == 'wezterm_' then
    -- find the second underscore and cut after it
    local _, second = label:find('^wezterm_[^_]+_')
    if second then label = label:sub(second + 1) end
  end
  return label
end

local module_state = {
  configured = false,
  stats_dir = nil,
  visible_count = DEFAULTS.visible_count,
  warm_count = DEFAULTS.warm_count,
  half_life_days = DEFAULTS.half_life_days,
  recompute_interval_ms = DEFAULTS.recompute_interval_ms,
  swap_flash_ms = DEFAULTS.swap_flash_ms,
  spawn_visible_only = false,
  wezterm = nil,
  logger = nil,
  -- Per-workspace runtime cache:
  --   { last_recompute_ms, last_stats_mtime, stats,
  --     visible[], warm[], slots[ { session_name, last_swap_ms } ] }
  workspaces = {},
}

function M.configure(opts)
  opts = opts or {}
  local merged = copy_with_defaults(opts.config or {}, DEFAULTS)
  module_state.wezterm = opts.wezterm
  module_state.logger = opts.logger
  module_state.stats_dir = opts.config and opts.config.stats_dir or nil
  module_state.visible_count = merged.visible_count
  module_state.warm_count = merged.warm_count
  module_state.half_life_days = merged.half_life_days
  module_state.recompute_interval_ms = merged.recompute_interval_ms
  module_state.swap_flash_ms = merged.swap_flash_ms
  module_state.spawn_visible_only = (opts.config and opts.config.spawn_visible_only == true) or false
  module_state.configured = true
end

-- True only when the workspace is enabled AND the user has flipped on
-- spawn_visible_only. Gated separately because the cap creates a UX
-- regression until the overflow picker (PR3 phase 2) lands — without
-- the picker, capped sessions are unreachable.
function M.spawn_capped(workspace_name)
  if not M.is_enabled(workspace_name) then return false end
  return module_state.spawn_visible_only == true
end

-- Tab-visibility layout (slot-aware titles, top-N spawn, warm preheat,
-- Alt+x overflow picker) is the default capability for every named
-- workspace. The previous opt-in `enabled_workspaces` config was
-- removed — this returns true unconditionally for any non-empty
-- workspace name once the module is configured. Kept as a function
-- (rather than inlined) because callers gate on it as a single
-- predicate, and tests / future per-workspace overrides can re-add
-- granularity here without touching the call sites.
function M.is_enabled(workspace_name)
  if not module_state.configured then return false end
  if not workspace_name or workspace_name == '' then return false end
  return true
end

local function path_sep()
  return package.config:sub(1, 1)
end

local function stats_path(workspace_name)
  if not module_state.stats_dir or module_state.stats_dir == '' then
    return nil
  end
  return module_state.stats_dir .. path_sep() .. M.workspace_slug(workspace_name) .. '.json'
end

-- Use posix mtime via lfs if present, else fall back to wezterm.read_dir/glob;
-- for our purposes we just need a "cheap freshness signal" to skip JSON
-- decode when the file hasn't changed. If we can't determine mtime, return
-- 0 (forces every tick to re-decode, which is still throttled by the
-- recompute interval).
local function stats_mtime(path)
  if not path then return 0 end
  local fd = io.open(path, 'rb')
  if not fd then return 0 end
  -- Lua 5.4 doesn't expose stat. Use a length probe — cheap, and any
  -- change in file content will change length given the JSON shape (every
  -- bump appends/replaces last_bump_ms). Combined with the recompute
  -- throttle this is good enough; we are not trying to detect identical
  -- rewrites, only "did the content change since last tick".
  local size = fd:seek('end') or 0
  fd:close()
  return size
end

local function read_stats(workspace_name)
  local path = stats_path(workspace_name)
  if not path then return nil end
  local fd = io.open(path, 'rb')
  if not fd then return nil end
  local content = fd:read('*a')
  fd:close()
  if not content or content == '' then return nil end
  local wezterm = module_state.wezterm
  if not wezterm or not wezterm.serde or not wezterm.serde.json_decode then
    return nil
  end
  local ok, parsed = pcall(wezterm.serde.json_decode, content)
  if not ok or type(parsed) ~= 'table' then return nil end
  return parsed
end

local function rank_sessions(stats)
  local items = {}
  if not stats or type(stats.sessions) ~= 'table' then return items end
  for name, entry in pairs(stats.sessions) do
    if type(entry) == 'table' then
      items[#items + 1] = {
        name = name,
        weight = tonumber(entry.weight) or 0,
        raw_count = tonumber(entry.raw_count) or 0,
      }
    end
  end
  table.sort(items, function(a, b)
    if a.weight ~= b.weight then return a.weight > b.weight end
    if a.raw_count ~= b.raw_count then return a.raw_count > b.raw_count end
    return a.name < b.name
  end)
  return items
end

local function ensure_workspace_cache(workspace_name)
  local cache = module_state.workspaces[workspace_name]
  if cache then return cache end
  cache = {
    last_recompute_ms = 0,
    last_stats_mtime = -1,
    stats = nil,
    ranked = {},
    visible_set = {},  -- set: name -> true
    warm_set = {},
    slots = {},        -- array of { session_name, last_swap_ms } or {}
  }
  for i = 1, module_state.visible_count do
    cache.slots[i] = {}
  end
  module_state.workspaces[workspace_name] = cache
  return cache
end

-- Sticky slot diff. `cache.slots` holds per-slot state across ticks.
-- New entrants displace stale slots in increasing index order.
local function reassign_slots(cache, visible_names, now_ms)
  local present = {}
  for _, name in ipairs(visible_names) do present[name] = true end

  -- Pass 1: figure out which existing slots to keep (still in top-N) and
  -- which are "available" (either empty or holding a session that fell
  -- out). Keep available indices ordered by:
  --   slots that have never been used (last_swap_ms == 0 or nil) first,
  --   then slots whose current session is no longer in top-N — oldest
  --   swap first.
  local available = {}
  local placed = {}
  for i, slot in ipairs(cache.slots) do
    if slot.session_name and present[slot.session_name] then
      placed[slot.session_name] = i
    else
      available[#available + 1] = {
        index = i,
        last_swap_ms = slot.last_swap_ms or 0,
        had_session = slot.session_name ~= nil,
      }
    end
  end
  table.sort(available, function(a, b)
    -- empty slots first (had_session = false sorts before true)
    if a.had_session ~= b.had_session then
      return not a.had_session
    end
    -- among non-empty, oldest swap first
    if a.last_swap_ms ~= b.last_swap_ms then
      return a.last_swap_ms < b.last_swap_ms
    end
    return a.index < b.index
  end)

  -- Pass 2: assign new entrants in visible order to available slots in
  -- the order computed above.
  local avail_cursor = 1
  local swapped_slots = {}
  for _, name in ipairs(visible_names) do
    if not placed[name] then
      local slot = available[avail_cursor]
      avail_cursor = avail_cursor + 1
      if not slot then break end -- visible larger than slot count; ignore tail
      cache.slots[slot.index] = {
        session_name = name,
        last_swap_ms = now_ms,
      }
      swapped_slots[slot.index] = true
    end
  end
  return swapped_slots
end

function M.tick(workspace_name, now_ms)
  if not module_state.configured then return end
  if workspace_name == nil or workspace_name == '' then return end
  local cache = ensure_workspace_cache(workspace_name)
  if (now_ms - (cache.last_recompute_ms or 0)) < module_state.recompute_interval_ms then
    return
  end
  cache.last_recompute_ms = now_ms

  local path = stats_path(workspace_name)
  local size_signal = stats_mtime(path)
  if size_signal == cache.last_stats_mtime and cache.stats ~= nil then
    -- file unchanged since last tick; nothing to recompute
    return
  end
  cache.last_stats_mtime = size_signal

  local stats = read_stats(workspace_name)
  cache.stats = stats
  local ranked = rank_sessions(stats)
  cache.ranked = ranked

  local visible_names = {}
  local warm_names = {}
  for i, entry in ipairs(ranked) do
    if i <= module_state.visible_count then
      visible_names[#visible_names + 1] = entry.name
    elseif i <= (module_state.visible_count + module_state.warm_count) then
      warm_names[#warm_names + 1] = entry.name
    else
      break
    end
  end

  cache.visible_set = {}
  for _, n in ipairs(visible_names) do cache.visible_set[n] = true end
  cache.warm_set = {}
  for _, n in ipairs(warm_names) do cache.warm_set[n] = true end

  local swapped = reassign_slots(cache, visible_names, now_ms)

  if module_state.logger and module_state.logger.info then
    local visible_csv = table.concat(visible_names, ',')
    local warm_csv = table.concat(warm_names, ',')
    local swap_count = 0
    for _ in pairs(swapped) do swap_count = swap_count + 1 end
    if swap_count > 0 then
      module_state.logger.info('tab_visibility', 'slot swap', {
        workspace = workspace_name,
        visible = visible_csv,
        warm = warm_csv,
        swapped_slots = swap_count,
      })
    end
  end
end

-- Slot accessor for titles.lua. Returns:
--   nil                       — visibility module not configured for this ws
--   { session_name = "..."    — slot is filled
--     just_swapped = bool     — true if last_swap_ms within swap_flash_ms
--     swap_age_ms = int }
--   { empty = true }          — slot is configured but empty (cold start)
function M.get_slot_for_tab(workspace_name, tab_index, now_ms)
  if not module_state.configured then return nil end
  if not workspace_name or workspace_name == '' then return nil end
  -- tab_index outside the visible window is NOT a slot at all — return
  -- nil so the title renderer falls back to the tab's normal title.
  -- (An "empty" return value reserved for the cold-start case where
  -- a slot inside the visible window has never been assigned.)
  if not tab_index or tab_index < 1 or tab_index > module_state.visible_count then
    return nil
  end
  local cache = module_state.workspaces[workspace_name]
  if not cache then return nil end
  local slot = cache.slots[tab_index]
  if not slot or slot.session_name == nil then
    return { empty = true }
  end
  local last = slot.last_swap_ms or 0
  local age = now_ms and (now_ms - last) or math.huge
  return {
    session_name = slot.session_name,
    just_swapped = age < module_state.swap_flash_ms,
    swap_age_ms = age,
  }
end

-- Helper to flatten cache.slots into an ordered visible list.
local function visible_order(cache)
  local out = {}
  for i = 1, #cache.slots do
    local s = cache.slots[i]
    if s and s.session_name then
      out[#out + 1] = s.session_name
    end
  end
  return out
end

-- Ordered visible list for spawn / warm callers.
function M.visible_list(workspace_name)
  local cache = module_state.workspaces[workspace_name]
  if not cache then return {} end
  return visible_order(cache)
end

function M.warm_list(workspace_name)
  local cache = module_state.workspaces[workspace_name]
  if not cache then return {} end
  local order = {}
  for name, _ in pairs(cache.warm_set) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    -- preserve the rank: warm_set is unordered, so re-rank here
    local ai, bi = math.huge, math.huge
    for i, entry in ipairs(cache.ranked) do
      if entry.name == a then ai = i end
      if entry.name == b then bi = i end
    end
    return ai < bi
  end)
  return order
end

function M.config()
  return {
    visible_count = module_state.visible_count,
    warm_count = module_state.warm_count,
    half_life_days = module_state.half_life_days,
    recompute_interval_ms = module_state.recompute_interval_ms,
    swap_flash_ms = module_state.swap_flash_ms,
    stats_dir = module_state.stats_dir,
  }
end

-- Test-only: clear cache so unit tests can reset between calls.
function M._reset()
  module_state.workspaces = {}
end

-- ---------------------------------------------------------------------
-- Overflow pane registry. Stored on `_G` rather than module_state so
-- attention.lua (which dofile-loads this module independently and would
-- otherwise see a fresh module_state per dofile) can read the live state
-- without threading the module through attention.register's opts.
--
-- Schema: `_G.__WEZTERM_TAB_OVERFLOW[<workspace_name>] = {
--   pane_id = <wezterm_pane_id_int>,
--   session = <currently_projected_tmux_session_name>,
-- }`
--
-- Writers:
--   - workspace/tabs.lua spawn_overflow_tab populates pane_id + initial
--     browse session (`wezterm_<slug>_overflow`).
--   - titles.lua tab.activate_overflow event handler updates session
--     after each Alt+t pick.
--
-- Readers:
--   - attention.lua is_entry_focused (auto-ack fallback when the user
--     is focused on the overflow pane currently projecting this entry's
--     tmux_session, even though the entry's stored wezterm_pane_id
--     points at a long-killed pane).
--   - attention.lua activate_in_gui (Alt+/ jump fallback by mapping the
--     entry's tmux_session to whichever overflow pane is projecting it).
function M.set_overflow_pane(workspace_name, pane_id, browse_session)
  if not workspace_name or workspace_name == '' or not pane_id then return end
  _G.__WEZTERM_TAB_OVERFLOW = _G.__WEZTERM_TAB_OVERFLOW or {}
  _G.__WEZTERM_TAB_OVERFLOW[workspace_name] = {
    pane_id = pane_id,
    session = browse_session or '',
  }
end

function M.set_overflow_attach(workspace_name, session_name)
  if not workspace_name or workspace_name == '' then return end
  _G.__WEZTERM_TAB_OVERFLOW = _G.__WEZTERM_TAB_OVERFLOW or {}
  local entry = _G.__WEZTERM_TAB_OVERFLOW[workspace_name]
  if not entry then return end
  entry.session = session_name or ''
end

function M.overflow_attach_for_pane(pane_id)
  if pane_id == nil then return nil end
  local map = _G.__WEZTERM_TAB_OVERFLOW or {}
  local key = tostring(pane_id)
  for workspace_name, entry in pairs(map) do
    if entry and entry.pane_id and tostring(entry.pane_id) == key then
      return { workspace = workspace_name, session = entry.session or '' }
    end
  end
  return nil
end

function M.overflow_pane_for_session(session_name)
  if not session_name or session_name == '' then return nil end
  local map = _G.__WEZTERM_TAB_OVERFLOW or {}
  for workspace_name, entry in pairs(map) do
    if entry and entry.session == session_name and entry.pane_id then
      return { workspace = workspace_name, pane_id = entry.pane_id }
    end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- Unified pane→tmux_session map. Single source of truth for "which tmux
-- session does this wezterm pane currently host". Covers BOTH visible
-- managed tabs (each pane attached to its project session) AND the
-- overflow placeholder (rotating attach target).
--
-- Two storage tiers:
--   1. In-memory `_G.__WEZTERM_PANE_TMUX_SESSION[<pane_id>] = <session>`
--      — written by lua handlers (overflow spawn + tab.activate_overflow).
--      Survives across dofile because it lives on _G.
--   2. On-disk `<runtime_state>/state/pane-session/<pane_id>.txt`
--      containing the session name — written by open-project-session.sh
--      after a managed tmux session is created or reused. Visible
--      managed tabs get their entry through this path.
--
-- Reads consult tier 1 first, then tier 2. Writes only target tier 1
-- (the file path is bash-owned at managed-session-creation time).
--
-- Readers:
--   - attention.lua is_entry_focused — match focused pane's session
--     against entry.tmux_session.
--   - attention.lua activate_in_gui — pane_for_session() finds the
--     wezterm pane hosting an entry's session for jump.
--   - attention.lua tab_badge — active_pane → session → matching entry.
function M.set_pane_session(pane_id, session_name)
  if pane_id == nil then return end
  _G.__WEZTERM_PANE_TMUX_SESSION = _G.__WEZTERM_PANE_TMUX_SESSION or {}
  if session_name == nil or session_name == '' then
    _G.__WEZTERM_PANE_TMUX_SESSION[tostring(pane_id)] = nil
  else
    _G.__WEZTERM_PANE_TMUX_SESSION[tostring(pane_id)] = session_name
  end
end

local function pane_session_dir()
  if module_state.stats_dir and module_state.stats_dir ~= '' then
    -- stats_dir = <runtime_state>/state/tab-stats. The pane-session dir
    -- is its sibling under state/.
    return module_state.stats_dir:gsub('[/\\]tab%-stats$', '') .. '/pane-session'
  end
  -- Fallback: derive from LOCALAPPDATA on hybrid-wsl, XDG_STATE_HOME
  -- elsewhere. Mirrors open-project-session.sh's path resolution.
  local lad = os.getenv('LOCALAPPDATA')
  if lad and lad ~= '' then
    return lad .. '\\wezterm-runtime\\state\\pane-session'
  end
  local xdg = os.getenv('XDG_STATE_HOME') or (os.getenv('HOME') .. '/.local/state')
  return xdg .. '/wezterm-runtime/state/pane-session'
end

local function read_pane_session_file(pane_id)
  if pane_id == nil then return nil end
  local dir = pane_session_dir()
  if not dir or dir == '' then return nil end
  local path
  if dir:find('\\', 1, true) then
    path = dir .. '\\' .. tostring(pane_id) .. '.txt'
  else
    path = dir .. '/' .. tostring(pane_id) .. '.txt'
  end
  local fd = io.open(path, 'r')
  if not fd then return nil end
  local line = fd:read('*l')
  fd:close()
  if line == nil then return nil end
  line = line:gsub('^%s+', ''):gsub('%s+$', '')
  if line == '' then return nil end
  return line
end

function M.session_for_pane(pane_id)
  if pane_id == nil then return nil end
  local map = _G.__WEZTERM_PANE_TMUX_SESSION or {}
  local in_memory = map[tostring(pane_id)]
  if in_memory then return in_memory end
  return read_pane_session_file(pane_id)
end

-- Forget both tiers for `pane_id`. Used when the file-tier value is
-- detected stale (workspace prefix mismatches the live pane's
-- workspace), so subsequent session_for_pane calls return nil instead
-- of the stale session — which would otherwise misroute focus-ack and
-- the picker reverse map.
function M.forget_pane_session(pane_id)
  if pane_id == nil then return end
  _G.__WEZTERM_PANE_TMUX_SESSION = _G.__WEZTERM_PANE_TMUX_SESSION or {}
  _G.__WEZTERM_PANE_TMUX_SESSION[tostring(pane_id)] = nil
  local dir = pane_session_dir()
  if not dir or dir == '' then return end
  local path
  if dir:find('\\', 1, true) then
    path = dir .. '\\' .. tostring(pane_id) .. '.txt'
  else
    path = dir .. '/' .. tostring(pane_id) .. '.txt'
  end
  pcall(os.remove, path)
end

function M.pane_for_session(session_name)
  if not session_name or session_name == '' then return nil end
  -- In-memory tier only. The file tier used to walk the on-disk
  -- pane-session/ directory via a Windows shell `dir` spawn — 100-200
  -- ms per call on cross-FS WSL/Windows, and it fired on EVERY jump
  -- for a session whose in-memory edge had not been established yet
  -- (the typical case for a hook-created `running` entry whose
  -- session is not currently projected by any wezterm pane). The
  -- snapshot tick already populates the in-memory map for every
  -- visible managed tab plus the overflow projection, so callers
  -- that hit this miss are jumps to genuinely unhosted sessions —
  -- the right behavior is "no host, fall through fast" rather than
  -- "block 200 ms then return nil anyway".
  local map = _G.__WEZTERM_PANE_TMUX_SESSION or {}
  for pane_id, sess in pairs(map) do
    if sess == session_name then
      return tonumber(pane_id) or pane_id
    end
  end
  return nil
end

return M
