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
-- Live-panes snapshot pacing. update-status fires every
-- `status_update_interval` (250ms by default); the snapshot writer is
-- self-throttled to one rewrite per LIVE_SNAPSHOT_INTERVAL_MS so the
-- map menu.sh reads is at most this many ms stale even if the user
-- never opens the picker. The 5-second freshness gate in
-- tmux-attention-menu.sh stays the consumer-side cap; this constant
-- just determines how often the producer-side refresh fires.
M.LIVE_SNAPSHOT_INTERVAL_MS = 1000
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
local overflow_project_spawner = nil
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
local last_live_snapshot_ms = 0
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

-- Resolve which tmux session a wezterm pane currently hosts, via the
-- unified pane→session map in tab_visibility.lua (in-memory tier covers
-- overflow rotation; file tier covers visible managed tabs written by
-- open-project-session.sh). Single source of truth used by tab_badge,
-- write_live_snapshot, is_entry_focused, and activate_in_gui — so the
-- right-status counter, picker filter, and tab indicators all agree.
--
-- Defined here at the top of the module so every M.* function below can
-- close over them as parse-time locals. Defining them lower required
-- forward-declare bindings to bridge the closures, and missing one such
-- binding silently degraded the caller to its stale-pane fallback path
-- (the "Alt+/ doesn't jump" / "tab badge missing" failure mode).
--
-- The tab_visibility module table is cached for the lifetime of the
-- wezterm process. Earlier we re-`dofile`d on every call; with
-- write_live_snapshot iterating all panes plus per-jump lookups, that
-- meant N+1 cross-FS file reads of tab_visibility.lua per Alt+/ press.
-- Module state is not cached — set_pane_session / session_for_pane both
-- consult `_G.__WEZTERM_PANE_TMUX_SESSION` and the on-disk file tier,
-- which are dynamic, so reusing the module table is safe.
-- Cache the dofile result for the lifetime of the wezterm Lua state.
-- write_live_snapshot calls pane_hosted_session per pane plus several
-- memoize / forget helpers per tick, all routed through this loader;
-- without caching, every snapshot tick re-`dofile`s a /mnt/c-resident
-- file 10-20 times (~3-5 ms each cross-FS), and the cumulative ~50-
-- 100 ms blocks the wezterm UI thread.
--
-- Invalidate on window-config-reloaded so changes land after sync
-- without a full wezterm restart. (An earlier attempt to gate on file
-- mtime regressed perf by always re-dofile-ing when mtime was
-- unavailable — wezterm Lua has no portable stat.)
local cached_tab_visibility = nil
local function load_tab_visibility()
  if cached_tab_visibility ~= nil then return cached_tab_visibility end
  local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or ''
  if runtime_dir == '' then return nil end
  local ok, tab_visibility = pcall(dofile, runtime_dir .. '/lua/ui/tab_visibility.lua')
  if not ok or type(tab_visibility) ~= 'table' then return nil end
  cached_tab_visibility = tab_visibility
  return cached_tab_visibility
end

if wezterm.on then
  pcall(function()
    wezterm.on('window-config-reloaded', function()
      cached_tab_visibility = nil
    end)
  end)
end

local function pane_hosted_session(wezterm_pane_id)
  if wezterm_pane_id == nil or wezterm_pane_id == '' then return nil end
  local tab_visibility = load_tab_visibility()
  if not tab_visibility or type(tab_visibility.session_for_pane) ~= 'function' then
    return nil
  end
  return tab_visibility.session_for_pane(wezterm_pane_id)
end

-- Reverse lookup: which wezterm pane is currently hosting `session_name`?
-- Used by activate_in_gui to find a jump target when the entry's stored
-- wezterm_pane_id is stale.
local function pane_for_hosted_session(session_name)
  if not session_name or session_name == '' then return nil end
  local tab_visibility = load_tab_visibility()
  if not tab_visibility or type(tab_visibility.pane_for_session) ~= 'function' then
    return nil
  end
  return tab_visibility.pane_for_session(session_name)
end

-- Memoize a (pane_id → session) edge into the in-memory tier so
-- subsequent reads — and the reverse lookup pane_for_hosted_session in
-- particular — never have to walk the on-disk pane-session/ directory
-- (which falls back to spawning a Windows shell directory walk, costing
-- 100-200ms per jump on cross-FS WSL/Windows). write_live_snapshot
-- calls this for every pane it touches, so by the time the user
-- presses Alt+/ the in-memory map is already warm.
local function memoize_pane_session(pane_id, session_name)
  if pane_id == nil or session_name == nil or session_name == '' then return end
  local tab_visibility = load_tab_visibility()
  if not tab_visibility or type(tab_visibility.set_pane_session) ~= 'function' then
    return
  end
  pcall(tab_visibility.set_pane_session, pane_id, session_name)
end

-- Drop both tiers of the unified pane→session map for `pane_id`. Used
-- when write_live_snapshot finds the file-tier value is stale (its
-- session-name workspace prefix disagrees with the live pane's
-- workspace). Otherwise the stale value silently misroutes focus-ack
-- onto the wrong entry — the user focuses pane 1 (config), file says
-- pane 1 hosts a work session, focus-ack archives the work entry, and
-- the right-status badge / Alt+/ picker desync.
local function forget_pane_session(pane_id)
  if pane_id == nil then return end
  local tab_visibility = load_tab_visibility()
  if not tab_visibility or type(tab_visibility.forget_pane_session) ~= 'function' then
    return
  end
  pcall(tab_visibility.forget_pane_session, pane_id)
end

-- ── Picker row helpers ────────────────────────────────────────────────
-- The picker (tmux popup) and the right-status badge used to each
-- recompute visibility / labels / ordering from raw attention.json
-- using parallel filter pipelines (Lua for the badge, jq for the
-- picker). They drifted: every change had to be hand-mirrored on both
-- sides, and the mirror missed often enough that "badge says N, picker
-- shows M" became a recurring complaint. The helpers below collapse
-- the decision into one place — `compute_picker_data` returns the
-- exact rows the picker should render plus the counts the badge
-- should display, and `write_live_snapshot` embeds the result in the
-- snapshot so the picker becomes a dumb renderer.
local OVERFLOW_GLYPH = '…'

local function nonempty_str(v)
  return type(v) == 'string' and v ~= ''
end

local function parse_session_workspace(s)
  if type(s) ~= 'string' or s == '' then return nil end
  return s:match('^wezterm_([^_]+)_')
end

local function parse_session_repo(s)
  if type(s) ~= 'string' or s == '' then return nil end
  return s:match('^wezterm_[^_]+_(.+)_[0-9a-f]+$')
end

local function strip_tmux_prefix(v)
  if type(v) ~= 'string' then return '' end
  return (v:gsub('^[@%%]', ''))
end

local function format_age(ms)
  local s = math.floor((ms or 0) / 1000)
  if s < 0 then s = 0 end
  if s < 60 then return s .. 's' end
  local m = math.floor(s / 60)
  if m < 60 then return m .. 'm' end
  return math.floor(s / 3600) .. 'h'
end

local function sanitize(s)
  if type(s) ~= 'string' then return '' end
  return (s:gsub('[\t\n\r]', ' '))
end

-- Trust the live host pane info for label rendering only when its
-- workspace matches the session-name workspace prefix. The reverse-map
-- miss path in production lands the host on whatever pane currently
-- owns the entry's stored wezterm_pane_id — frequently the user own
-- Claude pane in a totally unrelated workspace. Trusting that produces
-- labels like `config/1_wezterm-config/13_21/master` on a coco-server
-- row. Cross-checking workspace lets the parsed-from-session fallback
-- kick in for the right reason.
local function trusted_live(entry, host_info)
  local L = host_info or {}
  local session_ws = parse_session_workspace(entry.tmux_session)
  if L.workspace and session_ws and L.workspace ~= session_ws then
    return {}
  end
  return L
end

-- Build the `ws/tab/tmuxseg/branch` label string. host_info is the
-- panes_map entry for the wezterm pane currently hosting the entry's
-- session, or nil when no such host exists. Falls through to parsed
-- session-name fields for any segment the live info cannot supply.
-- Special-case: the overflow placeholder tab title is the `…` glyph,
-- not a meaningful repo name. When the host is the overflow pane we
-- substitute the projected session's repo for the tab segment so the
-- row reads `work/6_coco-server/...` instead of `work/6_…/...`.
local function compute_label(entry, host_info)
  local L = trusted_live(entry, host_info)
  local session_ws = parse_session_workspace(entry.tmux_session)
  local session_repo = parse_session_repo(entry.tmux_session)
  local ws = nonempty_str(L.workspace) and L.workspace or (session_ws or '?')

  local tab
  if L.tab_index ~= nil then
    if L.tab_title == OVERFLOW_GLYPH then
      tab = tostring(L.tab_index) .. '_' .. (session_repo or '?')
    elseif nonempty_str(L.tab_title) then
      tab = tostring(L.tab_index) .. '_' .. L.tab_title
    else
      tab = tostring(L.tab_index)
    end
  else
    tab = session_repo or '?'
  end

  local tmux_seg
  if nonempty_str(entry.tmux_window) then
    if nonempty_str(entry.tmux_pane) then
      tmux_seg = strip_tmux_prefix(entry.tmux_window) .. '_' .. strip_tmux_prefix(entry.tmux_pane)
    else
      tmux_seg = strip_tmux_prefix(entry.tmux_window)
    end
  else
    tmux_seg = '?'
  end

  local branch = nonempty_str(entry.git_branch) and entry.git_branch or '?'

  if ws == '?' and tab == '?' and tmux_seg == '?' and branch == '?' then
    return nil
  end
  return ws .. '/' .. tab .. '/' .. tmux_seg .. '/' .. branch
end

-- Reachability predicate driven by snapshot-time facts (panes_map +
-- sessions_map). Mirrors entry_has_live_target's logic but uses the
-- pre-built maps rather than re-walking the mux for every entry, which
-- keeps the picker_data computation cheap.
local function entry_reachable(entry, panes_map, sessions_map)
  if not entry then return false end
  local ts = entry.tmux_session
  if nonempty_str(ts) and sessions_map and sessions_map[ts] then
    return true
  end
  -- _G fallback in case sessions_map is empty (cold start before the
  -- first snapshot has populated it).
  local g_map = rawget(_G, '__WEZTERM_PANE_TMUX_SESSION')
  if nonempty_str(ts) and type(g_map) == 'table' then
    for _, sess in pairs(g_map) do
      if sess == ts then return true end
    end
  end
  -- Fallback: stored wezterm_pane_id alive AND in the session
  -- encoded workspace.
  local pane_id = entry.wezterm_pane_id
  if pane_id == nil or pane_id == '' then return false end
  local pane_info = panes_map and panes_map[tostring(pane_id)]
  if not pane_info then return false end
  local session_ws = parse_session_workspace(ts)
  if session_ws and nonempty_str(pane_info.workspace) and pane_info.workspace ~= session_ws then
    return false
  end
  return true
end

-- Visibility predicate shared between picker rows and badge counts.
-- Running entries are always visible (informational counter — the
-- user wants an honest in-flight count regardless of whether the
-- session currently has a known wezterm host). Waiting / done are
-- visible iff reachable.
local function entry_visible(entry, panes_map, sessions_map)
  if not entry then return false end
  if entry.status == M.STATUS_RUNNING then return true end
  return entry_reachable(entry, panes_map, sessions_map)
end

local function status_rank(s)
  if s == M.STATUS_WAITING then return 0
  elseif s == M.STATUS_DONE then return 1
  elseif s == M.STATUS_RUNNING then return 2
  else return 3 end
end

local function effective_host_info(entry, panes_map, sessions_map)
  local effective_pane
  if nonempty_str(entry.tmux_session) and sessions_map then
    effective_pane = sessions_map[entry.tmux_session]
  end
  if not effective_pane and entry.wezterm_pane_id ~= nil then
    effective_pane = entry.wezterm_pane_id
  end
  if effective_pane == nil then return nil end
  return panes_map and panes_map[tostring(effective_pane)]
end

local function build_active_row(entry, label, age_text)
  local body
  if nonempty_str(entry.reason) then
    body = entry.reason
  else
    body = entry.status or ''
  end
  if label and label ~= '' then
    body = label .. '  ' .. body
  end
  return {
    status = entry.status,
    body = sanitize(body),
    age_text = age_text,
    id = entry.session_id or '',
    wezterm_pane_id = entry.wezterm_pane_id ~= nil and tostring(entry.wezterm_pane_id) or '',
    tmux_socket = entry.tmux_socket or '',
    tmux_window = entry.tmux_window or '',
    tmux_pane = entry.tmux_pane or '',
    last_status = entry.status or '',
    tmux_session = entry.tmux_session or '',
  }
end

local function build_recent_row(r, label, age_text)
  local body
  if nonempty_str(r.last_reason) then
    body = r.last_reason
  else
    body = r.last_status or 'recent'
  end
  if label and label ~= '' then
    body = label .. '  ' .. body
  end
  return {
    status = 'recent',
    body = sanitize(body),
    age_text = age_text,
    id = 'recent::' .. (r.session_id or '') .. '::' .. tostring(r.archived_ts or 0),
    wezterm_pane_id = r.wezterm_pane_id ~= nil and tostring(r.wezterm_pane_id) or '',
    tmux_socket = r.tmux_socket or '',
    tmux_window = r.tmux_window or '',
    tmux_pane = r.tmux_pane or '',
    last_status = r.last_status or '',
    tmux_session = r.tmux_session or '',
  }
end

-- Single source of truth for picker rows and badge counts. Returns a
-- table { rows = [...], counts = { waiting, done, running } } where
-- rows is a flat array (active rows ordered waiting → done → running
-- by ts; recent rows appended after, deduped by tmux_session, ordered
-- by archived_ts desc). The picker reads rows directly; the badge
-- reads counts. Both surfaces therefore agree by construction.
function M.compute_picker_data(panes_map, sessions_map)
  panes_map = panes_map or {}
  sessions_map = sessions_map or {}
  local now = now_ms()
  local rows = {}
  local counts = { waiting = 0, done = 0, running = 0 }

  -- ── Active entries ─────────────────────────────────────────────────
  local active_sids = {}
  local actives = {}
  for sid, entry in pairs(state_cache.entries or {}) do
    active_sids[sid] = true
    if entry_is_live(entry, now) and entry_visible(entry, panes_map, sessions_map) then
      table.insert(actives, entry)
    end
  end
  table.sort(actives, function(a, b)
    local ra, rb = status_rank(a.status), status_rank(b.status)
    if ra ~= rb then return ra < rb end
    return (tonumber(a.ts) or 0) < (tonumber(b.ts) or 0)
  end)
  for _, entry in ipairs(actives) do
    if entry.status == M.STATUS_WAITING or entry.status == M.STATUS_RUNNING
       or entry.status == M.STATUS_DONE then
      counts[entry.status] = counts[entry.status] + 1
    end
    local host = effective_host_info(entry, panes_map, sessions_map)
    local label = compute_label(entry, host)
    local age_ms = now - (tonumber(entry.ts) or now)
    local age_text = format_age(age_ms)
    if not nonempty_str(tostring(entry.wezterm_pane_id or '')) then
      age_text = age_text .. ', no pane'
    end
    table.insert(rows, build_active_row(entry, label, age_text))
  end

  -- ── Recent entries ─────────────────────────────────────────────────
  -- Dedupe by tmux_session (or session_id for legacy rows). One
  -- session has at most one current host, so showing every archived
  -- entry just stacks N rows that all jump to the same place.
  local recent_by_key = {}
  for _, r in ipairs(state_cache.recent or {}) do
    if not active_sids[r.session_id or ''] then
      local key = nonempty_str(r.tmux_session) and r.tmux_session or (r.session_id or '')
      if key ~= '' then
        local existing = recent_by_key[key]
        if not existing or (tonumber(r.archived_ts) or 0) > (tonumber(existing.archived_ts) or 0) then
          recent_by_key[key] = r
        end
      end
    end
  end
  local recents = {}
  for _, r in pairs(recent_by_key) do
    -- Recent never has running status, so reachability is the gate.
    if entry_reachable(r, panes_map, sessions_map) then
      table.insert(recents, r)
    end
  end
  table.sort(recents, function(a, b)
    return (tonumber(a.archived_ts) or 0) > (tonumber(b.archived_ts) or 0)
  end)
  for _, r in ipairs(recents) do
    local host = effective_host_info(r, panes_map, sessions_map)
    local label = compute_label(r, host)
    local age_ms = now - (tonumber(r.archived_ts) or now)
    local age_text = format_age(age_ms)
    table.insert(rows, build_recent_row(r, label, age_text))
  end

  return { rows = rows, counts = counts }
end

-- True when an entry has SOME viable jump target right now: either its
-- tmux_session appears in the unified pane→session map (preferred), or
-- its stored wezterm_pane_id is still alive in the live mux (fallback
-- for visible-managed-tab entries whose pane-session file was cleared
-- and never rewritten — open-project-session.sh only writes on session
-- create/attach, so a long-lived persistent session can lose its file
-- mapping and never get it back). Used by M.collect to hide orphan
-- entries whose tmux session is detached and has no wezterm host.
-- Returns true (don't filter) when both signals are unavailable, so a
-- cold-start tick before write_live_snapshot has populated either path
-- never wipes legitimate entries.
local function entry_has_live_target(entry)
  if type(entry) ~= 'table' then return true end
  local tmux_session = entry.tmux_session
  if type(tmux_session) == 'string' and tmux_session ~= '' then
    local map = rawget(_G, '__WEZTERM_PANE_TMUX_SESSION')
    if type(map) == 'table' then
      for _, sess in pairs(map) do
        if sess == tmux_session then return true end
      end
    end
  else
    -- Legacy / non-tmux entries: no session to check, treat as live.
    return true
  end
  -- Fallback: the entry's stored wezterm_pane_id is still alive AND
  -- belongs to the same workspace the session encodes. Walk the mux
  -- just enough to find the candidate; on a hit, cross-check the
  -- workspace prefix (`wezterm_<workspace>_...`). Without the
  -- cross-check an orphan entry whose stored id collides with an
  -- unrelated current pane (e.g. the user's own Claude pane) would
  -- pass — the bug the test_attention_overflow suite catches.
  local pane_id = entry.wezterm_pane_id
  if pane_id == nil or pane_id == '' then return false end
  local target = tostring(pane_id)
  local session_ws = nil
  if type(tmux_session) == 'string' then
    session_ws = tmux_session:match('^wezterm_([^_]+)_')
  end
  local ok_all, all_windows = pcall(wezterm.mux.all_windows)
  if not ok_all or type(all_windows) ~= 'table' then return true end
  for _, mux_win in ipairs(all_windows) do
    local pane_ws
    if mux_win.get_workspace then
      local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
      if ok_ws then pane_ws = ws end
    end
    local ok_tabs, tabs = pcall(function() return mux_win:tabs() end)
    if ok_tabs and type(tabs) == 'table' then
      for _, mux_tab in ipairs(tabs) do
        local ok_panes, panes_with_info = pcall(function() return mux_tab:panes_with_info() end)
        if ok_panes and type(panes_with_info) == 'table' then
          for _, info in ipairs(panes_with_info) do
            local pid_ok, pid = pcall(function() return info.pane:pane_id() end)
            if pid_ok and tostring(pid) == target then
              if session_ws == nil or pane_ws == nil or pane_ws == session_ws then
                return true
              end
              return false
            end
          end
        end
      end
    end
  end
  return false
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

-- Per-tick cache hygiene that is cheap to redo every update-status
-- regardless of whether state.json itself has changed. Split out from
-- reload_state because the state read is now event-driven (only fires
-- on attention.tick), but the tmux-focus file can change without any
-- attention.* event — `tmux-focus-emit.sh` writes it on every pane
-- switch — so its cache must reset on the wezterm tick cadence.
function M.reset_per_tick_cache()
  tmux_focus_cache = {}
end

-- Heavy re-read of state.json + reapplication of optimistic hides.
-- Called from the attention.tick event handler, NOT from update-status,
-- so the 4Hz disk read disappears in steady state. Producers that
-- mutate state.json must publish attention.tick (hooks via OSC,
-- attention-jump.sh writes via the event bus) so this reload fires
-- when the file actually changed.
function M.reload_state()
  M.reset_per_tick_cache()
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
  -- Single source of truth: ask the picker-data builder for the same
  -- visibility decision the snapshot publishes. Build the empty
  -- panes_map / sessions_map fallback walk via mux for collect's
  -- standalone callers (badge update-status path) — write_live_snapshot
  -- passes its own pre-built maps when it embeds picker_data.
  return M.collect_buckets(nil, nil)
end

function M.collect_buckets(panes_map, sessions_map)
  local waiting, running, done = {}, {}, {}
  local now = now_ms()
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now) then
      local visible
      if panes_map or sessions_map then
        visible = entry_visible(entry, panes_map, sessions_map)
      else
        -- Standalone path: no maps available, so use the mux-walking
        -- fallback. Result equals entry_visible-with-maps because
        -- entry_has_live_target is the mux-walking variant of
        -- entry_reachable.
        visible = (entry.status == M.STATUS_RUNNING) or entry_has_live_target(entry)
      end
      if visible then
        if entry.status == M.STATUS_WAITING then table.insert(waiting, entry)
        elseif entry.status == M.STATUS_RUNNING then table.insert(running, entry)
        elseif entry.status == M.STATUS_DONE then table.insert(done, entry)
        end
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
    -- Both `done` AND `waiting` collapse under focus per the user's
    -- updated spec: focusing the pane is the acknowledgement that
    -- the badge was for. `running` stays — informational counter.
    done = drop_focused(done)
    waiting = drop_focused(waiting)
  end
  local idle_bg = palette.tab_bar_background
  local idle_fg = palette.new_tab_fg

  local parts = {}

  -- Order: waiting → done → running. Action items first so the eye lands
  -- on `⚠` when something needs the user; `✓` next as the recently-
  -- finished pile to scan; `⟳` last as ambient "work in flight" context.
  -- Each segment dims to `idle_bg` when zero so the bar width stays stable.
  if #waiting > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_waiting_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_waiting_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Bold' } })
    table.insert(parts, { Text = ' 🚨 ' .. #waiting .. ' waiting ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' 🚨 0 waiting ' })
  end

  -- Fixed one-cell gap so the segment width stays stable between idle and
  -- active states; prevents the right side of the tab bar from jittering.
  table.insert(parts, { Background = { Color = idle_bg } })
  table.insert(parts, { Text = ' ' })

  if #done > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_done_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_done_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ✅ ' .. #done .. ' done ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' ✅ 0 done ' })
  end

  table.insert(parts, { Background = { Color = idle_bg } })
  table.insert(parts, { Text = ' ' })

  if #running > 0 then
    table.insert(parts, { Background = { Color = palette.tab_attention_running_bg } })
    table.insert(parts, { Foreground = { Color = palette.tab_attention_running_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' 🔄 ' .. #running .. ' running ' })
  else
    table.insert(parts, { Background = { Color = idle_bg } })
    table.insert(parts, { Foreground = { Color = idle_fg } })
    table.insert(parts, { Attribute = { Intensity = 'Normal' } })
    table.insert(parts, { Text = ' 🔄 0 running ' })
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
  -- Match entry → tab by tmux session. The pane→session unified map
  -- (tab_visibility.session_for_pane) is the single source of truth:
  -- it covers visible managed tabs (file-backed by open-project-
  -- session.sh) and the rotating overflow pane (in-memory). Comparing
  -- against entry.tmux_session is stable across spawn-cap eviction,
  -- workspace close+reopen and overflow rotation — all of which would
  -- break a wezterm_pane_id strict match.
  --
  -- When the tab is the active one and tmux-pane focus also matches
  -- the entry, suppress both `done` AND `waiting` badges (the user
  -- is looking at the exact pane; both badges would be noise). The
  -- previous policy kept `waiting` visible on the rationale that a
  -- glance is not the same as an answer, but the user updated the
  -- spec to suppress both on focus. `running` stays visible so the
  -- parallel-task view across tabs is truthful.
  local hosted_session = pane_hosted_session(active.pane_id)
  if hosted_session == nil or hosted_session == '' then
    return nil
  end
  local tab_is_active = tab_info.is_active == true
  for _, entry in pairs(state_cache.entries or {}) do
    if entry_is_live(entry, now)
      and type(entry.tmux_session) == 'string'
      and entry.tmux_session == hosted_session then
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
  -- The tab badge intentionally drops the emoji vocabulary used by the
  -- right-status counter and the picker chips: at a tab-strip density the
  -- emoji is informationally redundant (color already encodes status) and
  -- the 2-cell width plus VS16/font-baseline drift made it feel "off".
  -- Render a single `█` block in the status color instead — color does
  -- the work, the glyph is just a 1-cell carrier so the eye has something
  -- to land on. The right-status and picker keep emoji because their
  -- adjacent text labels need the visual anchor.
  if has_waiting then
    return { status = M.STATUS_WAITING, marker = '█' }
  elseif has_running then
    return { status = M.STATUS_RUNNING, marker = '█' }
  elseif has_done then
    return { status = M.STATUS_DONE, marker = '█' }
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

-- Walk the mux and write a snapshot of every live pane's
--   pane_id (string) → { workspace, tab_index, tab_title }
-- to `target_path` as JSON, plus `ts` and `trace` fields. The Alt+/
-- handler calls this right before forwarding `\x1b/` to the tmux pane
-- so the popup-side picker can render workspace/tab labels without
-- paying for a `wezterm.exe cli list` round-trip across the WSL→GUI
-- socket.
--
-- The `trace` field is the WezTerm-side trace id for this Alt+/ press;
-- menu.sh reads it from the snapshot and adopts it as its own trace id
-- so a single chord generates one consistent trace_id across the three
-- layers (lua → bash menu → picker), letting `grep trace_id="..."` on
-- both wezterm.log and runtime.log assemble the full per-press timeline.
-- Returns true on success.
--
function M.write_live_snapshot(target_path, trace_id)
  if type(target_path) ~= 'string' or target_path == '' then
    return false
  end
  if not wezterm.serde or not wezterm.serde.json_encode then
    return false
  end

  local panes_map = {}
  local ok_all, all_windows = pcall(wezterm.mux.all_windows)
  if ok_all and type(all_windows) == 'table' then
    for _, mux_win in ipairs(all_windows) do
      local workspace
      if mux_win.get_workspace then
        local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
        if ok_ws then workspace = ws end
      end
      local ok_tabs, tabs = pcall(function() return mux_win:tabs() end)
      if ok_tabs and type(tabs) == 'table' then
        for tab_idx, mux_tab in ipairs(tabs) do
          local tab_title
          if mux_tab.get_title then
            local ok_title, title = pcall(function() return mux_tab:get_title() end)
            if ok_title then tab_title = title end
          end
          local ok_panes, panes_with_info = pcall(function() return mux_tab:panes_with_info() end)
          if ok_panes and type(panes_with_info) == 'table' then
            for _, info in ipairs(panes_with_info) do
              local pane = info.pane
              local pid_ok, pid = pcall(function() return pane:pane_id() end)
              if pid_ok and pid ~= nil then
                local pane_tab_title = tab_title
                if (not pane_tab_title or pane_tab_title == '') and pane.get_title then
                  local ok_ptitle, ptitle = pcall(function() return pane:get_title() end)
                  if ok_ptitle then pane_tab_title = ptitle end
                end
                panes_map[tostring(pid)] = {
                  workspace = workspace or '',
                  tab_index = tab_idx,
                  tab_title = pane_tab_title or '',
                }
              end
            end
          end
        end
      end
    end
  end

  -- Reverse map for picker labels: tmux_session_name → wezterm_pane_id
  -- of the pane currently hosting it. Populated from the unified
  -- pane→session map (covers visible managed tabs file-backed +
  -- overflow pane in-memory). Lets the picker label a row by the
  -- workspace/tab where the user can SEE the entry right now —
  -- crucial when the work overflow tab projects a config session
  -- (the row is still attached to config session-name, but the user
  -- views it as "work overflow").
  --
  -- Stale-file guard: open-project-session.sh writes
  -- pane-session/<pid>.txt at session-creation time but never cleans
  -- up. When a wezterm pane id is reused (workspace close + reopen
  -- assigns a new tab the previous occupant's id), the file still
  -- names the previous occupant's session. session_for_pane then
  -- returns the wrong session, focus-ack misfires on the user's
  -- focused pane (silently archiving entries the picker then can't
  -- find), and the right-status / picker desync. Cross-check the
  -- file's claimed workspace prefix against the pane's actual
  -- workspace and skip on mismatch. Session naming convention is
  -- `wezterm_<workspace>_<repo>_<10hex>`; a missing or wrong
  -- workspace token means the file is stale.
  -- Overflow registry tier. _G.__WEZTERM_TAB_OVERFLOW[workspace] holds
  -- {pane_id, session} for the workspace's overflow placeholder tab,
  -- updated by spawn_overflow_tab and refreshed by the
  -- tab.activate_overflow event after each Alt+t pick. The pane_id in
  -- the registry can go stale across workspace close+reopen (the new
  -- overflow placeholder gets a fresh pane id but nothing rewrites the
  -- registry until the next Alt+t). Identifying the placeholder by tab
  -- title is more robust: workspace_manager always renders it with the
  -- `…` glyph. Pull session from the registry keyed by workspace name,
  -- not pane_id, so the pane↔session edge is recoverable even when the
  -- registry pane_id is stale.
  local overflow_registry = rawget(_G, '__WEZTERM_TAB_OVERFLOW') or {}
  local OVERFLOW_GLYPH = '…'

  local sessions_map = {}
  for pane_id_str, pane_info in pairs(panes_map) do
    local pane_id_key = tonumber(pane_id_str) or pane_id_str
    local hosted = pane_hosted_session(pane_id_key)
    -- Overflow override: when the unified map has nothing for this
    -- pane and the tab is the overflow placeholder, take the session
    -- from the workspace overflow registry. Covers the common case
    -- where the workspace was reopened after the last Alt+t pick.
    if (not hosted or hosted == '') and pane_info.tab_title == OVERFLOW_GLYPH then
      local pane_workspace = pane_info.workspace or ''
      local entry = pane_workspace ~= '' and overflow_registry[pane_workspace] or nil
      if entry and type(entry.session) == 'string' and entry.session ~= '' then
        hosted = entry.session
        -- Memoize so jump-time reverse lookup hits in-memory and the
        -- registry self-heals (any stale pane_id in the registry is
        -- shadowed by the up-to-date in-memory edge).
        memoize_pane_session(pane_id_key, hosted)
      end
    end
    if hosted and hosted ~= '' then
      local session_workspace = hosted:match('^wezterm_([^_]+)_')
      local pane_workspace = pane_info.workspace or ''
      if session_workspace and pane_workspace ~= '' and session_workspace ~= pane_workspace then
        -- Stale file. Delete it AND clear the in-memory tier so
        -- subsequent session_for_pane calls return nil instead of the
        -- stale session. Without the file delete, the next snapshot
        -- tick would re-read the same stale value and we would
        -- ping-pong forever.
        forget_pane_session(pane_id_key)
        if module_logger then
          module_logger.info('attention',
            'dropped stale pane→session entry',
            { pane_id = pane_id_str,
              file_session = hosted,
              pane_workspace = pane_workspace })
        end
      else
        sessions_map[hosted] = pane_id_str
        -- Also stash the hosted session inside the pane entry so picker
        -- jq can confirm the projection in a single lookup.
        pane_info.tmux_session = hosted
        -- Warm the in-memory tier of the unified pane→session map. We
        -- already paid for the file-tier read above; memoizing here
        -- means the next jump's pane_for_hosted_session reverse lookup
        -- hits in-memory instead of falling through to the on-disk
        -- dir walk.
        memoize_pane_session(pane_id_key, hosted)
      end
    end
  end

  -- Compute picker rows and counts using the same predicate the badge
  -- uses (entry_visible). Embed in the snapshot so the picker reads
  -- precomputed rows directly — no parallel jq filter pipeline that
  -- could drift out of sync with the badge.
  local picker_data = M.compute_picker_data(panes_map, sessions_map)

  -- Publish the wezterm-side focused pane id so the hook
  -- (emit-agent-status.sh) can verify the user is actually looking at
  -- the firing tab before suppressing a waiting/done upsert. Without
  -- this, the hook would skip on the tmux-focus-file signal alone —
  -- that signal stays true while the user is on a different workspace
  -- viewing a different wezterm pane, so coco-server done would get
  -- wrongly suppressed.
  local focused_pane_id = rawget(_G, '__WEZTERM_FOCUSED_PANE_ID')

  local payload = {
    ts = now_ms(),
    trace = (type(trace_id) == 'string') and trace_id or '',
    panes = panes_map,
    sessions = sessions_map,
    picker_rows = picker_data.rows,
    picker_counts = picker_data.counts,
    focused_wezterm_pane_id = focused_pane_id,
  }
  local ok_enc, encoded = pcall(wezterm.serde.json_encode, payload)
  if not ok_enc or type(encoded) ~= 'string' then
    return false
  end

  -- Atomic-ish write: temp + rename. Same dir so rename is in-fs.
  -- POSIX `rename` overwrites the target atomically; Windows `os.rename`
  -- (Lua stdlib) does not — it fails when the destination exists. So on
  -- Windows we explicitly `os.remove` the target before the rename. The
  -- reader (tmux-attention-picker.sh) already tolerates a missing file
  -- via the snapshot-freshness fallback to `?`, so the brief gap during
  -- remove → rename is harmless.
  local tmp_path = target_path .. '.tmp'
  local f = io.open(tmp_path, 'w')
  if not f then return false end
  f:write(encoded)
  f:close()
  if not os.rename(tmp_path, target_path) then
    pcall(os.remove, target_path)
    if not os.rename(tmp_path, target_path) then
      pcall(os.remove, tmp_path)
      return false
    end
  end
  last_live_snapshot_ms = payload.ts
  return true
end

-- Throttled wrapper for write_live_snapshot, invoked every update-status
-- tick from titles.lua. Without this the snapshot only refreshes on
-- explicit Alt+/ presses, so the picker can race the press-time write
-- (Lua write → forward chord → tmux schedule menu.sh; if the read lands
-- before the rename is visible to bash, menu.sh sees a multi-minute-old
-- file, fails the freshness gate, and renders every label as `?/?/`).
-- Refreshing every LIVE_SNAPSHOT_INTERVAL_MS makes the snapshot a
-- continuously-maintained artifact rather than a press-coupled one, so
-- menu.sh almost always sees something fresh regardless of timing.
function M.maybe_refresh_live_snapshot(target_path)
  if type(target_path) ~= 'string' or target_path == '' then
    return
  end
  local now = now_ms()
  if (now - last_live_snapshot_ms) < M.LIVE_SNAPSHOT_INTERVAL_MS then
    return
  end
  M.write_live_snapshot(target_path, '')
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

-- Locate and activate the WezTerm pane that currently hosts the
-- chosen attention entry's tmux session. Performs a workspace switch
-- when the target lives in a different one than the current GUI
-- window, then activates the mux tab/pane.
--
-- Resolution order for the target pane id:
--   1. Reverse lookup: which wezterm pane currently hosts
--      `opts.tmux_session`? Covers the common case where the entry's
--      stored `pane_id_value` is stale (visible cap eviction, workspace
--      reopen) but the same tmux session is now hosted by a fresh
--      visible tab or by the overflow pane after Alt+t rotation.
--   2. Literal `pane_id_value` (the entry's stored
--      wezterm_pane_id) — only when (1) returns nothing AND the id
--      still exists in the live mux. Kept as a fallback for legacy /
--      non-tmux entries that don't carry a tmux_session.
--
-- Returns true on successful activation.
function M.activate_in_gui(pane_id_value, window, source_pane, opts)
  local tmux_session_hint = opts and opts.tmux_session or nil
  local target_id = nil
  if tmux_session_hint and tmux_session_hint ~= '' then
    local found = pane_for_hosted_session(tmux_session_hint)
    if found ~= nil then
      target_id = tostring(found)
    end
  end

  -- No wezterm pane currently hosts the session (typical for a folded
  -- session: it lives in tmux but the workspace overflow tab is
  -- attached to something else right now). Project it into the
  -- overflow tab — same effect as the user picking it via Alt+t —
  -- so the click actually takes them somewhere useful instead of
  -- silently dead-ending on the entry's stale stored pane id. We
  -- compute the overflow placeholder pane id from the live mux to
  -- use as the activation target, AND spawn the bash helper that
  -- runs `tmux switch-client` on the overflow client + emits
  -- tab.activate_overflow so the unified map updates.
  if target_id == nil and tmux_session_hint and tmux_session_hint ~= ''
     and type(overflow_project_spawner) == 'function' then
    local session_workspace = tmux_session_hint:match('^wezterm_([^_]+)_')
    if session_workspace then
      -- Find the overflow placeholder pane in that workspace via the
      -- same heuristic used elsewhere: tab title == OVERFLOW_GLYPH.
      local overflow_pane_id
      local ok_all, all_windows = pcall(wezterm.mux.all_windows)
      if ok_all and type(all_windows) == 'table' then
        for _, mux_win in ipairs(all_windows) do
          local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
          if ok_ws and ws == session_workspace then
            local ok_tabs, tabs_list = pcall(function() return mux_win:tabs() end)
            if ok_tabs and type(tabs_list) == 'table' then
              for _, mux_tab in ipairs(tabs_list) do
                local ok_title, title = pcall(function() return mux_tab:get_title() end)
                if ok_title and title == '…' then
                  local ok_pane, active_pane = pcall(function() return mux_tab:active_pane() end)
                  if ok_pane and active_pane then
                    pcall(function() overflow_pane_id = active_pane:pane_id() end)
                  end
                  break
                end
              end
            end
          end
          if overflow_pane_id then break end
        end
      end
      if overflow_pane_id then
        -- Spawn the project helper. It runs tab-overflow-attach.sh
        -- (tmux switch-client -c <tty> -t <session>) and emits
        -- tab.activate_overflow to refresh the unified map.
        local args = overflow_project_spawner(session_workspace, tmux_session_hint, source_pane)
        if type(args) == 'table' and #args > 0 then
          pcall(wezterm.background_child_process, args)
        end
        -- Memoize the projection in the unified map immediately so
        -- subsequent reads (and this very activation walk) see the
        -- new edge without waiting for the bash side / event tick.
        memoize_pane_session(overflow_pane_id, tmux_session_hint)
        target_id = tostring(overflow_pane_id)
        if module_logger then
          module_logger.info('attention', 'projected entry into overflow', {
            session = tmux_session_hint,
            workspace = session_workspace,
            overflow_pane_id = overflow_pane_id,
          })
        end
      end
    end
  end

  if target_id == nil and pane_id_value ~= nil and pane_id_value ~= '' then
    target_id = tostring(pane_id_value)
  end
  if target_id == nil then
    return false
  end
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

-- Parse the picker's jump-trigger payload (the value field of
-- jump-trigger.json). Payload schema is pipe-delimited so tmux socket
-- paths and `=` characters survive intact:
--   v1|jump|<sid>|<wp>|<sock>|<win>|<pane>
--   v1|recent|<sid>|<archived_ts>|<wp>|<sock>|<win>|<pane>
-- Returns a table { kind = "jump"|"recent", session_id, wezterm_pane,
-- tmux_socket, tmux_window, tmux_pane, tmux_session?, archived_ts? }
-- or nil on bad input. tmux_session is the v1 trailing append (added
-- so activate_in_gui can fall back via the unified pane→session map
-- when wezterm_pane is stale). Older payloads without the trailing
-- field still parse — tmux_session falls through as nil.
function M.parse_jump_payload(value)
  if type(value) ~= 'string' or value == '' then
    return nil
  end
  local parts = {}
  for piece in (value .. '|'):gmatch('([^|]*)|') do
    table.insert(parts, piece)
  end
  if #parts == 0 or parts[1] ~= 'v1' then
    return nil
  end
  local kind = parts[2]
  if kind == 'jump' and #parts >= 7 then
    return {
      kind = 'jump',
      session_id   = parts[3],
      wezterm_pane = parts[4],
      tmux_socket  = parts[5],
      tmux_window  = parts[6],
      tmux_pane    = parts[7],
      tmux_session = parts[8],  -- nil-tolerant: missing → nil
    }
  elseif kind == 'recent' and #parts >= 8 then
    return {
      kind = 'recent',
      session_id   = parts[3],
      archived_ts  = parts[4],
      wezterm_pane = parts[5],
      tmux_socket  = parts[6],
      tmux_window  = parts[7],
      tmux_pane    = parts[8],
      tmux_session = parts[9],
    }
  end
  return nil
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
-- when in doubt rather than hidden. Callers use this in the render
-- path (drop the focused pane's `done` entries from right-status /
-- tab badge — `waiting` is *not* dropped because it is an action item)
-- and in the auto-ack path (schedule --forget for `done` only).
function M.is_entry_focused(entry, wezterm_pane_id)
  if not entry or wezterm_pane_id == nil or wezterm_pane_id == '' then
    return false
  end
  if type(entry.tmux_session) ~= 'string' or entry.tmux_session == '' then
    return false
  end
  -- Sole criterion: the focused wezterm pane is hosting a tmux client
  -- attached to entry.tmux_session. wezterm_pane_id alone is unreliable
  -- because spawn-cap eviction / workspace close+reopen / overflow
  -- rotation all change the pane id without changing the session
  -- identity, and entry.wezterm_pane_id was captured at hook-fire time
  -- by the original spawning pane. Match against entry.tmux_session
  -- via the unified pane→session map so the same path covers visible
  -- managed tabs and the rotating overflow pane.
  local hosted = pane_hosted_session(wezterm_pane_id)
  if hosted ~= entry.tmux_session then
    return false
  end
  -- tmux pane-level guard: a single wezterm pane can host an entire
  -- tmux session whose split panes have independent focus. Require the
  -- tmux client's active pane to also match entry.tmux_pane before
  -- counting as focused. Skipped when the entry has no tmux pane
  -- coordinate (legacy / non-tmux entries).
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

-- Auto-ack: when the currently-focused pane matches a live `done`
-- entry, spawn --forget immediately (no grace window) and hide the
-- entry from the in-memory cache in the same tick so the counter
-- drops without waiting for the subprocess to land the write on disk.
-- `done` is a knowledge signal — sitting on the pane *is* the
-- acknowledgement, so the badge and counter clear without a second
-- gesture. `waiting` is intentionally excluded: it is an action item,
-- and a glance at the pane is not the same as answering the prompt;
-- focus-acking it would silently swallow pending input. `waiting`
-- clears via the actual response path (PreToolUse resolved / Stop /
-- Alt+/). `running` is excluded for the original reason: it is a live
-- indicator of current work, not an action item, and it transitions
-- to waiting or done on its own as the agent progresses.
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
      -- Ack both waiting and done when the entry's pane is focused.
      -- Earlier the policy was "done only" on the rationale that
      -- waiting is an action item and a glance ≠ an answer; the user
      -- updated that spec ("如果 focus 了的 tmux pane 不触发 waiting
      -- 和 done 的加一操作"). Running stays excluded because it is
      -- informational and clears on its own state transition.
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

-- Optimistically hide an entry until its background --forget lands on
-- disk. Used by the Alt+. handler so the badge / picker drop the
-- entry immediately on jump rather than lagging until the
-- subprocess + reload cycle completes (~50-200 ms). Without this,
-- two quick Alt+. presses look like the count goes 2 → 2 → 0
-- instead of 2 → 1 → 0.
function M.optimistically_hide(entry)
  if type(entry) ~= 'table' then return end
  local sid = entry.session_id
  if type(sid) ~= 'string' or sid == '' then return end
  local ts = entry.ts
  hidden_entries[sid] = ts
  if state_cache.entries then
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
  if opts and type(opts.overflow_project_spawner) == 'function' then
    overflow_project_spawner = opts.overflow_project_spawner
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
