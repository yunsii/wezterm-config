-- Regression tests for attention.pick_next, especially the multi-tmux-
-- pane single-wezterm-pane topology where two split-pane Claude agents
-- share one wezterm pane id. Without tmux-pane-precise filtering, the
-- sibling tmux pane's done/waiting/running was unreachable via
-- Alt+k / Alt+j / Alt+l.
--
-- Drive with scripts/dev/test-lua-units.sh.

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
local function assert_eq(a, b, m)
  if a ~= b then error((m or '') .. ' expected=' .. tostring(b) .. ' actual=' .. tostring(a), 2) end
end
local function assert_truthy(v, m) if not v then error(m or 'expected truthy', 2) end end
local function assert_nil(v, m) if v ~= nil then error((m or 'expected nil') .. ' actual=' .. tostring(v), 2) end end

local function reset()
  _G.__WEZTERM_PANE_TMUX_SESSION = {}
  _G.__WEZTERM_TAB_OVERFLOW = {}
  mock.reset_mux()
end

-- Build a state.json + tmux-focus file in a tmpdir, register attention
-- with that state path, reload, and return the tmpdir so the test can
-- clean up. focused_tmux_pane is the active tmux pane recorded in the
-- focus file (what after-select-pane / client-focus-in would have
-- written). When focus_session_extras is provided, additional tmux-focus
-- files are written for sibling sessions so multi-session topologies can
-- be exercised.
local function setup_state(state_json, focus_socket, focus_session, focus_tmux_pane, focus_session_extras)
  local tmp = os.tmpname() .. '.d'
  os.execute('mkdir -p ' .. tmp .. '/tmux-focus')
  local state_file = tmp .. '/state.json'
  local fd = io.open(state_file, 'w')
  fd:write(state_json)
  fd:close()
  if focus_socket and focus_session and focus_tmux_pane then
    local safe_socket = focus_socket:gsub('/', '_')
    local safe_session = focus_session:gsub('^%$', '')
    local focus_file = tmp .. '/tmux-focus/' .. safe_socket .. '__' .. safe_session .. '.txt'
    local ff = io.open(focus_file, 'w')
    ff:write(focus_tmux_pane)
    ff:close()
  end
  for _, extra in ipairs(focus_session_extras or {}) do
    local safe_socket = extra.socket:gsub('/', '_')
    local safe_session = extra.session:gsub('^%$', '')
    local focus_file = tmp .. '/tmux-focus/' .. safe_socket .. '__' .. safe_session .. '.txt'
    local ff = io.open(focus_file, 'w')
    ff:write(extra.tmux_pane)
    ff:close()
  end
  attention.register {
    state_file = state_file,
    forget_spawner = function() return { 'true' } end,
  }
  attention.reload_state()
  return tmp
end

local function cleanup(tmp) os.execute('rm -rf ' .. tmp) end

-- Mux topology helper: one wezterm window/workspace with one tab whose
-- single pane has id `pane_id`. Used so entry_has_live_target's mux
-- walk treats entries pointing at `pane_id` as reachable (the `done`
-- buckets are filtered by reachability, not just liveness).
local function set_single_pane_topology(pane_id, workspace)
  mock.set_mux {
    windows = {
      {
        workspace = workspace or 'work',
        tabs = { { id = 1, title = 'a', active_pane = { id = pane_id } } },
      },
    },
  }
end

-- ── tests ──────────────────────────────────────────────────────────────

describe('pick_next — multi-tmux-pane single-wezterm-pane', function()
  it('returns the sibling tmux pane done when user is on the other split', function()
    reset()
    -- Wezterm pane 42 hosts tmux session "wezterm_work_a_aaaaaaaaaa"
    -- which has two split panes %1 (user) and %2 (other agent).
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"d_other":{"session_id":"d_other","wezterm_pane_id":"42",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%2",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"task done"}'
      .. '}}'
    -- User's tmux focus is on %1 (the sibling pane), so entry on %2 is
    -- a valid jump target even though both share wezterm pane 42.
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_truthy(picked, 'sibling tmux-pane done was filtered out')
    assert_eq(picked.session_id, 'd_other', 'wrong entry returned')
  end)

  it('returns the sibling tmux pane waiting too (Alt+j parity)', function()
    reset()
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"w_other":{"session_id":"w_other","wezterm_pane_id":"42",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%2",'
        .. '"status":"waiting","ts":' .. tostring(now) .. ',"reason":"approve change"}'
      .. '}}'
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_WAITING, 42)
    cleanup(tmp)
    assert_truthy(picked, 'sibling tmux-pane waiting was filtered out')
    assert_eq(picked.session_id, 'w_other', 'wrong entry returned')
  end)

  it('returns nil when the only done is the user\'s exact tmux pane', function()
    reset()
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"d_self":{"session_id":"d_self","wezterm_pane_id":"42",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%1",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"task done"}'
      .. '}}'
    -- User is on %1 and the only done is also on %1 — nothing to jump to.
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_nil(picked, 'pick_next jumped to self (user\'s exact tmux pane)')
  end)

  it('cycles to the second sibling when the first one is the user\'s pane', function()
    reset()
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    -- Entry on %1 (user's pane) sorts older than entry on %2; pick_next
    -- must skip %1 and land on %2.
    local entries = '{"version":1,"entries":{'
      .. '"d_self":{"session_id":"d_self","wezterm_pane_id":"42",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%1",'
        .. '"status":"done","ts":' .. tostring(now - 10000) .. ',"reason":"old"},'
      .. '"d_other":{"session_id":"d_other","wezterm_pane_id":"42",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%2",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"new"}'
      .. '}}'
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_truthy(picked, 'pick_next returned nil with a valid sibling target')
    assert_eq(picked.session_id, 'd_other', 'pick_next did not skip the user\'s own pane')
  end)
end)

describe('pick_next — cross-wezterm-pane topology (regression guard)', function()
  it('returns the entry on a different wezterm pane', function()
    reset()
    -- Two wezterm panes, two tmux sessions (one per pane).
    mock.set_mux {
      windows = {
        {
          workspace = 'work',
          tabs = {
            { id = 1, title = 'a', active_pane = { id = 42 } },
            { id = 2, title = 'b', active_pane = { id = 43 } },
          },
        },
      },
    }
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(43, 'wezterm_work_b_bbbbbbbbbb')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"d_other":{"session_id":"d_other","wezterm_pane_id":"43",'
        .. '"tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@3","tmux_pane":"%7",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"done b"}'
      .. '}}'
    -- User on pane 42 / session_a / %1; entry on pane 43 / session_b.
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_b_bbbbbbbbbb', tmux_pane = '%7' },
    })
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_truthy(picked, 'cross-wezterm-pane done was filtered out')
    assert_eq(picked.session_id, 'd_other', 'wrong entry returned')
  end)
end)

describe('pick_next — round-robin (3+ pool)', function()
  it('walks all three running entries instead of ping-ponging the two oldest', function()
    reset()
    -- Three wezterm panes / three tmux sessions, all running.
    mock.set_mux {
      windows = {
        {
          workspace = 'work',
          tabs = {
            { id = 1, title = 'a', active_pane = { id = 41 } },
            { id = 2, title = 'b', active_pane = { id = 42 } },
            { id = 3, title = 'c', active_pane = { id = 43 } },
          },
        },
      },
    }
    tab_visibility.set_pane_session(41, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(42, 'wezterm_work_b_bbbbbbbbbb')
    tab_visibility.set_pane_session(43, 'wezterm_work_c_cccccccccc')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"r_old":{"session_id":"r_old","wezterm_pane_id":"41",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 3000) .. ',"reason":"old"},'
      .. '"r_mid":{"session_id":"r_mid","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 2000) .. ',"reason":"mid"},'
      .. '"r_new":{"session_id":"r_new","wezterm_pane_id":"43",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_c_cccccccccc",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 1000) .. ',"reason":"new"}'
      .. '}}'
    -- Start focused on the oldest (pane 41 / %1 of session a).
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_b_bbbbbbbbbb', tmux_pane = '%1' },
      { socket = '/tmp/sock', session = 'wezterm_work_c_cccccccccc', tmux_pane = '%1' },
    })
    local first = attention.pick_next(attention.STATUS_RUNNING, 41)
    assert_truthy(first, 'first hop nil')
    assert_eq(first.session_id, 'r_mid', 'from oldest should advance to mid')

    -- Simulate landing on mid: refresh focus file for session b.
    cleanup(tmp)
    tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_b_bbbbbbbbbb', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_a_aaaaaaaaaa', tmux_pane = '%1' },
      { socket = '/tmp/sock', session = 'wezterm_work_c_cccccccccc', tmux_pane = '%1' },
    })
    local second = attention.pick_next(attention.STATUS_RUNNING, 42)
    assert_truthy(second, 'second hop nil')
    assert_eq(second.session_id, 'r_new', 'from mid must reach newest (not bounce to oldest)')

    cleanup(tmp)
    tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_c_cccccccccc', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_a_aaaaaaaaaa', tmux_pane = '%1' },
      { socket = '/tmp/sock', session = 'wezterm_work_b_bbbbbbbbbb', tmux_pane = '%1' },
    })
    local third = attention.pick_next(attention.STATUS_RUNNING, 43)
    cleanup(tmp)
    assert_truthy(third, 'wrap hop nil')
    assert_eq(third.session_id, 'r_old', 'from newest should wrap to oldest')
  end)

  it('reverse walks newest-ward (Alt+Shift+l)', function()
    reset()
    mock.set_mux {
      windows = {
        {
          workspace = 'work',
          tabs = {
            { id = 1, title = 'a', active_pane = { id = 41 } },
            { id = 2, title = 'b', active_pane = { id = 42 } },
            { id = 3, title = 'c', active_pane = { id = 43 } },
          },
        },
      },
    }
    tab_visibility.set_pane_session(41, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(42, 'wezterm_work_b_bbbbbbbbbb')
    tab_visibility.set_pane_session(43, 'wezterm_work_c_cccccccccc')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"r_old":{"session_id":"r_old","wezterm_pane_id":"41",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 3000) .. ',"reason":"old"},'
      .. '"r_mid":{"session_id":"r_mid","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 2000) .. ',"reason":"mid"},'
      .. '"r_new":{"session_id":"r_new","wezterm_pane_id":"43",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_c_cccccccccc",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 1000) .. ',"reason":"new"}'
      .. '}}'
    -- Focused on mid; reverse should go to oldest (previous in sorted order).
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_b_bbbbbbbbbb', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_a_aaaaaaaaaa', tmux_pane = '%1' },
      { socket = '/tmp/sock', session = 'wezterm_work_c_cccccccccc', tmux_pane = '%1' },
    })
    local prev = attention.pick_next(attention.STATUS_RUNNING, 42, { reverse = true })
    assert_truthy(prev, 'reverse hop nil')
    assert_eq(prev.session_id, 'r_old', 'from mid reverse should land on oldest')

    cleanup(tmp)
    -- Focused on oldest; reverse wraps to newest.
    tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_b_bbbbbbbbbb', tmux_pane = '%1' },
      { socket = '/tmp/sock', session = 'wezterm_work_c_cccccccccc', tmux_pane = '%1' },
    })
    local wrap = attention.pick_next(attention.STATUS_RUNNING, 41, { reverse = true })
    cleanup(tmp)
    assert_truthy(wrap, 'reverse wrap nil')
    assert_eq(wrap.session_id, 'r_new', 'from oldest reverse should wrap to newest')
  end)
end)

describe('pick_next — running pool (Alt+l)', function()
  it('returns a sibling running entry and ignores waiting/done', function()
    reset()
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"w1":{"session_id":"w1","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%2","status":"waiting","ts":'
        .. tostring(now - 3000) .. ',"reason":"perm"},'
      .. '"r1":{"session_id":"r1","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%2","status":"running","ts":'
        .. tostring(now - 2000) .. ',"reason":"mid-turn"},'
      .. '"d1":{"session_id":"d1","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%2","status":"done","ts":'
        .. tostring(now - 1000) .. ',"reason":"stop"}'
      .. '}}'
    -- User focused on %1; sibling %2 has waiting+running+done — pick_next
    -- for running must return only r1.
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_RUNNING, 42)
    cleanup(tmp)
    assert_truthy(picked, 'running sibling was not returned')
    assert_eq(picked.session_id, 'r1', 'pick_next(running) returned a non-running entry')
  end)

  it('returns nil when the only running entry is the focused pane', function()
    reset()
    set_single_pane_topology(42, 'work')
    tab_visibility.set_pane_session(42, 'wezterm_work_a_aaaaaaaaaa')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"r_self":{"session_id":"r_self","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now) .. ',"reason":"self"}'
      .. '}}'
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1')
    local picked = attention.pick_next(attention.STATUS_RUNNING, 42)
    cleanup(tmp)
    assert_nil(picked, 'pick_next(running) jumped to self')
  end)

  it('advances via note_jump when tmux-focus still names the previous pane', function()
    -- Repro for "Alt+l feels dead": after landing on mid, the focus file
    -- has not caught up (still names oldest). Without note_jump the next
    -- press re-picks oldest → activate is a no-op on the already-focused
    -- wezterm pane.
    reset()
    mock.set_mux {
      windows = {
        {
          workspace = 'work',
          tabs = {
            { id = 1, title = 'a', active_pane = { id = 41 } },
            { id = 2, title = 'b', active_pane = { id = 42 } },
            { id = 3, title = 'c', active_pane = { id = 43 } },
          },
        },
      },
    }
    tab_visibility.set_pane_session(41, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(42, 'wezterm_work_b_bbbbbbbbbb')
    tab_visibility.set_pane_session(43, 'wezterm_work_c_cccccccccc')
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"r_old":{"session_id":"r_old","wezterm_pane_id":"41",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 3000) .. ',"reason":"old"},'
      .. '"r_mid":{"session_id":"r_mid","wezterm_pane_id":"42",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 2000) .. ',"reason":"mid"},'
      .. '"r_new":{"session_id":"r_new","wezterm_pane_id":"43",'
        .. '"tmux_socket":"/tmp/sock","tmux_session":"wezterm_work_c_cccccccccc",'
        .. '"tmux_window":"@1","tmux_pane":"%1","status":"running","ts":'
        .. tostring(now - 1000) .. ',"reason":"new"}'
      .. '}}'
    -- Focus file still on oldest, but wezterm focus already on mid (42)
    -- after a prior jump — is_entry_focused misses because session b's
    -- focus file is absent / wrong. note_jump(mid) must still advance.
    local tmp = setup_state(entries, '/tmp/sock', 'wezterm_work_a_aaaaaaaaaa', '%1', {
      { socket = '/tmp/sock', session = 'wezterm_work_c_cccccccccc', tmux_pane = '%1' },
    })
    attention.note_jump(attention.STATUS_RUNNING, {
      session_id = 'r_mid',
      tmux_window = '@1',
      tmux_pane = '%1',
    })
    local picked = attention.pick_next(attention.STATUS_RUNNING, 42)
    cleanup(tmp)
    assert_truthy(picked, 'note_jump cursor did not advance')
    assert_eq(picked.session_id, 'r_new', 'expected newest after note_jump(mid); got ' .. tostring(picked and picked.session_id))
  end)
end)

describe('pick_next — non-tmux fallback', function()
  it('skips an entry whose wezterm_pane_id matches when no tmux_session', function()
    reset()
    set_single_pane_topology(42, 'work')
    -- No tab_visibility.set_pane_session — entry has no tmux_session.
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"legacy":{"session_id":"legacy","wezterm_pane_id":"42",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"legacy"}'
      .. '}}'
    local tmp = setup_state(entries)
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_nil(picked, 'legacy entry on user\'s wezterm pane was not skipped')
  end)

  it('returns a legacy entry on a different wezterm pane', function()
    reset()
    mock.set_mux {
      windows = {
        {
          workspace = 'work',
          tabs = {
            { id = 1, title = 'a', active_pane = { id = 42 } },
            { id = 2, title = 'b', active_pane = { id = 43 } },
          },
        },
      },
    }
    local now = os.time() * 1000
    local entries = '{"version":1,"entries":{'
      .. '"legacy":{"session_id":"legacy","wezterm_pane_id":"43",'
        .. '"status":"done","ts":' .. tostring(now) .. ',"reason":"legacy"}'
      .. '}}'
    local tmp = setup_state(entries)
    local picked = attention.pick_next(attention.STATUS_DONE, 42)
    cleanup(tmp)
    assert_truthy(picked, 'legacy entry on another wezterm pane was filtered out')
    assert_eq(picked.session_id, 'legacy', 'wrong entry returned')
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
