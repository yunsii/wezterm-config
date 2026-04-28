-- Failing tests for the focus-ack semantic gaps the user just clarified:
--
--   - waiting entries on the focused pane should be acked too (the
--     current implementation only acks done; comments call this out
--     intentional but the user wants it changed).
--
-- These tests should FAIL against the current code and PASS once the
-- behavior is updated. Drive with scripts/dev/test-lua-units.sh.

package.path = './tests/lua-units/?.lua;./wezterm-x/lua/?.lua;./wezterm-x/lua/ui/?.lua;' .. package.path

local mock = require 'wezterm_mock'
package.preload['wezterm'] = function() return mock end
_G.WEZTERM_RUNTIME_DIR = './wezterm-x'

local attention = require 'attention'
local tab_visibility = require 'tab_visibility'

local fail_count, pass_count = 0, 0
local function describe(n, fn) io.write('▸ ' .. n .. '\n') fn() end
local function it(n, fn)
  local ok, err = pcall(fn)
  if ok then pass_count = pass_count + 1 io.write('  ✓ ' .. n .. '\n')
  else fail_count = fail_count + 1 io.write('  ✗ ' .. n .. '\n    ' .. tostring(err) .. '\n') end
end
local function assert_truthy(v, m) if not v then error(m or 'expected truthy', 2) end end
local function assert_falsy(v, m) if v then error((m or 'expected falsy') .. ': ' .. tostring(v), 2) end end
local function assert_eq(a, b, m)
  if a ~= b then error((m or '') .. ' expected=' .. tostring(b) .. ' actual=' .. tostring(a), 2) end
end

local function reset()
  _G.__WEZTERM_PANE_TMUX_SESSION = {}
  _G.__WEZTERM_TAB_OVERFLOW = {}
  mock.reset_mux()
end

-- Helper: stand up an attention state file + tmux-focus file in a
-- tmpdir, register a recording forget_spawner, then run
-- maybe_ack_focused with a mock pane. Returns the recorded forget
-- calls so tests can assert what got acked.
local function run_focus_ack_with(entries_json, focused_pane_id, focused_socket, focused_session, focused_tmux_pane)
  local tmp = os.tmpname() .. '.d'
  os.execute('mkdir -p ' .. tmp .. '/tmux-focus')
  local state_file = tmp .. '/state.json'
  local fd = io.open(state_file, 'w')
  fd:write(entries_json)
  fd:close()
  -- tmux-focus file path mirrors tmux-focus-emit.sh:
  -- <state_dir>/tmux-focus/<safe_socket>__<safe_session>.txt with
  -- contents = active tmux pane id.
  local safe_socket = focused_socket:gsub('/', '_')
  local safe_session = focused_session:gsub('^%$', '')
  local focus_file = tmp .. '/tmux-focus/' .. safe_socket .. '__' .. safe_session .. '.txt'
  local ff = io.open(focus_file, 'w')
  ff:write(focused_tmux_pane)
  ff:close()

  local recorded = {}
  attention.register {
    state_file = state_file,
    forget_spawner = function(args)
      table.insert(recorded, args)
      return { 'true' }  -- harmless argv; mock background_child_process is no-op
    end,
  }
  attention.reload_state()

  -- Build mock pane with the specified pane_id.
  local pane = { id = focused_pane_id }
  function pane:pane_id() return self.id end

  attention.maybe_ack_focused(nil, pane)

  os.execute('rm -rf ' .. tmp)
  return recorded
end

-- ── tests ──────────────────────────────────────────────────────────────

describe('maybe_ack_focused', function()
  it('acks a waiting entry on the focused pane (NEW: matches user intent)', function()
    reset()
    -- Pane 10 hosts session_a; tmux focus is on pane %5 of session_a.
    tab_visibility.set_pane_session(10, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"w1":{"session_id":"w1","wezterm_pane_id":"10",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%5",'
        .. '"status":"waiting","ts":' .. tostring(now) .. ',"reason":"approve change"}'
      .. '}}'

    local recorded = run_focus_ack_with(entries, 10, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%5')

    assert_eq(#recorded, 1, 'waiting on focused pane was not acked')
    -- Verify the forget targeted the waiting entry by session_id.
    local got_w1 = false
    for _, args in ipairs(recorded) do
      for i, a in ipairs(args) do
        if a == '--forget' and args[i + 1] == 'w1' then got_w1 = true end
      end
    end
    assert_truthy(got_w1, 'forget was called but not for the waiting entry w1')
  end)

  it('still acks done on the focused pane (regression guard)', function()
    reset()
    tab_visibility.set_pane_session(10, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"d1":{"session_id":"d1","wezterm_pane_id":"10",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%5",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"task done"}'
      .. '}}'

    local recorded = run_focus_ack_with(entries, 10, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%5')

    assert_eq(#recorded, 1, 'done on focused pane was not acked (regression)')
  end)

  it('does NOT ack running on the focused pane', function()
    reset()
    tab_visibility.set_pane_session(10, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"r1":{"session_id":"r1","wezterm_pane_id":"10",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%5",'
        .. '"status":"running","ts":' .. tostring(now) .. ',"reason":"in flight"}'
      .. '}}'

    local recorded = run_focus_ack_with(entries, 10, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%5')

    assert_eq(#recorded, 0, 'running was acked (it should not be — running is informational)')
  end)

  it('does NOT ack a waiting entry on a different pane (regression)', function()
    reset()
    -- Pane 10 hosts session_a; entry is on pane 11 (a different pane).
    tab_visibility.set_pane_session(10, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(11, 'wezterm_work_b_bbbbbbbbbb')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"w_other":{"session_id":"w_other","wezterm_pane_id":"11",'
        .. '"tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@3","tmux_pane":"%7",'
        .. '"status":"waiting","ts":' .. tostring(now) .. ',"reason":"please approve"}'
      .. '}}'

    -- Focus is on pane 10 / session_a / %5. tmux-focus file is for
    -- session_a — session_b's focus file does not exist.
    local recorded = run_focus_ack_with(entries, 10, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%5')

    assert_eq(#recorded, 0, 'unfocused waiting was acked (cross-pane bleed)')
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
