-- Tab-visibility brain. Reads scripts/runtime/tab-stats-lib.sh's per-
-- workspace JSON files on the WezTerm `update-status` tick (throttled to
-- recompute_interval_ms), computes the top-N activity set, and assigns
-- sessions to sticky slots. Producers (titles.lua, workspace_manager.lua,
-- the overflow picker) consume via get_slot_for_tab / visible_set /
-- warm_set.
--
-- Sticky slot algorithm:
--   1. compute visible = top-N sessions by
--      (activity_score + access_bonus desc, recency desc, name asc)
--      access_bonus = access_weight * 2^(-age / half_life) from
--      last_access_ms stamped by the WSL sampler out of the access ledger
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
  -- Visit bonus weight (access ledger). Between index(+40) and HEAD(+100).
  access_weight = 60,
  dwell_credit_cap_ms = 1800000,
  recompute_interval_ms = 5000,
  activity_sample_interval_ms = 60000,
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
  access_weight = DEFAULTS.access_weight,
  dwell_credit_cap_ms = DEFAULTS.dwell_credit_cap_ms,
  recompute_interval_ms = DEFAULTS.recompute_interval_ms,
  activity_sample_interval_ms = DEFAULTS.activity_sample_interval_ms,
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
  module_state.access_weight = tonumber(merged.access_weight) or DEFAULTS.access_weight
  module_state.dwell_credit_cap_ms = merged.dwell_credit_cap_ms
  module_state.recompute_interval_ms = merged.recompute_interval_ms
  module_state.activity_sample_interval_ms = merged.activity_sample_interval_ms
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

-- Cheap content fingerprint used to skip JSON decode when the stats file
-- has not changed. Size alone missed same-length rewrites (for example
-- two sessions swapping dwell values), which made live tab ordering lag
-- until another write changed the byte count.
local function stats_fingerprint(path)
  if not path then return 0 end
  local fd = io.open(path, 'rb')
  if not fd then return 0 end
  local content = fd:read('*a') or ''
  fd:close()
  local hash = 5381
  for i = 1, #content do
    hash = ((hash * 33) + content:byte(i)) % 2147483647
  end
  return tostring(#content) .. ':' .. tostring(hash)
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

-- `scripts/runtime/tmux-reset/session.sh::replacement_session_name` mints
-- `<base>__refresh_<YYYYMMDDTHHMMSS>_<pid>` whenever refresh-current-window
-- needs a fresh tmux session for the same workspace+repo. Each variant
-- gets its own focus-stats row (different session_name keys), so without
-- aggregation a project that the user refreshed three times would show
-- up as four separate ranking entries — fragmenting its own dwell across
-- variants and letting other projects appear higher than they should.
-- We strip the suffix during ranking so all variants aggregate under the
-- base name.
local function normalize_session_name(name)
  if type(name) ~= 'string' or name == '' then return name end
  local base = name:match('^(.+)__refresh_%d+T%d+_%d+$')
  return base or name
end

M._normalize_session_name = normalize_session_name

-- Mirror of `tmux_worktree_sanitize_name` in
-- scripts/runtime/tmux-worktree/core.sh: replace `/`, space, `.`, `:`
-- with `_`. Applied to workspace and repo-label segments before they
-- get joined into a tmux session name. Pure lua so the fallback path
-- below doesn't shell out.
local function sanitize_name_segment(name)
  if type(name) ~= 'string' then return '' end
  return (name:gsub('[/ .:]', '_'))
end

M._sanitize_name_segment = sanitize_name_segment

-- Best-effort inverse of `tmux_worktree_session_name_for_path` in
-- scripts/runtime/tmux-worktree/git.sh: pull the sanitized repo-label
-- segment out of `wezterm_<workspace>_<label>_<10hex>` so we can match
-- a ranked session back to a workspaces.lua item even when the
-- cwd→session map (compute_cwd_to_session's wsl.exe round-trip) is
-- unavailable. Returns the label or nil. The 10-char hex tail anchors
-- the right side; greedy `(.+)` captures everything between the
-- workspace prefix and the hash, so labels containing `_` (or even
-- hex-looking substrings) parse correctly. Hash format follows from
-- `sha1sum | cut -c1-10` in core.sh.
local function session_label_segment(session_name, workspace_name)
  if type(session_name) ~= 'string' or session_name == '' then return nil end
  if type(workspace_name) ~= 'string' or workspace_name == '' then return nil end
  local sanitized_ws = sanitize_name_segment(workspace_name)
  local prefix = 'wezterm_' .. sanitized_ws .. '_'
  local prefix_pat = (prefix:gsub('([%-%.%+%*%?%[%]%^%$%(%)%%])', '%%%1'))
  return session_name:match('^' .. prefix_pat .. '(.+)_(%x%x%x%x%x%x%x%x%x%x)$')
end

M._session_label_segment = session_label_segment

local function has_git_activity(entry)
  return (tonumber(entry.activity_count) or 0) > 0
    or (tonumber(entry.last_activity_ms) or 0) > 0
end

local function has_activity(entry)
  return has_git_activity(entry)
    or (tonumber(entry.last_access_ms) or 0) > 0
end

local function access_bonus(entry, now_ms)
  local last_access = tonumber(entry.last_access_ms) or 0
  if last_access <= 0 then return 0 end
  local weight = tonumber(module_state.access_weight) or DEFAULTS.access_weight
  local half_days = tonumber(module_state.half_life_days) or DEFAULTS.half_life_days
  local half_ms = half_days * 86400000
  if not now_ms or half_ms <= 0 then return weight end
  local age = now_ms - last_access
  if age < 0 then age = 0 end
  return weight * (2 ^ (-age / half_ms))
end

local function ranking_score(entry, now_ms)
  return (tonumber(entry.activity_score) or 0) + access_bonus(entry, now_ms)
end

local function ranking_tier(entry)
  return has_activity(entry) and 1 or 0
end

local function ranking_recent(entry)
  local a = tonumber(entry.last_activity_ms) or 0
  local b = tonumber(entry.last_access_ms) or 0
  local c = tonumber(entry.last_bump_ms) or 0
  if a >= b and a >= c then return a end
  if b >= c then return b end
  return c
end

-- Aggregate stats rows by normalized base name, then rank.
-- Aggregation: activity score summed, access bonus taken from max
-- last_access_ms across variants (not summed — one visit clock),
-- total_dwell_ms summed, event counts summed, recent timestamp max.
-- Rows with git activity and/or access-ledger stamps participate.
-- Legacy focus dwell is diagnostic only.
local function rank_sessions(stats, now_ms)
  if not stats or type(stats.sessions) ~= 'table' then return {} end
  local agg = {}
  for name, entry in pairs(stats.sessions) do
    if type(entry) == 'table' and has_activity(entry) then
      local key = normalize_session_name(name) or name
      local cur = agg[key]
      if not cur then
        cur = {
          name = key,
          rank_tier = 0,
          rank_score = 0,
          activity_score = 0,
          activity_count = 0,
          last_activity_ms = 0,
          last_access_ms = 0,
          dwell_ms = 0,
          total_dwell_ms = 0,
          raw_count = 0,
          last_bump_ms = 0,
          rank_recent_ms = 0,
        }
        agg[key] = cur
      end
      local dwell = tonumber(entry.dwell_ms) or 0
      local tier = ranking_tier(entry)
      cur.dwell_ms = cur.dwell_ms + dwell
      if tier > cur.rank_tier then cur.rank_tier = tier end
      cur.activity_score = cur.activity_score + (tonumber(entry.activity_score) or 0)
      cur.activity_count = cur.activity_count + (tonumber(entry.activity_count) or 0)
      cur.total_dwell_ms = cur.total_dwell_ms + (tonumber(entry.total_dwell_ms) or 0)
      cur.raw_count = cur.raw_count + (tonumber(entry.raw_count) or 0)
      local lbm = tonumber(entry.last_bump_ms) or 0
      if lbm > cur.last_bump_ms then cur.last_bump_ms = lbm end
      local lam = tonumber(entry.last_activity_ms) or 0
      if lam > cur.last_activity_ms then cur.last_activity_ms = lam end
      local lac = tonumber(entry.last_access_ms) or 0
      if lac > cur.last_access_ms then cur.last_access_ms = lac end
      local recent = ranking_recent(entry)
      if recent > cur.rank_recent_ms then cur.rank_recent_ms = recent end
    end
  end
  -- Compute rank_score after aggregation so access_bonus uses the max
  -- last_access_ms once (not once per __refresh_* fragment).
  local items = {}
  for _, v in pairs(agg) do
    v.rank_score = ranking_score(v, now_ms)
    items[#items + 1] = v
  end
  table.sort(items, function(a, b)
    if a.rank_tier ~= b.rank_tier then return a.rank_tier > b.rank_tier end
    if a.rank_score ~= b.rank_score then return a.rank_score > b.rank_score end
    if a.rank_recent_ms ~= b.rank_recent_ms then return a.rank_recent_ms > b.rank_recent_ms end
    local ac = a.activity_count > 0 and a.activity_count or a.raw_count
    local bc = b.activity_count > 0 and b.activity_count or b.raw_count
    if ac ~= bc then return ac > bc end
    return a.name < b.name
  end)
  return items
end

M._rank_sessions = rank_sessions
M._access_bonus = access_bonus

local function slots_path(workspace_name)
  if not module_state.stats_dir or module_state.stats_dir == '' then
    return nil
  end
  -- Co-locate with tab-stats JSON so Lua can read/write without creating
  -- a new directory on the Windows runtime state tree (mkdir is awkward
  -- from wezterm.exe). Filename distinguishes the sticky-slot snapshot
  -- from the activity-score stats file.
  return module_state.stats_dir
    .. path_sep()
    .. M.workspace_slug(workspace_name)
    .. '.slots.json'
end

local function read_persisted_slots(workspace_name)
  local path = slots_path(workspace_name)
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
  if not ok or type(parsed) ~= 'table' or type(parsed.slots) ~= 'table' then
    return nil
  end
  return parsed.slots
end

local function write_persisted_slots(workspace_name, slots)
  local path = slots_path(workspace_name)
  if not path then return end
  local wezterm = module_state.wezterm
  if not wezterm or not wezterm.serde or not wezterm.serde.json_encode then
    return
  end
  local payload = {
    version = 1,
    workspace = workspace_name,
    slots = {},
  }
  for i, slot in ipairs(slots or {}) do
    if slot and slot.session_name and slot.session_name ~= '' then
      payload.slots[i] = {
        session_name = slot.session_name,
        last_swap_ms = tonumber(slot.last_swap_ms) or 0,
      }
    else
      payload.slots[i] = {}
    end
  end
  local ok, encoded = pcall(wezterm.serde.json_encode, payload)
  if not ok or type(encoded) ~= 'string' then return end
  local tmp = path .. '.tmp'
  local fd = io.open(tmp, 'wb')
  if not fd then return end
  fd:write(encoded)
  fd:close()
  -- Atomic replace when possible; fall back to overwrite.
  local renamed = os.rename(tmp, path)
  if not renamed then
    local out = io.open(path, 'wb')
    if out then
      out:write(encoded)
      out:close()
    end
    pcall(os.remove, tmp)
  end
end

local function hydrate_slots_from_disk(cache, workspace_name)
  if cache.slots_hydrated then return end
  cache.slots_hydrated = true
  local persisted = read_persisted_slots(workspace_name)
  if type(persisted) ~= 'table' then return end
  local filled = 0
  for i = 1, module_state.visible_count do
    local entry = persisted[i]
    if type(entry) == 'table' and type(entry.session_name) == 'string'
        and entry.session_name ~= '' then
      cache.slots[i] = {
        session_name = entry.session_name,
        last_swap_ms = tonumber(entry.last_swap_ms) or 0,
      }
      filled = filled + 1
    end
  end
  if filled > 0 and module_state.logger and module_state.logger.info then
    module_state.logger.info('tab_visibility', 'hydrated sticky slots', {
      workspace = workspace_name,
      filled = filled,
    })
  end
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
    slots_hydrated = false,
  }
  for i = 1, module_state.visible_count do
    cache.slots[i] = {}
  end
  hydrate_slots_from_disk(cache, workspace_name)
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
  local size_signal = stats_fingerprint(path)
  if size_signal == cache.last_stats_mtime and cache.stats ~= nil then
    -- file unchanged since last tick; nothing to recompute
    return
  end
  cache.last_stats_mtime = size_signal

  local stats = read_stats(workspace_name)
  cache.stats = stats
  local ranked = rank_sessions(stats, now_ms)
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

  cache.warm_set = {}
  for _, n in ipairs(warm_names) do cache.warm_set[n] = true end

  local swapped = reassign_slots(cache, visible_names, now_ms)

  -- Slots may also contain declared-order fallback sessions seeded by
  -- preferred_item_order. They are real visible tabs even before their
  -- first activity event, so membership consumers must use the slot
  -- projection rather than only the scored subset in visible_names.
  cache.visible_set = {}
  for _, slot in ipairs(cache.slots) do
    if slot and slot.session_name then cache.visible_set[slot.session_name] = true end
  end

  local swap_count = 0
  for _ in pairs(swapped) do swap_count = swap_count + 1 end
  -- Persist whenever membership/order of sticky slots changes so a
  -- WezTerm restart can hydrate the same layout. Also write once after
  -- first hydrate+tick so a never-swapped cold-open still records the
  -- initial assignment.
  if swap_count > 0 or not cache.slots_persisted then
    write_persisted_slots(workspace_name, cache.slots)
    cache.slots_persisted = true
  end

  if module_state.logger and module_state.logger.info then
    local visible_csv = table.concat(visible_names, ',')
    local warm_csv = table.concat(warm_names, ',')
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

-- True iff `session_name` is currently in the workspace's top-N
-- visible set (the membership-only check; ordering is irrelevant).
-- Used by Workspace.maybe_clear_overflow_collision to decide whether
-- the overflow pane is still projecting a session that has since been
-- promoted into a visible tab — that pair would otherwise share a tmux
-- session and mirror the same output. Empty / unknown workspaces
-- return false (the same answer their visible_set would give).
function M.is_in_visible(workspace_name, session_name)
  if not workspace_name or workspace_name == '' then return false end
  if not session_name or session_name == '' then return false end
  local cache = module_state.workspaces[workspace_name]
  if not cache or type(cache.visible_set) ~= 'table' then return false end
  return cache.visible_set[session_name] == true
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
    access_weight = module_state.access_weight,
    dwell_credit_cap_ms = module_state.dwell_credit_cap_ms,
    recompute_interval_ms = module_state.recompute_interval_ms,
    activity_sample_interval_ms = module_state.activity_sample_interval_ms,
    swap_flash_ms = module_state.swap_flash_ms,
    stats_dir = module_state.stats_dir,
  }
end

-- Stable string signature of the workspace's slot assignment, joined
-- across the visible_count slots. Used by titles.lua's update-status
-- callback to detect when the brain's sticky-slot reassignment moved
-- something between ticks: when the signature stays equal there's no
-- live reorder work to do. Returns '' for unknown workspaces (cache
-- not yet populated) so first-tick comparisons trigger naturally.
function M.visible_signature(workspace_name)
  local cache = module_state.workspaces[workspace_name]
  if not cache then return '' end
  local parts = {}
  for i = 1, (module_state.visible_count or DEFAULTS.visible_count) do
    local slot = cache.slots and cache.slots[i]
    parts[i] = (slot and slot.session_name) or ''
  end
  return table.concat(parts, '|')
end

-- Compatibility for callers outside the tracked runtime. Rank changes no
-- longer imply layout changes, so the legacy accessor now exposes slots too.
function M.rank_signature(workspace_name)
  return M.visible_signature(workspace_name)
end

-- Reorder a workspace's `workspaces.lua` items list using the brain's
-- sticky top-N slots, capped at `n`. Activity ranking decides membership,
-- but sessions that remain in top-N keep their existing slot when their
-- relative scores change. Items without stats fill the remaining capacity
-- in declared order. The net result is the slot-order spawn list:
--
--     [sticky-slot items..., declared-order fallback...] truncated at n
--
-- `cwd_to_session` is `{ [cwd] = session_name }` for the workspace
-- (computed by `scripts/runtime/tmux-worktree/print-session-names.sh`
-- once at snapshot/spawn time so we don't fork-per-item). Items whose
-- cwd has no entry in the map are treated as "no session yet" and
-- fall through to the declared-order tail.
--
-- Bootstrap behaviour: when the brain's ranked list is empty (cold
-- start, no activity events yet), the slot pass produces nothing and
-- we end up returning declared-order's first n items — identical to
-- the pre-Phase-2 behaviour.
--
-- Side effect: calls `tick` to force the cache up-to-date even for
-- workspaces that aren't currently focused. `Workspace.open` against a
-- not-yet-focused workspace would otherwise see an empty cache.
function M.preferred_item_order(workspace_name, items, cwd_to_session, n)
  if type(items) ~= 'table' or #items == 0 then return {} end
  n = tonumber(n) or module_state.visible_count or DEFAULTS.visible_count

  -- Workspaces whose full item list fits under the cap have nothing to
  -- drop, so brain-rank reordering only shuffles spawn / display order
  -- without changing the spawn set. Skip the rerank and keep declared
  -- order so workspaces.lua items[1] is always the leftmost tab and
  -- gets the lowest pane id at cold-open. Matters because wezterm pane
  -- ids are sticky for the wezterm process's lifetime, and a brain-
  -- ranked cold-open writes a pane-id layout that diverges from the
  -- author's mental model for the rest of the session (this caused the
  -- "Alt+. on wezterm-config done lands on WSL tab" bug when `config`
  -- workspace's brain happened to rank WSL ahead of wezterm-config).
  if #items <= n then
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = item end
    return out
  end

  -- Force a recompute for this workspace, ignoring the per-workspace
  -- throttle by zeroing last_recompute_ms first. `Workspace.open` is a
  -- low-frequency event (Alt+w / cold open) so a synchronous JSON
  -- decode here is fine.
  if M.is_enabled(workspace_name) then
    local cache = ensure_workspace_cache(workspace_name)
    cache.last_recompute_ms = 0
    local now_ms = 0
    if module_state.wezterm and module_state.wezterm.time and module_state.wezterm.time.now then
      local ok, now_str = pcall(function()
        return module_state.wezterm.time.now():format '%s%3f'
      end)
      if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
        now_ms = tonumber(now_str) or 0
      end
    end
    M.tick(workspace_name, now_ms)
  end

  local cache = module_state.workspaces[workspace_name]
  local slotted = cache and visible_order(cache) or {}

  -- Primary reverse-lookup: session_name → item via the cwd→session
  -- map computed by `compute_cwd_to_session` (workspace_manager.lua).
  local item_for_session = {}
  for _, item in ipairs(items) do
    if item and item.cwd then
      local sess = cwd_to_session and cwd_to_session[item.cwd]
      if sess and sess ~= '' then
        item_for_session[sess] = item
      end
    end
  end

  -- Fallback reverse-lookup: sanitized basename → item. Used when the
  -- cwd→session map is empty or partial — typically because
  -- compute_cwd_to_session's wsl.exe round-trip failed (e.g. WSL
  -- service returning E_UNEXPECTED on an overloaded hybrid-wsl host).
  -- Without this fallback, a transient host-side outage silently
  -- demotes every high-weight item to the declared-order tail and the
  -- user's most-used session falls off the visible cap. The label
  -- pulled from `wezterm_<workspace>_<label>_<10hex>` matches against
  -- `sanitize(basename(item.cwd))`, mirroring the bash session-name
  -- minter so the lookup is exact for the common case (a flat repo
  -- list under workspaces.lua) and best-effort otherwise. First-
  -- declared item wins ties on label collisions, matching declared-
  -- order tiebreak elsewhere.
  local item_for_label = {}
  for _, item in ipairs(items) do
    if item and item.cwd then
      local basename = item.cwd:match('([^/\\]+)$') or item.cwd
      local sanitized = sanitize_name_segment(basename)
      if sanitized ~= '' and item_for_label[sanitized] == nil then
        item_for_label[sanitized] = item
      end
    end
  end

  local function lookup_item(session_name)
    local exact = item_for_session[session_name]
    if exact then return exact end
    local label = session_label_segment(session_name, workspace_name)
    if label then return item_for_label[label] end
    return nil
  end

  local out = {}
  local placed_cwd = {}
  local session_for_cwd = {}

  -- Pass 1: top-N items in sticky slot order. `tick` initializes empty
  -- slots in activity-rank order, then preserves surviving assignments
  -- across later score changes.
  for _, session_name in ipairs(slotted) do
    if #out >= n then break end
    local item = lookup_item(session_name)
    if item and not placed_cwd[item.cwd] then
      out[#out + 1] = item
      placed_cwd[item.cwd] = true
      session_for_cwd[item.cwd] = session_name
    end
  end

  -- Pass 2: declared-order fallback for remaining capacity.
  for _, item in ipairs(items) do
    if #out >= n then break end
    if item and item.cwd and not placed_cwd[item.cwd] then
      out[#out + 1] = item
      placed_cwd[item.cwd] = true
    end
  end

  -- Cold-start and partial-activity layouts fill unused capacity from
  -- declaration order. Seed those actual tabs into empty sticky slots so
  -- their first later activity event keeps the position they already own.
  -- The canonical cwd map is available on cold open; ranked items recovered
  -- through label fallback use session_for_cwd instead.
  if cache and type(cache.slots) == 'table' then
    local slotted_sessions = {}
    for _, slot in ipairs(cache.slots) do
      if slot and slot.session_name then slotted_sessions[slot.session_name] = true end
    end
    for index, item in ipairs(out) do
      local session_name = item and item.cwd
        and ((cwd_to_session and cwd_to_session[item.cwd]) or session_for_cwd[item.cwd])
        or nil
      local slot = cache.slots[index]
      if session_name and session_name ~= '' and not slotted_sessions[session_name]
        and (not slot or not slot.session_name)
      then
        cache.slots[index] = { session_name = session_name, last_swap_ms = 0 }
        slotted_sessions[session_name] = true
      end
    end
    cache.visible_set = {}
    for _, session_name in ipairs(visible_order(cache)) do
      cache.visible_set[session_name] = true
    end
    write_persisted_slots(workspace_name, cache.slots)
    cache.slots_persisted = true
  end

  return out
end

-- Test-only: clear cache so unit tests can reset between calls.
function M._reset()
  module_state.workspaces = {}
end

-- Test helper: expose slots path construction.
function M._slots_path_for_test(workspace_name)
  return slots_path(workspace_name)
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

local function pane_session_file_path(pane_id)
  if pane_id == nil then return nil end
  local dir = pane_session_dir()
  if not dir or dir == '' then return nil end
  if dir:find('\\', 1, true) then
    return dir .. '\\' .. tostring(pane_id) .. '.txt'
  end
  return dir .. '/' .. tostring(pane_id) .. '.txt'
end

local function read_pane_session_file(pane_id)
  local path = pane_session_file_path(pane_id)
  if not path then return nil end
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
  local in_memory = M.memory_session_for_pane(pane_id)
  if in_memory then return in_memory end
  return read_pane_session_file(pane_id)
end

-- In-memory tier only, for callers that must not consult the file tier.
--
-- The overflow placeholder is the one pane that can never legitimately
-- own a `pane-session/<pane_id>.txt`: that file is written by
-- open-project-session.sh for *managed* session panes and is never
-- deleted, while wezterm recycles pane ids across restarts. A fresh
-- placeholder therefore routinely inherits an id whose leftover file
-- names the previous occupant's session — and write_live_snapshot's
-- staleness guard only catches cross-workspace mismatches, so a
-- same-workspace leftover sails through. Observed 2026-08-19: work
-- overflow pane 6 read a 08-03 file naming `coco-forge`, so the single
-- running coco-forge entry painted its badge on both the real
-- coco-forge tab and the `…` tab (tmux itself had the placeholder on
-- the browse session the whole time — the collision was metadata only,
-- which is also why maybe_clear_overflow_collision could not see it).
--
-- The overflow pane's session is only ever known in memory (browse
-- session at spawn, projected session after `tab.activate_overflow`),
-- so a miss here means "unknown", not "look on disk". Trade-off: a
-- config reload wipes `_G` and the placeholder loses the memory of a
-- pre-reload Alt+x projection, so its badge goes quiet until the next
-- pick. Silence beats attributing another tab's agent to it.
function M.memory_session_for_pane(pane_id)
  if pane_id == nil then return nil end
  local map = _G.__WEZTERM_PANE_TMUX_SESSION or {}
  return map[tostring(pane_id)]
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
  M.forget_pane_session_file(pane_id)
end

-- Delete the file tier only, leaving the in-memory tier intact. Used to
-- evict a leftover managed-session file that a recycled pane id
-- inherited (see memory_session_for_pane) without clobbering the live
-- in-memory edge the same pane may legitimately hold. Returns true when
-- a file was actually removed, so the caller can log the eviction once.
function M.forget_pane_session_file(pane_id)
  local path = pane_session_file_path(pane_id)
  if not path then return false end
  local ok, removed = pcall(os.remove, path)
  return ok and removed ~= nil
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
