-- event_bus.lua — wezterm-side consumer for the unified event bus.
--
-- Producers (scripts/runtime/wezterm-event-lib.sh, native/picker/wezbus.go)
-- pick between two transports:
--   - OSC 1337 SetUserVar=we_<name>=<base64(payload)>: low latency
--     (wezterm fires user-var-changed sub-frame), but only works from
--     a regular tmux pane whose DCS pass-through reaches wezterm.
--   - File at <state>/wezterm-events/<name>.json: up to one
--     update-status tick (~250 ms) of latency, but works from popup
--     pty / detached / any context.
--
-- This module hides both transports behind a single `event_bus.on`
-- subscription API. Consumers register handlers by event name (e.g.
-- "attention.tick") and never need to know which transport delivered
-- a given event. The transport and a few diagnostics are passed in the
-- handler's `meta` table so logs / tracing can still discriminate.
--
-- Wiring (titles.lua):
--   - call `event_bus.configure { event_dir = constants.wezterm_event_dir }`
--   - register `event_bus.on("attention.tick", handler)` etc.
--   - in `user-var-changed`, call `event_bus.dispatch_user_var(name, value)`
--   - in `update-status`, call `event_bus.poll_files()`
--
-- See docs/event-bus.md for the full design.

local wezterm = require 'wezterm'

local M = {}

-- Registry of name -> { handler, ... }. Multiple handlers per event
-- are supported so different modules can subscribe to the same signal
-- without coordinating.
local handlers = {}
local event_dir = nil
local logger = nil

function M.configure(opts)
  if type(opts) ~= 'table' then return end
  if type(opts.event_dir) == 'string' and opts.event_dir ~= '' then
    event_dir = opts.event_dir
  end
  if opts.logger then
    logger = opts.logger
  end
end

function M.on(name, handler)
  if type(name) ~= 'string' or name == '' or type(handler) ~= 'function' then
    return
  end
  handlers[name] = handlers[name] or {}
  table.insert(handlers[name], handler)
end

local function dispatch(name, payload, meta)
  local list = handlers[name]
  if not list then
    if logger then
      logger.info('event_bus', 'event with no handler', {
        name = name, transport = meta and meta.transport or '?',
      })
    end
    return false
  end
  for _, h in ipairs(list) do
    pcall(h, payload, meta or {})
  end
  return true
end

-- Map an OSC user-var name (we_attention_tick) back to an event name.
-- The producer mangle replaces `.` with `_`, so we can't perfectly
-- recover the original — instead we look up handlers by both forms
-- (with `_` and with `.`), letting consumers register either way.
local function user_var_to_event(var_name)
  if type(var_name) ~= 'string' then return nil end
  if var_name:sub(1, 3) ~= 'we_' then return nil end
  local underscored = var_name:sub(4)
  return underscored, (underscored:gsub('_', '.'))
end

function M.dispatch_user_var(var_name, value, window, pane)
  local underscored, dotted = user_var_to_event(var_name)
  if not underscored then return false end
  local meta = { transport = 'osc', raw_var = var_name, window = window, pane = pane }
  -- Prefer the dotted form so canonical event names (`attention.tick`)
  -- take priority over a hypothetical underscore-only registration.
  if handlers[dotted] then
    return dispatch(dotted, value, meta)
  end
  if handlers[underscored] then
    return dispatch(underscored, value, meta)
  end
  return false
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

-- Tiny envelope parser: matches {"version":N,"name":"...","payload":"...","ts":N}
-- Sufficient for our schema; we don't need a full JSON parser here
-- because the producer writes a fixed shape and the payload itself is
-- a simple string (no nested structure). Returns payload, ts.
local function parse_envelope(content)
  if type(content) ~= 'string' or content == '' then return nil end
  local payload = content:match('"payload"%s*:%s*"([^"]*)"')
  if not payload then return nil end
  -- Reverse the producer's JSON escapes (\\" → ", \\\\ → \\). Order
  -- matters: do \\\\ first so we don't double-unescape.
  payload = payload:gsub('\\\\', '\0'):gsub('\\"', '"'):gsub('\0', '\\')
  local ts = tonumber(content:match('"ts"%s*:%s*(%d+)'))
  return payload, ts
end

local function list_event_files(dir)
  local ok, entries = pcall(wezterm.read_dir, dir)
  if not ok or type(entries) ~= 'table' then return {} end
  local out = {}
  for _, p in ipairs(entries) do
    -- wezterm.read_dir returns full paths.
    if type(p) == 'string' and p:sub(-5) == '.json' and not p:find('%.tmp%.') then
      table.insert(out, p)
    end
  end
  return out
end

-- Drain every pending event-file in the configured directory. Each
-- file is read, atomically removed, and dispatched to its handler.
-- Files whose basename has no registered handler are removed too so
-- a stale schema doesn't accumulate forever. `window` and `pane` are
-- forwarded to handlers via meta so handlers that need to talk to the
-- mux (mux activate, focus tracking, etc.) can do it without
-- re-resolving the active GUI window themselves.
function M.poll_files(window, pane)
  if not event_dir then return end
  local files = list_event_files(event_dir)
  for _, path in ipairs(files) do
    local base = path:match('([^/\\]+)%.json$') or ''
    local content = read_file(path)
    os.remove(path)
    if base ~= '' and handlers[base] then
      local payload, ts = parse_envelope(content)
      if payload then
        dispatch(base, payload, {
          transport = 'file', ts = ts, path = path,
          window = window, pane = pane,
        })
      elseif logger then
        logger.warn('event_bus', 'envelope unparseable',
          { path = path, content_len = content and #content or 0 })
      end
    end
  end
end

return M
