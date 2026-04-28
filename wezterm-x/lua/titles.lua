local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
if not runtime_dir or runtime_dir == '' then
  runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
end

local function load_module(name)
  return dofile(join_path(runtime_dir, 'lua', name .. '.lua'))
end

local helpers = load_module 'helpers'

local M = {}

function M.register(opts)
  local wezterm = opts.wezterm
  local palette = opts.palette
  local attention = opts.attention
  local chrome_debug_status = opts.chrome_debug_status
  local host = opts.host
  local logger = opts.logger
  local constants = opts.constants
  local tab_visibility = opts.tab_visibility
  local workspace_module = opts.workspace
  local actions_mod = nil
  if constants then
    -- Lazy-load actions only when titles is wired with constants; the
    -- attention.jump bus handler needs it to build the wsl.exe-wrapped
    -- argv for `attention-jump.sh --direct` (the tmux side of a
    -- picker-driven jump).
    local ok, mod = pcall(load_module, 'ui/actions')
    if ok then actions_mod = mod end
  end
  -- Wire up the unified event bus consumer. Producers (hooks, picker,
  -- future Go/bash callers) target named events through the same API;
  -- this side just registers per-name handlers. See docs/event-bus.md.
  local event_bus = load_module 'event_bus'
  local event_dir = constants
    and constants.wezterm_event_bus
    and constants.wezterm_event_bus.event_dir
    or nil
  event_bus.configure { event_dir = event_dir, logger = logger }
  -- One-time initial reload so the right-status counter has something
  -- to render before the first `attention.tick` event arrives. After
  -- this, state_cache is only refreshed inside the attention.tick
  -- handler — the previous "reload every 250 ms tick" pattern is gone.
  if attention and attention.reload_state then
    attention.reload_state()
  end
  local workspace_label_cache = {}
  local badge_last_status = {}
  local last_rendered_status = nil

  local function ime_snapshot()
    if not host or not host.feature then
      return nil, 'host_unavailable'
    end
    local feature = host:feature('ime_state')
    if not feature or not feature.query then
      return nil, 'feature_unavailable'
    end
    return feature.query('ime-status')
  end

  local function render_ime_segment()
    local state, reason = ime_snapshot()
    if state then
      local mode = state.mode
      if mode == 'native' then
        return wezterm.format {
          { Background = { Color = palette.ime_native_bg } },
          { Foreground = { Color = palette.ime_native_fg } },
          { Attribute = { Intensity = 'Bold' } },
          { Text = ' 中 ' },
        }
      elseif mode == 'alpha' then
        return wezterm.format {
          { Background = { Color = palette.ime_alpha_bg } },
          { Foreground = { Color = palette.ime_alpha_fg } },
          { Text = ' 英 ' },
        }
      elseif mode == 'en' then
        return wezterm.format {
          { Background = { Color = palette.tab_bar_background } },
          { Foreground = { Color = palette.ime_en_fg } },
          { Text = ' EN ' },
        }
      end
    end

    if reason == 'unsupported_runtime' then
      return nil
    end

    return wezterm.format {
      { Background = { Color = palette.tab_bar_background } },
      { Foreground = { Color = palette.ime_unknown_fg } },
      { Attribute = { Italic = true } },
      { Text = ' 中? ' },
    }
  end

  local function workspace_badge_style(name)
    local badges = palette.workspace_badges or {}
    local style = badges[name]

    if not style then
      style = name == 'default' and badges.default or badges.managed
    end

    return {
      bg = style and style.bg or palette.tab_bar_background,
      fg = style and style.fg or palette.tab_accent,
    }
  end

  local function format_workspace_label(name)
    if workspace_label_cache[name] then
      return workspace_label_cache[name]
    end

    local style = workspace_badge_style(name)
    local label = wezterm.format {
      { Background = { Color = style.bg } },
      { Foreground = { Color = style.fg } },
      { Attribute = { Intensity = 'Bold' } },
      { Text = ' ' .. name .. ' ' },
    }

    workspace_label_cache[name] = label
    return label
  end

  wezterm.on('format-window-title', function(tab, pane, tabs, panes, config_overrides)
    local dirs = helpers.unique_dirs_from_panes(panes)
    if #dirs == 0 then
      return tab.active_pane.title
    end

    return '📂 ' .. table.concat(dirs, ' | ')
  end)

  wezterm.on('format-tab-title', function(tab, tabs, panes, config_overrides, hover, max_width)
    local pane_infos = panes or {}
    local width = math.max(max_width - 2, 1)
    local title

    if tab.tab_title and tab.tab_title ~= '' then
      local pane_count = #pane_infos
      local summary = tab.tab_title
      if pane_count > 1 then
        summary = summary .. ' +' .. (pane_count - 1)
      end

      title = summary
    else
      local dirs = helpers.unique_dirs_from_panes(pane_infos)
      if #dirs > 0 then
        title = helpers.summarize_dirs(dirs, width)
      else
        title = tab.active_pane.title
      end
    end

    title = wezterm.truncate_right(title, width)

    local bg = palette.tab_inactive_bg
    local fg = palette.tab_inactive_fg

    if tab.is_active then
      bg = palette.tab_active_bg
      fg = palette.tab_active_fg
    elseif hover then
      bg = palette.tab_hover_bg
      fg = palette.tab_hover_fg
    end

    -- Earlier "slot projection" rewrote visible-window tab titles to the
    -- top-N session names computed by tab_visibility. Removed: the
    -- visible tabs are spawned from workspaces.lua's first-N entries
    -- and stay attached to those tmux sessions for the wezterm tab's
    -- entire lifetime, so a frequency-driven label can drift out of
    -- sync with the pane content (tab title says `team-stat` while
    -- the pane is actually attached to `packages`). Default rendering
    -- (cwd summary / OSC title) is the source-of-truth.
    local badge = attention and attention.tab_badge(tab) or nil
    local segments = {}
    if badge then
      -- Render the badge as a colored `█` over the tab's own background:
      -- the saturated status color lives on the foreground so the bar
      -- reads as an indicator stripe rather than a filled chip. We pull
      -- the saturated color from `badge_colors`'s bg slot — that's where
      -- the orange/blue/green hue is defined; the fg slot is the
      -- text-on-saturated contrast color, not what we want here.
      local badge_color, _ = attention.badge_colors(palette, badge.status)
      table.insert(segments, { Background = { Color = bg } })
      table.insert(segments, { Foreground = { Color = badge_color } })
      table.insert(segments, { Attribute = { Intensity = 'Bold' } })
      table.insert(segments, { Text = badge.marker })
    end
    if logger then
      local tab_id = tab.tab_id
      local active_pane_id = tab.active_pane and tab.active_pane.pane_id or nil
      local current = badge and badge.status or nil
      if tab_id and badge_last_status[tab_id] ~= current then
        badge_last_status[tab_id] = current
        if current then
          logger.info('attention', 'render_tab badge applied', {
            tab_id = tab_id,
            pane_id = active_pane_id,
            status = current,
          })
        else
          logger.info('attention', 'render_tab badge cleared', {
            tab_id = tab_id,
            pane_id = active_pane_id,
          })
        end
      end
    end
    table.insert(segments, { Background = { Color = bg } })
    table.insert(segments, { Foreground = { Color = fg } })
    table.insert(segments, { Attribute = { Intensity = tab.is_active and 'Bold' or 'Normal' } })
    table.insert(segments, { Text = ' ' .. title .. ' ' })

    return segments
  end)

  -- Compose the right-status bar from IME, chrome-debug, and attention
  -- segments. Kept pure so it can run from both the `update-status`
  -- tick (the 250ms cadence) and from `user-var-changed` when the agent
  -- attention hook pushes an `attention_tick`. The fast path uses the
  -- already-reloaded state cache, so the bar repaints within a frame of
  -- the OSC arrival instead of waiting up to 250ms for the next tick.
  --
  -- The active pane's id is forwarded to `attention.render_status_segment`
  -- so entries on the currently-focused (WezTerm pane + tmux pane) are
  -- filtered out of the counters — focused work is not "pending".
  local function refresh_right_status(window, pane)
    local right_segments = {}
    local ime_segment = render_ime_segment()
    if ime_segment then
      table.insert(right_segments, ime_segment)
    end
    local chrome_debug_segment = chrome_debug_status and chrome_debug_status.render_status_segment(palette) or nil
    if chrome_debug_segment then
      table.insert(right_segments, chrome_debug_segment)
    end
    local active_pane_id = nil
    if pane and type(pane.pane_id) == 'function' then
      local ok, pid = pcall(function() return pane:pane_id() end)
      if ok then active_pane_id = pid end
    end
    local attention_segment = attention
      and attention.render_status_segment(palette, { active_pane_id = active_pane_id })
      or nil
    if attention_segment then
      table.insert(right_segments, attention_segment)
    end
    window:set_right_status(table.concat(right_segments, ' '))
  end

  local function log_rendered_status(window)
    if not (logger and attention) then return end
    local waiting, done, running = attention.collect()
    local waiting_count = waiting and #waiting or 0
    local running_count = running and #running or 0
    local done_count = done and #done or 0
    local signature = waiting_count == 0 and running_count == 0 and done_count == 0
        and 'empty'
      or string.format('w=%d,r=%d,d=%d', waiting_count, running_count, done_count)
    if last_rendered_status ~= signature then
      last_rendered_status = signature
      logger.info('attention', 'render_status', {
        waiting = waiting_count,
        running = running_count,
        done = done_count,
        window_id = window:window_id(),
      })
    end
  end

  -- Track which wezterm pane the user is currently focused on across
  -- all gui windows. The hook (emit-agent-status.sh) reads this to
  -- decide whether to focus-skip a waiting/done upsert: "tmux pane is
  -- focused in its session" alone is not enough, because that flag
  -- stays true even while the user is on a totally different
  -- workspace looking at a different wezterm pane. Only when the
  -- wezterm-side focused pane equals the hook's WEZTERM_PANE should
  -- the upsert be skipped.
  wezterm.on('window-focus-changed', function(window, pane)
    if not window or not pane then return end
    local ok_focused, focused = pcall(function() return window:is_focused() end)
    if not ok_focused or not focused then
      -- Window lost focus — clear the marker. Safer than leaving the
      -- last-focused pane id sticky: we'd rather over-upsert than
      -- under-upsert when no wezterm window has user focus.
      _G.__WEZTERM_FOCUSED_PANE_ID = nil
      return
    end
    local ok_pid, pid = pcall(function() return pane:pane_id() end)
    if ok_pid and pid ~= nil then
      _G.__WEZTERM_FOCUSED_PANE_ID = tostring(pid)
    end
  end)

  wezterm.on('update-status', function(window, pane)
    local overrides = window:get_config_overrides()
    if overrides and next(overrides) ~= nil then
      window:set_config_overrides({})
      return
    end

    -- Refresh the focused-pane marker on every tick of the focused
    -- window too — window-focus-changed fires only on transitions, so
    -- a pane swap inside the focused window (e.g. Alt+number tab pick)
    -- still needs an update path. Cheap: one rawset on _G.
    local ok_focused, focused = pcall(function() return window:is_focused() end)
    if ok_focused and focused and pane and type(pane.pane_id) == 'function' then
      local ok_pid, pid = pcall(function() return pane:pane_id() end)
      if ok_pid and pid ~= nil then
        _G.__WEZTERM_FOCUSED_PANE_ID = tostring(pid)
      end
    end

    local workspace = window:active_workspace() or 'default'
    window:set_left_status(format_workspace_label(workspace))

    -- Tab-visibility: recompute the top-N slot assignment for this
    -- workspace at most once per recompute_interval_ms (the module owns
    -- the throttle). No-op when the workspace is not enabled in
    -- constants.tab_visibility.enabled_workspaces. See docs/tab-visibility.md.
    if tab_visibility and tab_visibility.is_enabled(workspace) then
      local now_ms = nil
      local ok, now_str = pcall(function()
        return wezterm.time.now():format '%s%3f'
      end)
      if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
        now_ms = tonumber(now_str)
      end
      if now_ms then tab_visibility.tick(workspace, now_ms) end
    end

    -- update-status owns the periodic housekeeping that genuinely
    -- needs the wezterm tick cadence:
    --   - tmux focus cache reset (the focus file changes on tmux pane
    --     switches, which fire no wezterm event we observe);
    --   - throttled background TTL prune;
    --   - focus-based auto-ack of `done` entries on the focused pane;
    --   - drain of file-transport events.
    --
    -- It does NOT reload `state.json` per tick anymore — that's now
    -- driven by the `attention.tick` event below, so producers writing
    -- state must publish (attention-jump.sh nudges, hooks via OSC).
    -- See docs/event-bus.md "Why event-driven, not polling".
    if attention and attention.reset_per_tick_cache then
      attention.reset_per_tick_cache()
    end
    if attention and attention.maybe_prune then
      attention.maybe_prune()
    end
    if attention and attention.maybe_refresh_live_snapshot then
      local snapshot_path = constants.attention and constants.attention.live_panes_file
      if snapshot_path then
        attention.maybe_refresh_live_snapshot(snapshot_path)
      end
    end
    if attention and attention.maybe_ack_focused then
      attention.maybe_ack_focused(window, pane)
    end

    -- Drain pending file-transport events. Hooks targeting OSC arrive
    -- via user-var-changed (sub-frame); anything that landed via the
    -- file branch — picker-driven attention.jump in particular —
    -- shows up here within one tick. See docs/event-bus.md.
    event_bus.poll_files(window, pane)

    refresh_right_status(window, pane)
    log_rendered_status(window)
  end)

  -- attention.tick handler. Fires when a hook signals that state.json
  -- has changed (currently always via OSC because hooks run in regular
  -- panes; the bus would route the same handler if it ever lands via
  -- file). Repaints the right-status counter immediately rather than
  -- waiting up to 250 ms for the next update-status tick.
  event_bus.on('attention.tick', function(value, meta)
    if not attention then return end
    if attention.reload_state then attention.reload_state() end
    if meta.window then
      refresh_right_status(meta.window, meta.pane)
      log_rendered_status(meta.window)
    end
    if logger then
      local latency_ms = nil
      local tick_ms = tonumber(value)
      if tick_ms then
        local ok, now_str = pcall(function()
          return wezterm.time.now():format '%s%3f'
        end)
        if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
          latency_ms = tonumber(now_str) - tick_ms
        end
      end
      logger.info('attention', 'tick received', {
        pane_id = meta.pane and meta.pane.pane_id and meta.pane:pane_id() or nil,
        value = value,
        latency_ms = latency_ms,
        transport = meta.transport,
      })
    end
  end)

  -- attention.jump handler. Fires on picker-driven jumps, currently
  -- always via the file transport because the picker runs inside a
  -- tmux popup whose DCS pass-through doesn't reach wezterm. Same
  -- in-process mux activate Alt+,/. use, plus a background spawn of
  -- `attention-jump.sh --direct` for the tmux side.
  event_bus.on('attention.jump', function(payload, meta)
    if not attention or not attention.parse_jump_payload then return end
    local coords = attention.parse_jump_payload(payload)
    if not coords then
      if logger then
        logger.warn('attention', 'jump payload unparseable',
          { value = payload, transport = meta.transport })
      end
      return
    end
    local activated = attention.activate_in_gui(
      coords.wezterm_pane, meta.window, meta.pane,
      { tmux_session = coords.tmux_session })
    if actions_mod and actions_mod.attention_jump_args and constants then
      local trailing = {
        '--direct',
        '--tmux-socket', coords.tmux_socket,
        '--tmux-window', coords.tmux_window,
      }
      if coords.tmux_pane and coords.tmux_pane ~= '' then
        table.insert(trailing, '--tmux-pane')
        table.insert(trailing, coords.tmux_pane)
      end
      local args = actions_mod.attention_jump_args(
        constants, meta.pane, trailing, logger, nil)
      if args then
        pcall(wezterm.background_child_process, args)
      end
    end
    if logger then
      logger.info('attention', 'jump dispatched', {
        kind         = coords.kind,
        session_id   = coords.session_id,
        archived_ts  = coords.archived_ts,
        wezterm_pane = coords.wezterm_pane,
        activated    = activated,
        transport    = meta.transport,
      })
    end
  end)

  -- Shared payload parser for tab.* events. Format is
  -- `v1|key1=val1|key2=val2|...`.
  local function parse_tab_payload(payload)
    if type(payload) ~= 'string' or payload == '' then return nil end
    local fields = {}
    for chunk in string.gmatch(payload, '([^|]+)') do
      local k, v = chunk:match('^([^=]+)=(.+)$')
      if k and v then fields[k] = v end
    end
    return fields
  end

  -- tab.activate_visible: Alt+t picker selected a session that already
  -- has a wezterm tab in its workspace. Just activate that tab.
  event_bus.on('tab.activate_visible', function(payload, meta)
    local fields = parse_tab_payload(payload)
    if not fields or not fields.workspace or not fields.cwd then return end
    if not workspace_module or not workspace_module.activate_only then return end
    local ok = workspace_module.activate_only(fields.workspace, fields.cwd)
    if logger then
      logger.info('tab_visibility', 'tab.activate_visible dispatched', {
        workspace = fields.workspace,
        cwd = fields.cwd,
        success = ok,
        transport = meta and meta.transport or '?',
      })
    end
  end)

  -- tab.activate_overflow: bash already switch-client'd the overflow
  -- pane to a warm session; bring that wezterm tab forward so the
  -- user sees it. Title stays `…` (overflow is positional, not
  -- session-bound).
  event_bus.on('tab.activate_overflow', function(payload, meta)
    local fields = parse_tab_payload(payload)
    if not fields or not fields.workspace then return end
    -- Refresh the overflow→session map so attention's auto-ack +
    -- Alt+/ jump fallback know which session this overflow pane is
    -- currently projecting. Tab title intentionally stays `…`.
    if tab_visibility and type(tab_visibility.set_overflow_attach) == 'function'
       and fields.session and fields.session ~= '' then
      -- Always resolve the overflow placeholder pane id from the live
      -- mux. The previous design trusted _G.__WEZTERM_TAB_OVERFLOW's
      -- stored pane_id, but that goes stale across workspace
      -- close+reopen — the new placeholder gets a fresh wezterm pane
      -- id while the registry keeps the dead one. set_pane_session
      -- then writes the unified map under the wrong pane and
      -- attention.lua never learns the new edge, so jumps fall back
      -- to entry stored wezterm_pane_id (a different stale id) and
      -- the user clicks Alt+/ → no jump. Resolve fresh each time.
      local found_pane_id
      local ok_all, all_windows = pcall(wezterm.mux.all_windows)
      if ok_all and type(all_windows) == 'table' then
        for _, mux_win in ipairs(all_windows) do
          local ok_ws, ws = pcall(function() return mux_win:get_workspace() end)
          if ok_ws and ws == fields.workspace then
            local ok_tabs, tabs_list = pcall(function() return mux_win:tabs() end)
            if ok_tabs and type(tabs_list) == 'table' then
              for _, mux_tab in ipairs(tabs_list) do
                local ok_title, title = pcall(function() return mux_tab:get_title() end)
                if ok_title and title == '…' then
                  local ok_pane, active_pane = pcall(function() return mux_tab:active_pane() end)
                  if ok_pane and active_pane then
                    pcall(function() found_pane_id = active_pane:pane_id() end)
                  end
                  break
                end
              end
            end
          end
          if found_pane_id then break end
        end
      end
      if found_pane_id and type(tab_visibility.set_overflow_pane) == 'function' then
        -- Re-seed every time so a stale pane_id from an earlier
        -- workspace incarnation is overwritten by the live one.
        tab_visibility.set_overflow_pane(fields.workspace, found_pane_id, fields.session)
      end
      tab_visibility.set_overflow_attach(fields.workspace, fields.session)
      -- Mirror the resolved pane → session edge into the unified map
      -- so attention focus/jump/badge logic sees the overflow pane as
      -- hosting the new session within the same tick.
      if found_pane_id and type(tab_visibility.set_pane_session) == 'function' then
        tab_visibility.set_pane_session(found_pane_id, fields.session)
      end
    end
    if not workspace_module or not workspace_module.activate_overflow then return end
    local ok = workspace_module.activate_overflow(fields.workspace)
    if logger then
      logger.info('tab_visibility', 'tab.activate_overflow dispatched', {
        workspace = fields.workspace,
        session = fields.session,
        success = ok,
        transport = meta and meta.transport or '?',
      })
    end
  end)

  -- tab.spawn_overflow handler. Fallback path when the Alt+t picker
  -- selects a cold session (no tmux session yet) — spawn it as a new
  -- wezterm tab via Workspace.spawn_or_activate. Bash writes a file
  -- event with payload `v1|workspace=<name>|cwd=<path>`. Always file
  -- transport (popup pty has no DCS pass-through to wezterm).
  event_bus.on('tab.spawn_overflow', function(payload, meta)
    if type(payload) ~= 'string' or payload == '' then return end
    local parts = {}
    for chunk in string.gmatch(payload, '([^|]+)') do
      parts[#parts + 1] = chunk
    end
    local fields = {}
    for _, p in ipairs(parts) do
      local k, v = p:match('^([^=]+)=(.+)$')
      if k and v then fields[k] = v end
    end
    local workspace_name = fields.workspace
    local cwd = fields.cwd
    if not workspace_name or not cwd then
      if logger then
        logger.warn('tab_visibility', 'tab.spawn_overflow payload missing fields', {
          transport = meta and meta.transport or '?',
          payload = payload,
        })
      end
      return
    end
    if not workspace_module or not workspace_module.spawn_or_activate then
      if logger then
        logger.warn('tab_visibility', 'tab.spawn_overflow but workspace module unavailable', {
          workspace = workspace_name,
          cwd = cwd,
        })
      end
      return
    end
    local ok = workspace_module.spawn_or_activate(workspace_name, cwd)
    if logger then
      logger.info('tab_visibility', 'tab.spawn_overflow dispatched', {
        workspace = workspace_name,
        cwd = cwd,
        success = ok,
        transport = meta and meta.transport or '?',
      })
    end
  end)

  -- Single user-var-changed entry point. Anything matching the `we_`
  -- prefix is routed through the bus to the matching event handler
  -- registered above; everything else is ignored.
  wezterm.on('user-var-changed', function(window, pane, name, value)
    event_bus.dispatch_user_var(name, value, window, pane)
  end)
end

return M
