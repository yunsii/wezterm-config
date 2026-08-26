-- Key / status-tick latency observability.
--
-- Default posture: quiet. Emit an info row under category `latency` only
-- when a measured duration crosses the configured threshold. Full
-- sampling under `latency.perf` is opt-in via
-- `diagnostics.wezterm.latency.emit_all = true` (or an explicit
-- categories allowlist that includes `latency.perf`).
--
-- Ordinary character typing never enters Lua; status-tick duration is
-- the proxy for "UI thread blocked → keys feel sticky". WezTerm-layer
-- hotkeys are timed at the keymaps.lua wrap around perform_action.
-- See docs/diagnostics.md "Key / status latency".
--
-- Slow rows also attach a cheap guest-pressure snapshot (mem / swap /
-- loadavg) from the oom-guard status.json on the Windows state dir —
-- same file the M· badge reads — so a sticky tick can be correlated
-- with CPU/memory after the fact without paying that cost on the fast
-- path. Reads are cached briefly so a burst of slow ticks shares one
-- open+parse.

local M = {}

-- Lazy wezterm handle: unit tests load this module without a wezterm
-- mock, and pressure enrichment is optional there.
local function wezterm_mod()
  local ok, wt = pcall(require, 'wezterm')
  if ok then
    return wt
  end
  return nil
end

local DEFAULT_HOTKEY_SLOW_MS = 50
local DEFAULT_STATUS_SLOW_MS = 40
-- Share one status.json read across a burst of slow events. The
-- oom-record unit republishes ~every 30 s anyway, so sub-second
-- freshness is not the goal — avoiding N× NTFS opens on a 2 s tick
-- storm is.
local DEFAULT_PRESSURE_CACHE_MS = 2000

local pressure_state_path = nil
local pressure_cache_ms = DEFAULT_PRESSURE_CACHE_MS
local pressure_cache = { at_ms = 0, fields = nil }

local function positive_int(value, fallback)
  local n = tonumber(value)
  if n and n > 0 then
    return math.floor(n)
  end
  return fallback
end

local function now_ms_fallback()
  local wt = wezterm_mod()
  if wt and wt.time and wt.time.now then
    local ok, now_str = pcall(function()
      return wt.time.now():format '%s%3f'
    end)
    if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
      return tonumber(now_str)
    end
  end
  return math.floor(os.time() * 1000)
end

function M.config(constants)
  local diagnostics = constants and constants.diagnostics or {}
  local wezterm_diag = diagnostics.wezterm or {}
  local latency = wezterm_diag.latency or {}
  local categories = wezterm_diag.categories or {}
  local emit_all = latency.emit_all == true
  -- Empty categories means "all base categories" in logger.lua, but we
  -- deliberately do NOT treat that as permission to flood latency.perf
  -- at 4 Hz. Full sampling requires an explicit emit_all flag, or a
  -- non-empty allowlist that names latency.perf.
  if not emit_all and type(categories) == 'table' and next(categories) ~= nil then
    emit_all = categories['latency.perf'] == true
  end

  local mem_guard = constants and constants.mem_guard or {}
  local pressure_file = nil
  if type(latency.pressure_state_file) == 'string' and latency.pressure_state_file ~= '' then
    pressure_file = latency.pressure_state_file
  elseif type(mem_guard.status_file) == 'string' and mem_guard.status_file ~= '' then
    pressure_file = mem_guard.status_file
  end

  return {
    hotkey_slow_ms = positive_int(latency.hotkey_slow_ms, DEFAULT_HOTKEY_SLOW_MS),
    status_slow_ms = positive_int(latency.status_slow_ms, DEFAULT_STATUS_SLOW_MS),
    emit_all = emit_all,
    pressure_state_file = pressure_file,
    pressure_cache_ms = positive_int(latency.pressure_cache_ms, DEFAULT_PRESSURE_CACHE_MS),
    -- Opt-out for tests / constrained hosts without the oom-guard file.
    pressure_enrich = latency.pressure_enrich ~= false,
  }
end

function M.now_ms(wezterm_mod)
  local wt = wezterm_mod or wezterm
  if not wt or not wt.time or not wt.time.now then
    return nil
  end
  local ok, now_str = pcall(function()
    return wt.time.now():format '%s%3f'
  end)
  if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
    return tonumber(now_str)
  end
  return nil
end

local function merge_fields(base, extra)
  local out = {}
  if type(base) == 'table' then
    for k, v in pairs(base) do
      out[k] = v
    end
  end
  if type(extra) == 'table' then
    for k, v in pairs(extra) do
      out[k] = v
    end
  end
  return out
end

-- Collect cheap pane/window context. All accessors are pcall-guarded so
-- a missing method never fails the key path.
function M.context_fields(window, pane)
  local fields = {}
  if window then
    local ok_ws, ws = pcall(function() return window:active_workspace() end)
    if ok_ws and type(ws) == 'string' and ws ~= '' then
      fields.workspace = ws
    end
  end
  if pane then
    local ok_id, pane_id = pcall(function() return pane:pane_id() end)
    if ok_id and pane_id ~= nil then
      fields.pane_id = tostring(pane_id)
    end
    local ok_fg, fg = pcall(function() return pane:get_foreground_process_name() end)
    if ok_fg and type(fg) == 'string' and fg ~= '' then
      fields.foreground = fg
    end
    local ok_dom, dom = pcall(function() return pane:get_domain_name() end)
    if ok_dom and type(dom) == 'string' and dom ~= '' then
      fields.domain = dom
    end
  end
  return fields
end

local function parse_json(text)
  if type(text) ~= 'string' or text == '' then
    return nil
  end
  local wt = wezterm_mod()
  if wt and wt.json_parse then
    local ok, parsed = pcall(wt.json_parse, text)
    if ok then
      return parsed
    end
  end
  if wt and wt.serde and wt.serde.json_decode then
    local ok, parsed = pcall(wt.serde.json_decode, text)
    if ok then
      return parsed
    end
  end
  return nil
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

local function copy_number(dest, src, key, dest_key)
  local n = tonumber(src[key])
  if n ~= nil then
    dest[dest_key or key] = n
  end
end

-- Map oom-guard status.json → latency log fields. Missing / stale file
-- yields {}. Never throws.
function M.pressure_fields_from_state(state)
  local out = {}
  if type(state) ~= 'table' then
    return out
  end
  if type(state.level) == 'string' and state.level ~= '' then
    out.mem_level = state.level
  end
  copy_number(out, state, 'mem_used_pct')
  copy_number(out, state, 'mem_avail_mib')
  copy_number(out, state, 'swap_used_pct')
  copy_number(out, state, 'loadavg_1')
  copy_number(out, state, 'loadavg_5')
  copy_number(out, state, 'loadavg_15')
  copy_number(out, state, 'proc_runnable')
  copy_number(out, state, 'proc_total')
  if type(state.top_comm) == 'string' and state.top_comm ~= '' then
    out.top_comm = state.top_comm
  end
  copy_number(out, state, 'top_rss_mib')
  return out
end

-- Cached read of the guest pressure file. Safe to call from the slow
-- log path; returns {} when the file is missing or unreadable.
function M.read_pressure_fields(cfg, now_ms)
  cfg = cfg or {}
  if cfg.pressure_enrich == false then
    return {}
  end
  local path = cfg.pressure_state_file or pressure_state_path
  if type(path) ~= 'string' or path == '' then
    return {}
  end
  local cache_ms = positive_int(cfg.pressure_cache_ms, pressure_cache_ms)
  local t = tonumber(now_ms) or now_ms_fallback()
  if pressure_cache.fields
     and pressure_cache.path == path
     and (t - (pressure_cache.at_ms or 0)) < cache_ms then
    return pressure_cache.fields
  end
  local content = read_file(path)
  local fields = M.pressure_fields_from_state(parse_json(content))
  pressure_cache = { at_ms = t, path = path, fields = fields }
  return fields
end

-- Test helper: drop the in-module pressure cache between cases.
function M._reset_pressure_cache_for_test()
  pressure_cache = { at_ms = 0, fields = nil, path = nil }
end

-- opts:
--   kind          "hotkey" | "status"
--   duration_ms   number
--   fields        optional extra fields (hotkey_id, …)
--   window/pane   optional, for context_fields
--
-- Returns true when a slow-event (base category) line was emitted.
function M.observe(logger, cfg, opts)
  if not logger or not logger.info then
    return false
  end
  opts = opts or {}
  cfg = cfg or {}
  local duration_ms = tonumber(opts.duration_ms)
  if not duration_ms then
    return false
  end
  duration_ms = math.floor(duration_ms)

  local kind = opts.kind or 'hotkey'
  local threshold = (kind == 'status')
    and (cfg.status_slow_ms or DEFAULT_STATUS_SLOW_MS)
    or (cfg.hotkey_slow_ms or DEFAULT_HOTKEY_SLOW_MS)

  local fields = merge_fields(M.context_fields(opts.window, opts.pane), opts.fields)
  fields.duration_ms = duration_ms
  fields.threshold_ms = threshold
  fields.kind = kind

  if cfg.emit_all then
    local perf_message = (kind == 'status') and 'status tick timing' or 'key handler timing'
    logger.info('latency.perf', perf_message, fields)
  end

  if duration_ms < threshold then
    return false
  end

  -- Only the slow (default-on) row carries pressure — keep the 4 Hz
  -- emit_all path free of status.json I/O.
  fields = merge_fields(fields, M.read_pressure_fields(cfg, opts.now_ms))

  local slow_message = (kind == 'status') and 'slow status tick' or 'slow key handler'
  logger.info('latency', slow_message, fields)
  return true
end

-- Test / call-site helper: threshold gate only (no logger side effects).
function M.should_log_slow(duration_ms, threshold_ms)
  local d = tonumber(duration_ms)
  local t = tonumber(threshold_ms)
  if not d or not t then
    return false
  end
  return d >= t
end

M.DEFAULT_HOTKEY_SLOW_MS = DEFAULT_HOTKEY_SLOW_MS
M.DEFAULT_STATUS_SLOW_MS = DEFAULT_STATUS_SLOW_MS
M.DEFAULT_PRESSURE_CACHE_MS = DEFAULT_PRESSURE_CACHE_MS

return M
