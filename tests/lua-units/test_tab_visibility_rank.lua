-- Phase 0 (tab-visibility hot reorder): verify that rank_sessions
-- aggregates `<base>__refresh_<ts>_<pid>` variants under the base name
-- so `refresh-current-window` resets don't fragment a project's focus
-- weight across N short-lived rows. Without aggregation a frequently
-- refreshed project gets out-ranked by less-used projects whose stats
-- happen to be in fewer rows.
--
-- Schema v4: ranking key is activity_score + decayed access_bonus
-- (from last_access_ms). Rows with neither git activity nor access are
-- ignored so callers fall back to workspaces.lua declaration order.
-- `total_dwell_ms` remains the never-decayed lifetime focus counter,
-- aggregated alongside for picker display on active rows.
package.path = './tests/lua-units/?.lua;./wezterm-x/lua/?.lua;./wezterm-x/lua/ui/?.lua;' .. package.path

local mock = require 'wezterm_mock'
package.preload['wezterm'] = function() return mock end
_G.WEZTERM_RUNTIME_DIR = './wezterm-x'

local tab_visibility = require 'tab_visibility'

local fail_count, pass_count = 0, 0
local function describe(n, fn) io.write('▸ ' .. n .. '\n') fn() end
local function it(n, fn)
  local ok, err = pcall(fn)
  if ok then pass_count = pass_count + 1 io.write('  ✓ ' .. n .. '\n')
  else fail_count = fail_count + 1 io.write('  ✗ ' .. n .. '\n    ' .. tostring(err) .. '\n') end
end
local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or 'mismatch') .. ': expected ' .. tostring(expected) ..
      ', got ' .. tostring(actual), 2)
  end
end
local function assert_close(actual, expected, eps, msg)
  if math.abs((actual or 0) - expected) > (eps or 1e-9) then
    error((msg or 'mismatch') .. ': expected ~' .. tostring(expected) ..
      ', got ' .. tostring(actual), 2)
  end
end

describe('_normalize_session_name', function()
  local n = tab_visibility._normalize_session_name

  it('strips __refresh_<ts>_<pid> suffix', function()
    assert_eq(n('wezterm_work_coco-server_ebee3ed55c__refresh_20260507T090418_4108862'),
              'wezterm_work_coco-server_ebee3ed55c')
  end)

  it('leaves bare session names unchanged', function()
    assert_eq(n('wezterm_work_coco-server_ebee3ed55c'),
              'wezterm_work_coco-server_ebee3ed55c')
    assert_eq(n('wezterm_work_overflow'), 'wezterm_work_overflow')
    assert_eq(n('plain'), 'plain')
  end)

  it('does not strip suffixes that do not match the exact format', function()
    -- Letters where digits expected → not a real refresh suffix.
    assert_eq(n('foo__refresh_abc_123'), 'foo__refresh_abc_123')
    -- Missing T separator.
    assert_eq(n('foo__refresh_20260507_123'), 'foo__refresh_20260507_123')
    -- Single underscore "_refresh_" is not the marker.
    assert_eq(n('foo_refresh_20260507T010203_4'), 'foo_refresh_20260507T010203_4')
  end)

  it('handles edge inputs without crashing', function()
    assert_eq(n(''), '')
    assert_eq(n(nil), nil)
    -- non-string returns as-is (defensive — production callers should
    -- not pass non-strings, but let the rank path stay total).
    assert_eq(n(42), 42)
  end)

  it('peels only the trailing suffix when chained suffixes appear', function()
    -- Pathological input: a session refreshed, then refreshed again
    -- with the previous suffixed name as the "base". Greedy match
    -- peels the outer suffix only, which is the desired behaviour
    -- (each refresh emits one suffix layer onto the live session
    -- name; chained layers aren't a real shape today, but if they
    -- ever appear we still aggregate at one level instead of
    -- collapsing everything).
    local input = 'base__refresh_20260101T010101_1__refresh_20260102T020202_2'
    assert_eq(n(input), 'base__refresh_20260101T010101_1')
  end)
end)

describe('_rank_sessions', function()
  local r = tab_visibility._rank_sessions

  it('returns empty array for nil / malformed stats', function()
    assert_eq(#r(nil), 0)
    assert_eq(#r({}), 0)
    assert_eq(#r({ sessions = nil }), 0)
    assert_eq(#r({ sessions = 'not-a-table' }), 0)
  end)

  it('ignores a single view-only entry', function()
    local out = r {
      sessions = {
        ['wezterm_work_coco-platform_4cbcc8f612'] = {
          dwell_ms = 1500000, total_dwell_ms = 1800000, raw_count = 3, last_bump_ms = 1000,
        },
      },
    }
    assert_eq(#out, 0)
  end)

  it('passes through a single active bare-name entry', function()
    local out = r {
      sessions = {
        ['wezterm_work_coco-platform_4cbcc8f612'] = {
          activity_score = 20, activity_count = 1, last_activity_ms = 1500,
          dwell_ms = 1500000, total_dwell_ms = 1800000, raw_count = 3, last_bump_ms = 1000,
        },
      },
    }
    assert_eq(#out, 1)
    assert_eq(out[1].name, 'wezterm_work_coco-platform_4cbcc8f612')
    assert_close(out[1].dwell_ms, 1500000)
    assert_eq(out[1].total_dwell_ms, 1800000)
    assert_eq(out[1].raw_count, 3)
    assert_eq(out[1].last_bump_ms, 1000)
  end)

  it('aggregates active refresh-suffix variants under the base name', function()
    -- All four variants of coco-server collapse to one row; their
    -- activity_score, dwell_ms, and total_dwell_ms all sum for display.
    local stats = {
      version = 4,
      sessions = {
        ['wezterm_work_coco-server_ebee3ed55c'] = {
          activity_score = 10, activity_count = 1, last_activity_ms = 1000,
          dwell_ms = 1000000, total_dwell_ms = 5000000, raw_count = 3, last_bump_ms = 1000,
        },
        ['wezterm_work_coco-server_ebee3ed55c__refresh_20260506T174432_2661849'] = {
          activity_score = 20, activity_count = 1, last_activity_ms = 2000,
          dwell_ms = 180000, total_dwell_ms = 200000, raw_count = 1, last_bump_ms = 2000,
        },
        ['wezterm_work_coco-server_ebee3ed55c__refresh_20260507T090418_4108862'] = {
          activity_score = 30, activity_count = 1, last_activity_ms = 3000,
          dwell_ms = 510000, total_dwell_ms = 800000, raw_count = 1, last_bump_ms = 3000,
        },
        ['wezterm_work_coco-platform_4cbcc8f612'] = {
          activity_score = 5, activity_count = 1, last_activity_ms = 500,
          dwell_ms = 290000, total_dwell_ms = 400000, raw_count = 3, last_bump_ms = 500,
        },
      },
    }
    local out = r(stats)
    assert_eq(#out, 2, 'expected exactly two ranked entries (one per base name)')
    -- coco-server ranks first by aggregated activity_score (10+20+30 > 5).
    assert_eq(out[1].name, 'wezterm_work_coco-server_ebee3ed55c')
    assert_close(out[1].rank_score, 60)
    assert_close(out[1].dwell_ms, 1690000, 1e-6, 'coco-server aggregated dwell_ms')
    assert_eq(out[1].total_dwell_ms, 6000000, 'coco-server aggregated total_dwell_ms')
    assert_eq(out[1].raw_count, 5, 'coco-server aggregated raw_count')
    assert_eq(out[1].last_bump_ms, 3000, 'coco-server last_bump_ms is max across variants')
    assert_eq(out[2].name, 'wezterm_work_coco-platform_4cbcc8f612')
    assert_close(out[2].dwell_ms, 290000)
    assert_eq(out[2].raw_count, 3)
  end)

  it('ignores rows without activity instead of ranking legacy dwell', function()
    local out = r {
      sessions = {
        a = { dwell_ms = 500, raw_count = 1 },
        b = { dwell_ms = 500, raw_count = 5 },
        c = { dwell_ms = 200, raw_count = 1 },
        d = { dwell_ms = 200, raw_count = 1 },
        z = { dwell_ms = 900, raw_count = 0 },
      },
    }
    assert_eq(#out, 0)
  end)

  it('orders activity rows by activity_score, then last_activity_ms, then name', function()
    local out = r {
      version = 4,
      sessions = {
        high_dwell_view_only = { dwell_ms = 9999999, raw_count = 99 },
        active_old = {
          activity_score = 40, activity_count = 2, last_activity_ms = 1000,
          dwell_ms = 10, raw_count = 1,
        },
        active_recent = {
          activity_score = 40, activity_count = 1, last_activity_ms = 2000,
          dwell_ms = 10, raw_count = 1,
        },
        active_top = {
          activity_score = 60, activity_count = 1, last_activity_ms = 500,
          dwell_ms = 10, raw_count = 1,
        },
      },
    }
    assert_eq(out[1].name, 'active_top')
    assert_eq(out[2].name, 'active_recent')
    assert_eq(out[3].name, 'active_old')
    assert_eq(#out, 3, 'view-only legacy dwell rows are not ranked')
    assert_close(out[1].rank_score, 60)
  end)

  it('activity beats legacy dwell once both rows have activity events', function()
    local out = r {
      version = 4,
      sessions = {
        view_only = {
          activity_score = 0, activity_count = 1, last_activity_ms = 3000,
          dwell_ms = 9999999, raw_count = 99,
        },
        worked = {
          activity_score = 20, activity_count = 1, last_activity_ms = 2000,
          dwell_ms = 10, raw_count = 1,
        },
      },
    }
    assert_eq(out[1].name, 'worked')
    assert_eq(out[2].name, 'view_only')
  end)

  it('ranks any activity row ahead of view-only legacy dwell rows', function()
    local out = r {
      version = 4,
      sessions = {
        old_a = { dwell_ms = 39051807, raw_count = 45, activity_score = 0, activity_count = 0 },
        old_b = { dwell_ms = 35229360, raw_count = 36, activity_score = 0, activity_count = 0 },
        team_repo = {
          dwell_ms = 22117793,
          raw_count = 23,
          activity_score = 234,
          activity_count = 8,
          last_activity_ms = 1783569882098,
        },
      },
    }
    assert_eq(out[1].name, 'team_repo')
    assert_eq(out[1].rank_tier, 1)
    assert_eq(#out, 1)
  end)

  it('does not rank long-used view-only sessions', function()
    local out = r {
      sessions = {
        a = { dwell_ms = 1800000, raw_count = 50 },
        b = { dwell_ms = 30000,   raw_count = 1 },
        c = { dwell_ms = 30000,   raw_count = 1 },
        d = { dwell_ms = 30000,   raw_count = 1 },
      },
    }
    assert_eq(#out, 0)
  end)

  it('ignores legacy v2 uncapped dwell for ranking', function()
    local out = r {
      version = 2,
      sessions = {
        frequent = { dwell_ms = 1734813895, total_dwell_ms = 4202636013, raw_count = 45 },
        overnight = { dwell_ms = 5013459119, total_dwell_ms = 5013668127, raw_count = 5 },
      },
    }
    assert_eq(#out, 0)
  end)

  it('skips non-table session entries defensively', function()
    local out = r {
      sessions = {
        good = { activity_score = 5, activity_count = 1, last_activity_ms = 100, dwell_ms = 500, raw_count = 1 },
        bad_string = 'oops',
        bad_number = 42,
      },
    }
    assert_eq(#out, 1)
    assert_eq(out[1].name, 'good')
  end)

  it('treats missing diagnostic fields on active rows as zero', function()
    local out = r {
      sessions = {
        partial = { activity_score = 10, activity_count = 1, last_activity_ms = 100 },
        with_dwell = { dwell_ms = 300 },
      },
    }
    assert_eq(#out, 1)
    assert_eq(out[1].name, 'partial')
    assert_close(out[1].dwell_ms, 0)
    assert_eq(out[1].raw_count, 0)
    assert_eq(out[1].last_bump_ms, 0)
    assert_eq(out[1].total_dwell_ms, 0)
  end)

  it('ignores legacy v1 `weight` rows without activity', function()
    local out = r {
      sessions = {
        old_top    = { weight = 1.0, raw_count = 10, last_bump_ms = 1000 },
        old_middle = { weight = 0.5, raw_count = 5,  last_bump_ms = 1000 },
        old_bottom = { weight = 0.1, raw_count = 1,  last_bump_ms = 1000 },
      },
    }
    assert_eq(#out, 0)
  end)

  it('ignores mixed legacy rows without activity', function()
    local out = r {
      sessions = {
        already_migrated = { dwell_ms = 60000, total_dwell_ms = 60000, raw_count = 3 },
        not_yet_migrated = { weight = 0.9, raw_count = 1 },
      },
    }
    assert_eq(#out, 0)
  end)

  it('ranks access-only rows via decayed visit bonus', function()
    tab_visibility._reset()
    tab_visibility.configure {
      wezterm = mock,
      config = { access_weight = 60, half_life_days = 7, recompute_interval_ms = 0 },
    }
    local now = 1000000
    local out = r({
      sessions = {
        visited = { last_access_ms = now, dwell_ms = 0, raw_count = 0 },
        idle = { dwell_ms = 999999, raw_count = 50 },
      },
    }, now)
    assert_eq(#out, 1)
    assert_eq(out[1].name, 'visited')
    assert_close(out[1].rank_score, 60, 1e-6)
  end)

  it('sums access bonus with activity_score', function()
    tab_visibility._reset()
    tab_visibility.configure {
      wezterm = mock,
      config = { access_weight = 60, half_life_days = 7, recompute_interval_ms = 0 },
    }
    local now = 7 * 86400000 -- one half-life after epoch access
    local out = r({
      sessions = {
        both = {
          activity_score = 40, activity_count = 1, last_activity_ms = 1,
          last_access_ms = 0, -- age = now - 0 → full decay? use explicit
        },
      },
    }, now)
    -- last_access_ms=0 → no bonus; pure activity.
    assert_eq(out[1].name, 'both')
    assert_close(out[1].rank_score, 40, 1e-6)

    out = r({
      sessions = {
        both = {
          activity_score = 40, activity_count = 1, last_activity_ms = 1,
          last_access_ms = 0,
        },
        recent = {
          activity_score = 10, activity_count = 1, last_activity_ms = 1,
          last_access_ms = now, -- age 0 → +60
        },
      },
    }, now)
    assert_eq(out[1].name, 'recent')
    assert_close(out[1].rank_score, 70, 1e-6)
    assert_eq(out[2].name, 'both')
    assert_close(out[2].rank_score, 40, 1e-6)
  end)

  it('decays access bonus with the same half-life as activity', function()
    tab_visibility._reset()
    tab_visibility.configure {
      wezterm = mock,
      config = { access_weight = 60, half_life_days = 7, recompute_interval_ms = 0 },
    }
    local half = 7 * 86400000
    local out = r({
      sessions = {
        week_ago = { last_access_ms = 0 },
      },
    }, half)
    assert_eq(#out, 0, 'last_access_ms=0 is not a visit')

    out = r({
      sessions = {
        week_ago = { last_access_ms = 1 },
      },
    }, half + 1)
    assert_eq(#out, 1)
    assert_close(out[1].rank_score, 30, 0.01, 'one half-life → half weight')
  end)

  it('keeps pure activity order when neither row has access', function()
    local out = r {
      sessions = {
        high = { activity_score = 100, activity_count = 1, last_activity_ms = 100 },
        low = { activity_score = 20, activity_count = 1, last_activity_ms = 200 },
      },
    }
    assert_eq(out[1].name, 'high')
    assert_eq(out[2].name, 'low')
    assert_close(out[1].rank_score, 100)
    assert_close(out[2].rank_score, 20)
  end)
end)

describe('visible_signature', function()
  it('stays stable across internal reranks and changes on membership replacement', function()
    local stats_dir = (os.getenv('TMPDIR') or '/tmp') .. '/wezterm-test-rank-sig-' .. tostring(math.random(100000, 999999))
    os.execute('mkdir -p ' .. stats_dir)

    tab_visibility._reset()
    tab_visibility.configure {
      wezterm = mock,
      config = {
        stats_dir = stats_dir,
        visible_count = 2,
        recompute_interval_ms = 0,
      },
    }

    local function write(body)
      local fd = io.open(stats_dir .. '/work.json', 'w')
      fd:write(body)
      fd:close()
    end

    write('{"version":4,"sessions":{"a":{"activity_score":100,"activity_count":1,"last_activity_ms":1000},"b":{"activity_score":50,"activity_count":1,"last_activity_ms":900}}}')
    tab_visibility.tick('work', 1000)
    local first_visible = tab_visibility.visible_signature('work')

    write('{"version":4,"sessions":{"a":{"activity_score":50,"activity_count":1,"last_activity_ms":1000},"b":{"activity_score":100,"activity_count":1,"last_activity_ms":900}}}')
    tab_visibility.tick('work', 2000)
    local second_visible = tab_visibility.visible_signature('work')

    assert_eq(first_visible, 'a|b')
    assert_eq(second_visible, first_visible,
      'relative score changes inside top-N must not move sticky slots')

    write('{"version":4,"sessions":{"b":{"activity_score":100,"activity_count":1,"last_activity_ms":900},"c":{"activity_score":80,"activity_count":1,"last_activity_ms":2000}}}')
    tab_visibility.tick('work', 3000)
    assert_eq(tab_visibility.visible_signature('work'), 'c|b',
      'new top-N member should replace the stale slot without moving the survivor')
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
