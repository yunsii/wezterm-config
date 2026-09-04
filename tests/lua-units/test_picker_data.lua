-- Tests for the unified compute_picker_data pipeline. Same predicate
-- powers the right-status badge counts AND the picker rows the popup
-- renders, so a regression here is observable on both surfaces.
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
local function assert_falsy(v, m) if v then error((m or 'expected falsy') .. ': ' .. tostring(v), 2) end end

local function load_state(json)
  local p = os.tmpname()
  local fd = io.open(p, 'w')
  fd:write(json)
  fd:close()
  attention.configure { state_file = p }
  attention.reload_state()
  os.remove(p)
end

local function reset()
  _G.__WEZTERM_PANE_TMUX_SESSION = {}
  _G.__WEZTERM_TAB_OVERFLOW = {}
  mock.reset_mux()
  load_state('{"version":1,"entries":{}}')
end

local function find_row(rows, predicate)
  for _, r in ipairs(rows) do
    if predicate(r) then return r end
  end
  return nil
end

-- ── tests ──────────────────────────────────────────────────────────────

describe('badge counts and picker rows agree on the same predicate', function()
  it('orphan done is hidden on both surfaces; running is exempt and counted on both', function()
    reset()
    -- Live mux: user is in config workspace on pane 1.
    mock.set_mux({
      windows = {
        { workspace = 'config', tabs = {
          { id = 1, title = 'wezterm-config', active_pane = { id = 1 } },
        }},
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 101, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })
    -- Overflow projects coco-server.
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')
    tab_visibility.set_overflow_pane('work', 16, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_ffffffffff')

    -- Three entries: orphan done, hosted running, hosted waiting.
    local now_ts = tostring(os.time() * 1000)
    load_state('{"version":1,"entries":{'
      .. '"orphan-done":{"session_id":"orphan-done","wezterm_pane_id":"1",'
        .. '"tmux_session":"wezterm_work_ghost_zzzzzzzzzz",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@99","tmux_pane":"%99",'
        .. '"status":"done","ts":' .. now_ts .. ',"reason":"stale"},'
      .. '"running-overflow":{"session_id":"running-overflow","wezterm_pane_id":"9999",'
        .. '"tmux_session":"wezterm_work_coco-server_ffffffffff",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@13","tmux_pane":"%21",'
        .. '"status":"running","ts":' .. now_ts .. ',"reason":"writing manifest"},'
      .. '"waiting-visible":{"session_id":"waiting-visible","wezterm_pane_id":"10",'
        .. '"tmux_session":"wezterm_work_ai-video-collection_aaaaaaaaaa",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@2","tmux_pane":"%3",'
        .. '"status":"waiting","ts":' .. now_ts .. ',"reason":"approve change"}'
      .. '}}')

    -- Build snapshot panes/sessions maps the way write_live_snapshot does.
    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)

    -- Picker rows
    local rows = snapshot.picker_rows
    assert_truthy(find_row(rows, function(r) return r.id == 'running-overflow' end),
      'running entry missing from picker rows')
    assert_truthy(find_row(rows, function(r) return r.id == 'waiting-visible' end),
      'waiting entry with hosted session missing from picker rows')
    assert_falsy(find_row(rows, function(r) return r.id == 'orphan-done' end),
      'orphan done entry leaked into picker rows')

    -- Badge counts
    local counts = snapshot.picker_counts
    assert_eq(counts.running, 1, 'running count desync')
    assert_eq(counts.waiting, 1, 'waiting count desync')
    assert_eq(counts.done, 0, 'done count includes orphan')

    -- And the Lua-side M.collect agrees
    local w, d, r_buckets = attention.collect()
    assert_eq(#w, 1, 'collect waiting desync')
    assert_eq(#r_buckets, 1, 'collect running desync')
    assert_eq(#d, 0, 'collect done desync (orphan leaked)')
  end)

  it('paneless orphan (empty tmux_session AND empty wezterm_pane_id) is not counted', function()
    -- Production regression: agent hooks firing outside any managed
    -- WezTerm/tmux pane (e.g. OpenClaw-spawned agents) persist entries
    -- with empty tmux_session and empty wezterm_pane_id. The badge path
    -- (collect_buckets → entry_has_live_target) used to short-circuit
    -- these to "treat as live" and count them, while the picker path
    -- (entry_reachable) dropped them — so the right-status bar showed
    -- "5 done" while Alt+/ listed 1 and Alt+. had nothing to jump to.
    reset()
    -- A live pane exists, but the orphan references none of it.
    mock.set_mux({
      windows = {
        { workspace = 'config', tabs = {
          { id = 1, title = 'wezterm-config', active_pane = { id = 1 } },
        }},
      },
    })
    local now_ts = tostring(os.time() * 1000)
    load_state('{"version":1,"entries":{'
      .. '"paneless-done":{"session_id":"paneless-done","wezterm_pane_id":"",'
        .. '"tmux_session":"","tmux_socket":"","tmux_window":"","tmux_pane":"",'
        .. '"status":"done","ts":' .. now_ts .. ',"reason":"task done"}'
      .. '}}')

    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)

    assert_falsy(find_row(snapshot.picker_rows, function(r) return r.id == 'paneless-done' end),
      'paneless orphan leaked into picker rows')
    assert_eq(snapshot.picker_counts.done, 0, 'snapshot done count includes paneless orphan')

    -- Standalone badge path (nil maps → mux-walking entry_has_live_target).
    local _, d, _ = attention.collect()
    assert_eq(#d, 0, 'collect counted paneless orphan (entry_has_live_target regressed)')
  end)
end)

describe('overflow tab label uses session repo, not the … glyph', function()
  it('renders work/<repo>/... for an overflow-hosted entry (no tab_index prefix)', function()
    reset()
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 101, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')
    tab_visibility.set_overflow_pane('work', 16, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_ffffffffff')

    local now_ts = tostring(os.time() * 1000)
    load_state('{"version":1,"entries":{'
      .. '"running-overflow":{"session_id":"running-overflow","wezterm_pane_id":"16",'
        .. '"tmux_session":"wezterm_work_coco-server_ffffffffff",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@13","tmux_pane":"%21",'
        .. '"status":"running","ts":' .. now_ts .. ',"git_branch":"master","reason":"x"}'
      .. '}}')

    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)
    local row = find_row(snapshot.picker_rows, function(r) return r.id == 'running-overflow' end)
    assert_truthy(row, 'overflow row missing')
    assert_truthy(row.body:find('work/coco%-server/13_21/master', 1, false),
      'overflow label did not substitute session repo for the … glyph; got body=' .. row.body)
  end)
end)

describe('recent rows are deduped per window and ordered by activity desc', function()
  it('keeps one freshest row per tmux_window inside the same session', function()
    reset()
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
        }},
      },
    })
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')

    load_state([[{
      "version": 1,
      "entries": {},
      "recent": [
        { "session_id": "old",   "tmux_session": "wezterm_work_ai-video-collection_aaaaaaaaaa",
          "wezterm_pane_id": "10", "tmux_socket": "/tmp/sock", "tmux_window": "@2", "tmux_pane": "%5",
          "tmux_window_name": "dev-ci", "last_status": "done", "archived_ts": 1000 },
        { "session_id": "newer", "tmux_session": "wezterm_work_ai-video-collection_aaaaaaaaaa",
          "wezterm_pane_id": "10", "tmux_socket": "/tmp/sock", "tmux_window": "@2", "tmux_pane": "%5",
          "tmux_window_name": "dev-ci", "last_status": "done", "archived_ts": 2000,
          "last_user_prompt": "older prompt" },
        { "session_id": "newest","tmux_session": "wezterm_work_ai-video-collection_aaaaaaaaaa",
          "wezterm_pane_id": "10", "tmux_socket": "/tmp/sock", "tmux_window": "@2", "tmux_pane": "%5",
          "tmux_window_name": "dev-ci", "agent_name": "dev-ci-63",
          "last_user_prompt": "国际化脚本确认", "last_status": "done",
          "last_reason": "task done", "live_ts": 2500, "archived_ts": 3000 },
        { "session_id": "sibling","tmux_session": "wezterm_work_ai-video-collection_aaaaaaaaaa",
          "wezterm_pane_id": "10", "tmux_socket": "/tmp/sock", "tmux_window": "@12", "tmux_pane": "%21",
          "tmux_window_name": "dev-infra", "agent_name": "dev-infra-f1",
          "last_user_prompt": "observability", "last_status": "done",
          "last_reason": "task done", "live_ts": 4000, "archived_ts": 4100 }
      ]
    }]])
    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)

    local recent_rows = {}
    for _, r in ipairs(snapshot.picker_rows) do
      if r.status == 'recent' then table.insert(recent_rows, r) end
    end
    assert_eq(#recent_rows, 2, 'expected one recent row per worktree window')
    assert_truthy(recent_rows[1].id:find('sibling', 1, true),
      'first recent should be the higher-activity window: ' .. recent_rows[1].id)
    assert_truthy(recent_rows[2].id:find('newest', 1, true),
      'second recent should be the freshest @2 tombstone: ' .. recent_rows[2].id)
    assert_truthy(recent_rows[2].body:find('dev%-ci%-63', 1, false),
      'recent body should prefer agent_name over task done; got ' .. recent_rows[2].body)
    assert_truthy(recent_rows[2].body:find('国际化脚本确认', 1, true),
      'recent body should keep last_user_prompt; got ' .. recent_rows[2].body)
    assert_falsy(recent_rows[2].body:find('task done', 1, true),
      'canned last_reason leaked into recent body: ' .. recent_rows[2].body)
  end)

  it('caps recent rows at PICKER_RECENT_CAP', function()
    reset()
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
        }},
      },
    })
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')

    local parts = { '{"version":1,"entries":{},"recent":[' }
    for i = 1, 25 do
      if i > 1 then parts[#parts + 1] = ',' end
      parts[#parts + 1] = string.format(
        '{"session_id":"s%d","tmux_session":"wezterm_work_ai-video-collection_aaaaaaaaaa",'
          .. '"wezterm_pane_id":"10","tmux_socket":"/tmp/sock","tmux_window":"@%d","tmux_pane":"%%%d",'
          .. '"tmux_window_name":"w%d","last_status":"done","live_ts":%d,"archived_ts":%d}',
        i, i, i, i, i * 10, i * 10)
    end
    parts[#parts + 1] = ']}'
    load_state(table.concat(parts))

    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)
    local recent_rows = {}
    for _, r in ipairs(snapshot.picker_rows) do
      if r.status == 'recent' then table.insert(recent_rows, r) end
    end
    assert_eq(#recent_rows, attention.PICKER_RECENT_CAP, 'recent cap not applied')
    assert_truthy(recent_rows[1].id:find('s25', 1, true),
      'cap should keep the highest-activity rows first')
  end)
end)

describe('snapshot heals overflow edge even when registry pane_id is stale', function()
  it('writes the live placeholder pane → session edge into the unified map', function()
    -- Reproduces the bug observed after a wezterm config reload: the
    -- _G.__WEZTERM_TAB_OVERFLOW registry survived from an earlier
    -- workspace incarnation with a now-dead pane_id (e.g. 999), but
    -- the actual placeholder tab today is at pane 16. The previous
    -- implementation called set_pane_session(999, …), wrote the
    -- unified map under the dead id, and the picker never learned
    -- that pane 16 hosts coco-server. Result: Alt+/ on a coco-server
    -- entry fell through to the stored wezterm_pane_id and did not
    -- jump.
    --
    -- The snapshot must overwrite the stale registry edge with the
    -- live pane id. After write_live_snapshot the unified map keys
    -- 16 → coco-server (and ideally drops 999 entirely).
    reset()
    -- Stale registry: pane 999 from a previous workspace incarnation.
    tab_visibility.set_overflow_pane('work', 999, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_ffffffffff')
    -- Live mux: placeholder is actually at pane 16.
    mock.set_mux({
      windows = {
        { workspace = 'work', tabs = {
          { id = 100, title = 'ai-video-collection', active_pane = { id = 10 } },
          { id = 101, title = '…',                    active_pane = { id = 16 } },
        }},
      },
    })
    tab_visibility.set_pane_session(10, 'wezterm_work_ai-video-collection_aaaaaaaaaa')

    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)

    -- Live pane 16 must be the host for coco-server in the reverse
    -- map; the picker reads this as $sessions.
    assert_eq(snapshot.sessions['wezterm_work_coco-server_ffffffffff'], '16',
      'snapshot reverse map did not include the live overflow pane')
    -- The unified map must point pane 16 (live) at coco-server so
    -- subsequent jumps via pane_for_session resolve to it.
    assert_eq(tab_visibility.pane_for_session('wezterm_work_coco-server_ffffffffff'), 16,
      'unified map did not get the live overflow edge memoized')
  end)
end)

describe('label cross-checks workspace prefix on stored pane id', function()
  it('falls back to parsed session repo when stored pane is in another workspace', function()
    reset()
    -- coco-server entry stored pane_id = 1, but pane 1 today is in
    -- the config workspace (Claude pane). The label must NOT pick up
    -- config/1_wezterm-config/... — that was the bug from earlier in
    -- the thread.
    mock.set_mux({
      windows = {
        { workspace = 'config', tabs = {
          { id = 1, title = 'wezterm-config', active_pane = { id = 1 } },
        }},
        { workspace = 'work', tabs = {
          { id = 16, title = '…', active_pane = { id = 16 } },
        }},
      },
    })
    tab_visibility.set_overflow_pane('work', 16, 'wezterm_work_overflow')
    tab_visibility.set_overflow_attach('work', 'wezterm_work_coco-server_ffffffffff')

    local now_ts = tostring(os.time() * 1000)
    load_state('{"version":1,"entries":{'
      .. '"ccdc6240":{"session_id":"ccdc6240","wezterm_pane_id":"1",'
        .. '"tmux_session":"wezterm_work_coco-server_ffffffffff",'
        .. '"tmux_socket":"/tmp/sock","tmux_window":"@13","tmux_pane":"%21",'
        .. '"status":"done","ts":' .. now_ts .. ',"git_branch":"master","reason":"task done"}'
      .. '}}')

    local out = os.tmpname()
    attention.write_live_snapshot(out, 'test')
    local fd = io.open(out, 'r')
    local body = fd:read('*a')
    fd:close()
    os.remove(out)
    local snapshot = require('json_mini').decode(body)
    local row = find_row(snapshot.picker_rows, function(r) return r.id == 'ccdc6240' end)
    assert_truthy(row, 'expected coco-server row')
    -- Should be labeled with work workspace + coco-server (overflow
    -- substitution), not config/wezterm-config.
    assert_falsy(row.body:find('config/', 1, true),
      'label leaked unrelated config pane info: ' .. row.body)
    assert_truthy(row.body:find('work/', 1, true),
      'label missing work workspace: ' .. row.body)
    assert_truthy(row.body:find('coco%-server', 1, false),
      'label missing coco-server repo: ' .. row.body)
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
