-- Confirms tab_visibility.is_enabled returns true unconditionally for
-- any non-empty workspace name once configured. The previous opt-in
-- (`enabled_workspaces` allowlist) was removed when the user asked
-- for "默认能力" — every workspace gets the picker / overflow / stats
-- without any config knob.
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
local function assert_truthy(v, m) if not v then error(m or 'expected truthy', 2) end end
local function assert_falsy(v, m) if v then error((m or 'expected falsy') .. ': ' .. tostring(v), 2) end end

describe('is_enabled is the default for every workspace', function()
  it('returns true for arbitrary workspace names once configured', function()
    tab_visibility.configure { wezterm = mock, config = {} }
    assert_truthy(tab_visibility.is_enabled('work'))
    assert_truthy(tab_visibility.is_enabled('config'))
    assert_truthy(tab_visibility.is_enabled('mock-deck'))
    assert_truthy(tab_visibility.is_enabled('any-future-workspace'))
  end)

  it('returns false for empty / nil names (sanity guard)', function()
    tab_visibility.configure { wezterm = mock, config = {} }
    assert_falsy(tab_visibility.is_enabled(nil))
    assert_falsy(tab_visibility.is_enabled(''))
  end)
end)

io.write(string.format('\n%d passed, %d failed\n', pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
