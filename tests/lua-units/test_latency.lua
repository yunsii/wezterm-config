-- Verifies latency.lua threshold gating and emit_all / categories rules.
-- Drive with scripts/dev/test-lua-units.sh.

package.path = './tests/lua-units/?.lua;./wezterm-x/lua/?.lua;' .. package.path

local fail_count, pass_count = 0, 0
local function it(n, fn)
  local ok, err = pcall(fn)
  if ok then
    pass_count = pass_count + 1
    io.write('  \xE2\x9C\x93 ' .. n .. '\n')
  else
    fail_count = fail_count + 1
    io.write('  \xE2\x9C\x97 ' .. n .. '\n    ' .. tostring(err) .. '\n')
  end
end
local function assert_eq(a, b, m)
  if a ~= b then error((m or '') .. ' expected=' .. tostring(b) .. ' actual=' .. tostring(a), 2) end
end
local function assert_true(v, m)
  if not v then error(m or 'expected true', 2) end
end
local function assert_false(v, m)
  if v then error(m or 'expected false', 2) end
end

package.loaded['latency'] = nil
local latency = require 'latency'

it('should_log_slow respects threshold inclusive', function()
  assert_false(latency.should_log_slow(49, 50))
  assert_true(latency.should_log_slow(50, 50))
  assert_true(latency.should_log_slow(120, 50))
  assert_false(latency.should_log_slow(nil, 50))
  assert_false(latency.should_log_slow(50, nil))
end)

it('config defaults match documented thresholds', function()
  local cfg = latency.config({})
  assert_eq(cfg.hotkey_slow_ms, 50)
  assert_eq(cfg.status_slow_ms, 40)
  assert_false(cfg.emit_all)
end)

it('config reads overrides and ignores empty categories for emit_all', function()
  local cfg = latency.config {
    diagnostics = {
      wezterm = {
        categories = {},
        latency = {
          hotkey_slow_ms = 30,
          status_slow_ms = 25,
          emit_all = false,
        },
      },
    },
  }
  assert_eq(cfg.hotkey_slow_ms, 30)
  assert_eq(cfg.status_slow_ms, 25)
  assert_false(cfg.emit_all)
end)

it('emit_all true when flag set', function()
  local cfg = latency.config {
    diagnostics = {
      wezterm = {
        latency = { emit_all = true },
      },
    },
  }
  assert_true(cfg.emit_all)
end)

it('emit_all true when allowlist names latency.perf', function()
  local cfg = latency.config {
    diagnostics = {
      wezterm = {
        categories = { latency = true, ['latency.perf'] = true },
        latency = { emit_all = false },
      },
    },
  }
  assert_true(cfg.emit_all)
end)

it('observe skips below threshold and emits slow event above', function()
  local calls = {}
  local logger = {
    info = function(category, message, fields)
      calls[#calls + 1] = { category = category, message = message, fields = fields }
    end,
  }
  local cfg = { hotkey_slow_ms = 50, status_slow_ms = 40, emit_all = false }

  assert_false(latency.observe(logger, cfg, {
    kind = 'hotkey',
    duration_ms = 12,
    fields = { hotkey_id = 'workspace.switch' },
  }))
  assert_eq(#calls, 0, 'no log below threshold')

  assert_true(latency.observe(logger, cfg, {
    kind = 'hotkey',
    duration_ms = 88,
    fields = { hotkey_id = 'workspace.switch' },
  }))
  assert_eq(#calls, 1)
  assert_eq(calls[1].category, 'latency')
  assert_eq(calls[1].message, 'slow key handler')
  assert_eq(calls[1].fields.duration_ms, 88)
  assert_eq(calls[1].fields.hotkey_id, 'workspace.switch')
  assert_eq(calls[1].fields.threshold_ms, 50)
end)

it('observe emits latency.perf when emit_all even if under threshold', function()
  local calls = {}
  local logger = {
    info = function(category, message, fields)
      calls[#calls + 1] = { category = category, message = message, fields = fields }
    end,
  }
  local cfg = { hotkey_slow_ms = 50, status_slow_ms = 40, emit_all = true }
  assert_false(latency.observe(logger, cfg, {
    kind = 'status',
    duration_ms = 5,
  }))
  assert_eq(#calls, 1)
  assert_eq(calls[1].category, 'latency.perf')
  assert_eq(calls[1].message, 'status tick timing')
end)

it('observe slow status uses status message and threshold', function()
  local calls = {}
  local logger = {
    info = function(category, message, fields)
      calls[#calls + 1] = { category = category, message = message, fields = fields }
    end,
  }
  local cfg = { hotkey_slow_ms = 50, status_slow_ms = 40, emit_all = false }
  assert_true(latency.observe(logger, cfg, {
    kind = 'status',
    duration_ms = 41,
  }))
  assert_eq(calls[1].message, 'slow status tick')
  assert_eq(calls[1].fields.threshold_ms, 40)
end)

it('pressure_fields_from_state maps mem/load keys', function()
  local f = latency.pressure_fields_from_state {
    level = 'warn',
    mem_used_pct = 88,
    mem_avail_mib = 2048,
    swap_used_pct = 40,
    loadavg_1 = 14.5,
    loadavg_5 = 11.0,
    loadavg_15 = 6.5,
    proc_runnable = 3,
    proc_total = 3500,
    top_comm = 'tsgo',
    top_rss_mib = 3500,
  }
  assert_eq(f.mem_level, 'warn')
  assert_eq(f.mem_used_pct, 88)
  assert_eq(f.mem_avail_mib, 2048)
  assert_eq(f.swap_used_pct, 40)
  assert_eq(f.loadavg_1, 14.5)
  assert_eq(f.loadavg_5, 11.0)
  assert_eq(f.loadavg_15, 6.5)
  assert_eq(f.proc_runnable, 3)
  assert_eq(f.proc_total, 3500)
  assert_eq(f.top_comm, 'tsgo')
  assert_eq(f.top_rss_mib, 3500)
  local empty = latency.pressure_fields_from_state(nil)
  assert_eq(next(empty), nil)
end)

it('observe slow row attaches pressure from status file', function()
  package.preload['wezterm'] = function() return require 'wezterm_mock' end
  package.loaded['wezterm'] = nil
  package.loaded['latency'] = nil
  local latency2 = require 'latency'
  latency2._reset_pressure_cache_for_test()

  local tmp = os.tmpname()
  local fd = io.open(tmp, 'w')
  fd:write([[{
    "level": "ok",
    "mem_used_pct": 60,
    "mem_avail_mib": 17000,
    "swap_used_pct": 19,
    "loadavg_1": 12.25,
    "loadavg_5": 9.5,
    "loadavg_15": 5.0,
    "proc_runnable": 2,
    "proc_total": 3000
  }]])
  fd:close()

  local calls = {}
  local logger = {
    info = function(category, message, fields)
      calls[#calls + 1] = { category = category, message = message, fields = fields }
    end,
  }
  local cfg = {
    hotkey_slow_ms = 50,
    status_slow_ms = 40,
    emit_all = false,
    pressure_state_file = tmp,
    pressure_cache_ms = 2000,
  }
  assert_true(latency2.observe(logger, cfg, {
    kind = 'status',
    duration_ms = 900,
    now_ms = 100000,
  }))
  assert_eq(calls[1].fields.mem_used_pct, 60)
  assert_eq(calls[1].fields.loadavg_1, 12.25)
  assert_eq(calls[1].fields.proc_total, 3000)
  assert_eq(calls[1].fields.mem_level, 'ok')

  -- Under-threshold emit_all must NOT open the pressure file path as a
  -- required side effect of the fast sample — pressure only on slow rows.
  calls = {}
  cfg.emit_all = true
  assert_false(latency2.observe(logger, cfg, {
    kind = 'status',
    duration_ms = 5,
    now_ms = 100000,
  }))
  assert_eq(calls[1].category, 'latency.perf')
  assert_eq(calls[1].fields.loadavg_1, nil)

  os.remove(tmp)
end)

it('config picks mem_guard.status_file for pressure enrichment', function()
  local cfg = latency.config {
    mem_guard = { status_file = '/tmp/oom-status.json' },
    diagnostics = { wezterm = { latency = {} } },
  }
  assert_eq(cfg.pressure_state_file, '/tmp/oom-status.json')
  assert_true(cfg.pressure_enrich)
end)

io.write(string.format('latency: %d passed, %d failed\n', pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
