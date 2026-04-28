-- Real test for the bugs we have been chasing manually:
--
--   1. write_live_snapshot must publish a (session → wezterm_pane_id)
--      reverse map for every visible pane that hosts a managed session,
--      so the picker's jq filter / labels resolve correctly.
--   2. The overflow placeholder pane must show up in that reverse map
--      even when _G.__WEZTERM_TAB_OVERFLOW was not pre-seeded by
--      spawn_overflow_tab — production hits this whenever the wezterm
--      config reloads while the placeholder tab survives in mux.
--   3. activate_in_gui must use the session reverse lookup so a stale
--      stored wezterm_pane_id does not make the jump land on a
--      completely unrelated current pane.
--   4. Stale pane-session/<pid>.txt entries (workspace mismatch) get
--      dropped, so focus-ack and the picker do not misfire.
--
-- Driven by lua5.4 directly. Mocks wezterm via wezterm_mock.lua and
-- wires it into package.preload before requiring the modules under
-- test. No wezterm process needed.

package.path = './tests/lua-units/?.lua;./wezterm-x/lua/?.lua;./wezterm-x/lua/ui/?.lua;' .. package.path

local mock = require 'wezterm_mock'
package.preload['wezterm'] = function() return mock end

-- The modules under test reference WEZTERM_RUNTIME_DIR via rawget(_G, ...)
-- to dofile sibling files. Point it at the repo so dofile resolves.
_G.WEZTERM_RUNTIME_DIR = './wezterm-x'

local attention = require 'attention'
local tab_visibility = require 'tab_visibility'

-- ── tiny test harness ─────────────────────────────────────────────────
local fail_count = 0
local pass_count = 0
local function describe(name, fn)
  io.write('▸ ' .. name .. '\n')
  fn()
end
local function it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    pass_count = pass_count + 1
    io.write('  ✓ ' .. name .. '\n')
  else
    fail_count = fail_count + 1
    io.write('  ✗ ' .. name .. '\n    ' .. tostring(err) .. '\n')
  end
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or '') .. ' expected=' .. tostring(expected) ..
          ' actual=' .. tostring(actual), 2)
  end
end
local function assert_truthy(v, msg) if not v then error(msg or 'expected truthy', 2) end end
local function assert_falsy(v, msg) if v then error((msg or 'expected falsy') .. ': ' .. tostring(v), 2) end end

local function reset_global_state()
  _G.__WEZTERM_PANE_TMUX_SESSION = {}
  _G.__WEZTERM_TAB_OVERFLOW = {}
  -- Force attention.lua to re-resolve tab_visibility on first call.
  -- The cached_tab_visibility upvalue in attention.lua is internal;
  -- since each test reloads from the same in-process require, we just
  -- accept that the cache survives — it's a fresh tab_visibility table
  -- across tests anyway because tab_visibility holds no module-local
  -- mutable state, only _G.__WEZTERM_PANE_TMUX_SESSION etc.
end

local function tmpfile()
  local p = os.tmpname()
  -- os.tmpname returns a path like /tmp/lua_XXXXXX without auto-create.
  return p
end

-- ── tests ──────────────────────────────────────────────────────────────

describe('write_live_snapshot publishes session reverse map', function()
  it('records every visible managed-tab session', function()
    reset_global_state()
    -- Three visible managed tabs, each hosting a different session.
    -- We seed in-memory tier directly (the production write happens
    -- via tab_visibility.set_pane_session from spawn paths and the
    -- on-disk pane-session/<pid>.txt files).
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')
    tab_visibility.set_pane_session(11, 'wezterm_work_coco-platform_bbbbbbbbbb')
    tab_visibility.set_pane_session(12, 'wezterm_work_packages_cccccccccc')

    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 101, title = 'coco-platform',       active_pane = { id = 11 } },
          { id = 102, title = 'packages',            active_pane = { id = 12 } },
        }},
      },
    })

    local out = tmpfile()
    local ok = attention.write_live_snapshot(out, 'test-trace')
    assert_truthy(ok, 'write_live_snapshot returned non-truthy')

    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)

    -- Expect the encoded JSON to contain each session as a sessions key.
    assert_truthy(body:find('"sessions":', 1, true), 'no sessions block')
    assert_truthy(body:find('wezterm_work_ai-video-collection_aaaaaaaaaa', 1, true), 'missing ai-video session')
    assert_truthy(body:find('wezterm_work_coco-platform_bbbbbbbbbb', 1, true),       'missing coco-platform session')
    assert_truthy(body:find('wezterm_work_packages_cccccccccc', 1, true),            'missing packages session')
  end)

  it('drops stale pane→session entries on workspace mismatch', function()
    reset_global_state()
    -- pane 1 lives in the config workspace but the in-memory map says
    -- it hosts a work session — same shape as the bug from earlier
    -- in this thread.
    tab_visibility.set_pane_session(1, 'wezterm_work_coco-server_dddddddddd')

    mock.set_mux({
      windows = {
        { workspace = 'config', tabs = {
          { id = 200, title = 'wezterm-config', active_pane = { id = 1 } },
        }},
      },
    })

    local out = tmpfile()
    attention.write_live_snapshot(out, 'test-trace')
    os.remove(out)

    -- After the snapshot, the stale edge should have been forgotten.
    local map = _G.__WEZTERM_PANE_TMUX_SESSION
    assert_eq(map['1'], nil, 'stale edge survived snapshot')
  end)

  it('heals overflow pane→session edge from the workspace registry', function()
    reset_global_state()
    -- Workspace registry seeded by some earlier spawn_overflow_tab +
    -- Alt+t. Overflow placeholder lives at pane id 16.
    tab_visibility.set_overflow_pane('work', 16, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_eeeeeeeeee')

    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 300, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 301, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })

    local out = tmpfile()
    attention.write_live_snapshot(out, 'test-trace')

    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)

    -- Overflow's projected session must show up in sessions → 16.
    assert_truthy(body:find('"wezterm_work_coco-server_eeeeeeeeee":"16"', 1, true)
              or body:find('"wezterm_work_coco-server_eeeeeeeeee":16',   1, true),
                  'overflow pane not registered in sessions reverse map; body=' .. body)
    -- Unified map should have been memoized, so the next pane_for_session
    -- call hits in-memory and avoids the cmd.exe directory walk.
    assert_eq(tab_visibility.pane_for_session('wezterm_work_coco-server_eeeeeeeeee'), 16,
              'overflow pane not memoized in unified map')
  end)
end)

describe('activate_in_gui jumps via session, not stored pane id', function()
  it('routes around a stale stored wezterm_pane_id', function()
    reset_global_state()
    -- The entry was emitted when its session lived at pane 99 (now dead).
    -- Today the same session is hosted by pane 16 (e.g. overflow rotation).
    tab_visibility.set_pane_session(16, 'wezterm_work_coco-server_ffffffffff')

    local activated_pane_id
    -- Replace pane:activate so the test sees which pane was hit.
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 400, title = '…', active_pane = { id = 16 } },
        }},
      },
    })
    -- Patch the pane object's activate to record the id.
    for _, win in ipairs(mock.mux.all_windows()) do
      for _, tab in ipairs(win:tabs()) do
        for _, info in ipairs(tab:panes_with_info()) do
          local pane = info.pane
          local original_activate = pane.activate
          pane.activate = function(self)
            activated_pane_id = self.id
            if original_activate then original_activate(self) end
          end
        end
      end
    end

    local ok = attention.activate_in_gui(99, nil, nil,
      { tmux_session = 'wezterm_work_coco-server_ffffffffff' })
    assert_truthy(ok, 'activate_in_gui returned false')
    assert_eq(activated_pane_id, 16, 'activate landed on the wrong pane')
  end)

  it('does not surface entries with no live host', function()
    reset_global_state()
    -- No wezterm pane hosts the session. Entry has a stored pane id
    -- (1) that *is* alive but represents an unrelated pane in another
    -- workspace — exactly the failure mode where Alt+/ would end up
    -- surfacing a row that jumps to the user's own current pane.
    mock.set_mux({
      windows = {
        { workspace = 'config', tabs = {
          { id = 500, title = 'wezterm-config', active_pane = { id = 1 } },
        }},
      },
    })
    -- Force an in-memory edge so session_is_hosted has a populated map
    -- to consult; it just doesn't include the orphan session.
    tab_visibility.set_pane_session(1, 'wezterm_config_wezterm-config_xxxxxxxxxx')

    -- Direct test of attention.collect via a synthetic state_cache.
    -- We poke into the module by calling reload_state with no path so
    -- the cache resets, then manually populate.
    attention.configure { state_file = '/nonexistent' }
    attention.reload_state()
    -- attention.lua keeps state_cache as a module-local; it exposes
    -- collect() but no setter. The cleanest way to inject is by
    -- writing a real attention.json and re-reading it.
    local p = tmpfile()
    local fd = io.open(p, 'w')
    fd:write([[{
      "version": 1,
      "entries": {
        "self": {
          "session_id": "self",
          "wezterm_pane_id": "1",
          "tmux_session": "wezterm_config_wezterm-config_xxxxxxxxxx",
          "tmux_socket": "/tmp/tmux-1000/default",
          "tmux_window": "@1",
          "tmux_pane": "%1",
          "status": "running",
          "ts": ]] .. tostring(os.time() * 1000) .. [[
        },
        "orphan": {
          "session_id": "orphan",
          "wezterm_pane_id": "1",
          "tmux_session": "wezterm_work_coco-server_zzzzzzzzzz",
          "tmux_socket": "/tmp/tmux-1000/default",
          "tmux_window": "@13",
          "tmux_pane": "%21",
          "status": "done",
          "ts": ]] .. tostring(os.time() * 1000) .. [[
        }
      }
    }]])
    fd:close()
    attention.configure { state_file = p }
    attention.reload_state()
    os.remove(p)

    local waiting, done, running = attention.collect()
    -- self entry (live) must survive; orphan entry must be filtered.
    local function ids(arr)
      local out = {}
      for _, e in ipairs(arr) do out[e.session_id] = true end
      return out
    end
    assert_truthy(ids(running)['self'], 'self entry was filtered (false negative)')
    assert_falsy(ids(done)['orphan'],   'orphan entry leaked through (the bug)')
  end)
end)

describe('activate_in_gui auto-projects folded sessions into overflow', function()
  it('spawns the project helper and lands the activation on the overflow pane', function()
    -- Setup: coco-server is parked in tmux but no wezterm pane hosts
    -- it. The work workspace has an overflow placeholder at pane 16.
    -- The user picks coco-server in Alt+/. Expected behavior:
    --   1. activate_in_gui detects no host for coco-server
    --   2. parses session workspace = "work" from the session name
    --   3. finds pane 16 (overflow placeholder) in the work workspace
    --   4. calls the registered overflow_project_spawner to spawn
    --      the bash helper that switch-clients the overflow pane
    --   5. memoizes pane 16 → coco-server in the unified map
    --   6. activation walks the mux and lands on pane 16
    _G.__WEZTERM_PANE_TMUX_SESSION = {}
    _G.__WEZTERM_TAB_OVERFLOW = {}

    local activated_pane_id
    local spawned_args = nil
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 101, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })
    -- Patch pane:activate so the test sees the activation target.
    for _, win in ipairs(mock.mux.all_windows()) do
      for _, tab in ipairs(win:tabs()) do
        for _, info in ipairs(tab:panes_with_info()) do
          local pane = info.pane
          pane.activate = function(self) activated_pane_id = self.id end
        end
      end
    end

    -- Register a fake spawner that records the call.
    attention.register {
      logger = nil,
      overflow_project_spawner = function(workspace, session, pane_ref)
        spawned_args = { workspace = workspace, session = session }
        return { 'echo', workspace, session }  -- harmless; wezterm.background_child_process is mocked
      end,
    }

    local ok = attention.activate_in_gui(99, nil, nil,
      { tmux_session = 'wezterm_work_coco-server_ffffffffff' })

    assert_truthy(ok, 'activate_in_gui returned false')
    assert_truthy(spawned_args, 'project spawner was not called')
    assert_eq(spawned_args.workspace, 'work', 'wrong workspace passed to spawner')
    assert_eq(spawned_args.session, 'wezterm_work_coco-server_ffffffffff', 'wrong session')
    assert_eq(activated_pane_id, 16, 'activation did not land on the overflow pane')
    assert_eq(_G.__WEZTERM_PANE_TMUX_SESSION['16'], 'wezterm_work_coco-server_ffffffffff',
      'unified map did not memoize the new projection')
  end)
end)

describe('optimistic hide drops the entry immediately on Alt+.', function()
  it('removes the hidden entry from collect/picker before disk catches up', function()
    -- Setup: two done entries. Alt+. on the first should drop badge
    -- from `done 2` to `done 1` immediately. Without optimistic_hide
    -- the badge stays at 2 until the background --forget completes
    -- and reload_state catches up — and a second Alt+. that races
    -- the disk update sees both vanish (2 → 0).
    _G.__WEZTERM_PANE_TMUX_SESSION = {}
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'a', active_pane = { id = 10 } },
          { id = 101, title = 'b', active_pane = { id = 11 } },
        }},
      },
    })
    tab_visibility.set_pane_session(10, 'wezterm_work_a_aaaaaaaaaa')
    tab_visibility.set_pane_session(11, 'wezterm_work_b_bbbbbbbbbb')
    local now = os.time() * 1000
    local p = os.tmpname()
    local fd = io.open(p, 'w')
    fd:write('{"version":1,"entries":{'
      .. '"d1":{"session_id":"d1","wezterm_pane_id":"10",'
        .. '"tmux_session":"wezterm_work_a_aaaaaaaaaa",'
        .. '"status":"done","ts":' .. tostring(now) .. '},'
      .. '"d2":{"session_id":"d2","wezterm_pane_id":"11",'
        .. '"tmux_session":"wezterm_work_b_bbbbbbbbbb",'
        .. '"status":"done","ts":' .. tostring(now) .. '}'
      .. '}}')
    fd:close()
    attention.configure { state_file = p }
    attention.reload_state()
    os.remove(p)

    local _, done, _ = attention.collect()
    assert_eq(#done, 2, 'precondition: collect should see both done entries')

    -- Simulate Alt+. on the first entry.
    attention.optimistically_hide({ session_id = 'd1', ts = now })

    local _, done2, _ = attention.collect()
    assert_eq(#done2, 1, 'optimistic hide did not drop the badge count')
    assert_eq(done2[1].session_id, 'd2', 'wrong entry remained after hide')
  end)
end)

describe('overflow tab counts toward running badge', function()
  it('counts running entry even when no wezterm pane is known to host the session', function()
    -- Worst case: wezterm just reloaded, the registry is empty, and
    -- the user has not pressed Alt+t yet. The overflow placeholder
    -- still exists in the work workspace but no Lua state knows what
    -- session it currently projects. A coco-server hook fires
    -- `running`. The right-status badge in work should still tick up
    -- because running is informational, not actionable.
    reset_global_state()

    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 700, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 701, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })

    local p = tmpfile()
    local fd = io.open(p, 'w')
    fd:write([[{
      "version": 1,
      "entries": {
        "ccdc6240": {
          "session_id": "ccdc6240",
          "wezterm_pane_id": "9999",
          "tmux_session": "wezterm_work_coco-server_ffffffffff",
          "status": "running",
          "ts": ]] .. tostring(os.time() * 1000) .. [[
        }
      }
    }]])
    fd:close()
    attention.configure { state_file = p }
    attention.reload_state()
    os.remove(p)

    local _, _, running = attention.collect()
    assert_eq(#running, 1, 'running entry was filtered when overflow registry was empty')
  end)

  it('counts running entry whose session is currently in overflow', function()
    reset_global_state()

    -- Production layout: work workspace has 5 visible managed tabs +
    -- the overflow placeholder. Right now overflow projects coco-server
    -- (its tmux session is alive elsewhere; the overflow pane is
    -- currently attached to it via tmux switch-client).
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')
    tab_visibility.set_pane_session(11, 'wezterm_work_coco-platform_bbbbbbbbbb')
    tab_visibility.set_pane_session(12, 'wezterm_work_packages_cccccccccc')
    tab_visibility.set_pane_session(13, 'wezterm_work_breeze-monkey_dddddddddd')
    tab_visibility.set_pane_session(14, 'wezterm_work_operations-monkey_eeeeeeeeee')
    tab_visibility.set_overflow_pane('work', 16, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_ffffffffff')

    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 600, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 601, title = 'coco-platform',       active_pane = { id = 11 } },
          { id = 602, title = 'packages',            active_pane = { id = 12 } },
          { id = 603, title = 'breeze-monkey',       active_pane = { id = 13 } },
          { id = 604, title = 'operations-monkey',   active_pane = { id = 14 } },
          { id = 605, title = '…',                   active_pane = { id = 16 } },
        }},
      },
    })

    -- Snapshot tick runs first to populate the unified map.
    local snap = tmpfile()
    attention.write_live_snapshot(snap, 'test')
    os.remove(snap)

    -- Hook fires: coco-server is running.
    local p = tmpfile()
    local fd = io.open(p, 'w')
    fd:write([[{
      "version": 1,
      "entries": {
        "ccdc6240": {
          "session_id": "ccdc6240",
          "wezterm_pane_id": "1",
          "tmux_session": "wezterm_work_coco-server_ffffffffff",
          "tmux_socket": "/tmp/tmux-1000/default",
          "tmux_window": "@13",
          "tmux_pane": "%21",
          "status": "running",
          "ts": ]] .. tostring(os.time() * 1000) .. [[
        }
      }
    }]])
    fd:close()
    attention.configure { state_file = p }
    attention.reload_state()
    os.remove(p)

    local _, _, running = attention.collect()
    local found = false
    for _, e in ipairs(running) do
      if e.session_id == 'ccdc6240' then found = true end
    end
    assert_truthy(found,
      'overflow-projected coco-server running entry was filtered out — right-status badge will under-count')
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
