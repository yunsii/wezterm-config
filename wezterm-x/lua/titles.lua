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
  local session_bridge_status = opts.session_bridge_status
  local disk_status = opts.disk_status
  local mem_status = opts.mem_status
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

  local latency = load_module 'latency'
  local lat_cfg = latency.config(constants)

  -- Alt+x continuous maintenance. Press path is cache-only; this tick
  -- refreshes items snapshots (has_tab) and rebuilds overflow-base.tsv
  -- in the background so the keystroke stays under ~50ms. See
  -- scripts/runtime/tab-overflow-prefetch-build.sh.
  local last_overflow_prefetch_ms = 0
  local OVERFLOW_PREFETCH_INTERVAL_MS = 5000
  local function maybe_refresh_overflow_prefetch(now_ms, pane)
    if not now_ms then return end
    if last_overflow_prefetch_ms ~= 0
      and (now_ms - last_overflow_prefetch_ms) < OVERFLOW_PREFETCH_INTERVAL_MS then
      return
    end
    last_overflow_prefetch_ms = now_ms
    if workspace_module and workspace_module.refresh_all_items_snapshots then
      pcall(workspace_module.refresh_all_items_snapshots)
    end
    local repo_root = constants and constants.repo_root
    if not repo_root or repo_root == '' then return end
    local script_path = repo_root .. '/scripts/runtime/tab-overflow-prefetch-build.sh'
    local args
    local runtime_mode = (constants and constants.runtime_mode) or 'hybrid-wsl'
    if runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
      local domain = (pane and pane.get_domain_name and pane:get_domain_name())
        or constants.default_domain
        or ''
      local distro = type(domain) == 'string' and domain:match('^WSL:(.+)$') or nil
      if not distro and type(constants.default_domain) == 'string' then
        distro = constants.default_domain:match('^WSL:(.+)$')
      end
      if not distro then return end
      args = { 'wsl.exe', '-d', distro, '--', 'bash', script_path }
    else
      args = { 'bash', script_path }
    end
    pcall(wezterm.background_child_process, args)
  end

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
  -- Phase 2b: per-workspace cache of the brain's sticky-slot signature.
  -- Compared on every update-status to decide whether visible tabs need
  -- spawn / prune / replacement work. Relative score changes within the
  -- same top-N set leave the signature stable and do not move tabs.
  local last_visible_signature = {}

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

    -- Tab colors, highest priority first:
    --
    --   1. focused      — always the active pair, never a status. The
    --                     background is the only thing saying which tab
    --                     is focused (`use_fancy_tab_bar = false`), and
    --                     the tab you are looking at is the one whose
    --                     status you least need announced.
    --   2. status       — an unfocused tab whose session has a live
    --                     agent status takes the full block treatment,
    --                     background plus its matching text color, the
    --                     same pairing the right-status counters use.
    --                     This outranks hover: the pointer is a
    --                     secondary affordance in a keyboard-first strip
    --                     and a status must not vanish under it.
    --   3. hover        — pointer feedback on an otherwise plain tab.
    --   4. default      — inactive.
    --
    -- Status is carried by recoloring rather than by anything added to
    -- the tab. A separate marker cell — a `█` prepended when and only
    -- when a status was live — was how this worked until 2026-08-19, and
    -- it re-flowed the whole tab strip every time an agent started or
    -- finished a turn; an agent flipping between `running` and `waiting`
    -- several times a minute made the titles twitch under the cursor.
    -- Reserving the cell on idle tabs also fixes the twitch but spends a
    -- column of every title on nothing. Recoloring costs no width at
    -- all, so there is nothing left to jitter. Tinting only the
    -- foreground was tried in between and was too quiet for action
    -- statuses (`waiting` / `done`); `running` stays a full recolor but
    -- on the quieter ambient ladder so it does not out-compete focus.
    -- Ladder + focus tuning: docs/agent-attention.md / constants.lua.
    local bg, fg
    if tab.is_active then
      bg = palette.tab_active_bg
      fg = palette.tab_active_fg
    elseif badge then
      bg, fg = attention.badge_colors(palette, badge.status)
    elseif hover then
      bg = palette.tab_hover_bg
      fg = palette.tab_hover_fg
    else
      bg = palette.tab_inactive_bg
      fg = palette.tab_inactive_fg
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

  -- Compose the right-status bar from IME, chrome-debug, session-bridge
  -- watch poller, host-disk, guest-memory, and attention segments. Order:
  --   IME | CDP·… | ◆ SB·N | D·151G | M·88% | ▲…✓…●…
  -- Kept pure so it can run from both the `update-status` tick (250ms)
  -- and from the event-bus handler when a producer publishes
  -- `attention.tick` (OSC wire `we_attention_tick`).
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
    local sb_segment = session_bridge_status
      and session_bridge_status.render_status_segment(palette)
      or nil
    if sb_segment then
      table.insert(right_segments, sb_segment)
    end
    local disk_segment = disk_status and disk_status.render_status_segment(palette) or nil
    if disk_segment then
      table.insert(right_segments, disk_segment)
    end
    local mem_segment = mem_status and mem_status.render_status_segment(palette) or nil
    if mem_segment then
      table.insert(right_segments, mem_segment)
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

    -- Threshold-gated UI-thread budget. Ordinary typing never enters
    -- Lua; a slow tick is the closest proxy for "keys feel sticky".
    -- Logging stays out of the render helpers — only flush at the end
    -- when duration crosses status_slow_ms (or emit_all). See
    -- docs/logging-conventions.md render-path discipline.
    local tick_t0 = latency.now_ms(wezterm)

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
    -- the throttle). When the brain's slot signature changes (Phase 2b
    -- sticky-slot churn — some session entered or fell out of top-N),
    -- nudge the workspace module to spawn missing tabs and prune
    -- demoted ones, with active-tab protection. No-op when the
    -- workspace is not enabled. See docs/tab-visibility.md.
    if tab_visibility and tab_visibility.is_enabled(workspace) then
      local now_ms = nil
      local ok, now_str = pcall(function()
        return wezterm.time.now():format '%s%3f'
      end)
      if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
        now_ms = tonumber(now_str)
      end
      if now_ms then
        tab_visibility.tick(workspace, now_ms)
        if workspace_module and workspace_module.maybe_sample_tab_activity then
          pcall(workspace_module.maybe_sample_tab_activity, workspace, now_ms)
        end
        -- Auto-detach the overflow pane when its currently-projected
        -- session just got promoted into top-N (so the new visible tab
        -- doesn't end up mirroring the overflow pane's tmux output via
        -- a shared session). Runs every tick — the call is cheap and
        -- idempotent, with active-pane protection mirroring the
        -- preserve_focus prune deferral pattern. See docs/tab-visibility.md.
        if workspace_module and workspace_module.maybe_clear_overflow_collision then
          local focused_pane_id = rawget(_G, '__WEZTERM_FOCUSED_PANE_ID')
          pcall(workspace_module.maybe_clear_overflow_collision, workspace, focused_pane_id)
        end
        if workspace_module and workspace_module.maybe_hot_reorder
          and tab_visibility.visible_signature
        then
          local sig = tab_visibility.visible_signature(workspace)
          if last_visible_signature[workspace] ~= sig then
            local prev = last_visible_signature[workspace]
            last_visible_signature[workspace] = sig
            -- Skip the very first observation (prev == nil): the
            -- brain just finished its first tick for this workspace
            -- and any "change" is just bootstrap. Later deltas only
            -- represent top-N membership changes assigned to sticky slots.
            if prev ~= nil then
              pcall(workspace_module.maybe_hot_reorder, workspace)
            end
          end
        end
        -- Keep Alt+x menu cache warm (items has_tab + overflow-base.tsv).
        maybe_refresh_overflow_prefetch(now_ms, pane)
      end
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

    local tick_t1 = latency.now_ms(wezterm)
    if logger and tick_t0 and tick_t1 then
      latency.observe(logger, lat_cfg, {
        kind = 'status',
        duration_ms = tick_t1 - tick_t0,
        window = window,
        pane = pane,
        fields = { workspace = workspace },
      })
    end
  end)

  -- Track OSC `attention.tick` values we have already processed so the
  -- file-transport echo handler below can detect a dropped primary tick
  -- and reload as a fallback. Keyed by stringified `tick_ms`; values are
  -- the wall-clock arrival ms. Entries older than ECHO_PAIR_WINDOW_MS
  -- are pruned on every echo so the table cannot grow unbounded across
  -- long-running sessions.
  local seen_osc_ticks = {}
  local ECHO_PAIR_WINDOW_MS = 30000

  local function wall_now_ms()
    local ok, now_str = pcall(function()
      return wezterm.time.now():format '%s%3f'
    end)
    if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
      return tonumber(now_str)
    end
    return nil
  end

  local function prune_seen_osc_ticks(now)
    if not now then return end
    local cutoff = now - ECHO_PAIR_WINDOW_MS
    for k, ts in pairs(seen_osc_ticks) do
      if ts < cutoff then
        seen_osc_ticks[k] = nil
      end
    end
  end

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
    if value and value ~= '' then
      seen_osc_ticks[tostring(value)] = wall_now_ms() or 0
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

  -- attention.tick.echo handler. File-transport sidecar emitted by
  -- emit-agent-status.sh whenever the primary `attention.tick` picked
  -- OSC, carrying the same `tick_ms` payload. Plays two roles:
  --
  --   1. Diagnostic: pair `tick received transport=osc value=$ms`
  --      against `tick echo received transport=file value=$ms` in
  --      wezterm.log to spot OSC drops (hook log + echo present + osc
  --      tick missing = drop on the OSC pipeline).
  --
  --   2. Fallback: when the primary OSC tick failed to arrive for
  --      `value`, this handler calls reload_state + refresh so the
  --      badge reflects the on-disk state within ~250ms of the hook
  --      firing, instead of sitting stale until the next unrelated
  --      tick happens to land. The `osc_dropped=1` field on the echo
  --      log line marks every fallback path so the diagnostic signal
  --      survives the behavioral change.
  --
  -- Done badges in particular were going invisible: Stop hooks routinely
  -- lose their OSC tick (claude-cli redraws around the hook fire), so
  -- the file echo is the only signal that actually reaches lua. Without
  -- the fallback the badge stays on `running` until the next tick from
  -- *some other session* drives a reload, by which point focus-ack
  -- usually archives the entry sub-frame.
  event_bus.on('attention.tick.echo', function(value, meta)
    local now = wall_now_ms()
    prune_seen_osc_ticks(now)
    local key = (value and value ~= '') and tostring(value) or nil
    local osc_seen = key and seen_osc_ticks[key] ~= nil
    if key then
      seen_osc_ticks[key] = nil
    end
    if not osc_seen and attention then
      if attention.reload_state then attention.reload_state() end
      if meta.window then
        refresh_right_status(meta.window, meta.pane)
        log_rendered_status(meta.window)
      end
    end
    if logger then
      local latency_ms = nil
      local tick_ms = tonumber(value)
      if tick_ms and now then
        latency_ms = now - tick_ms
      end
      logger.info('attention', 'tick echo received', {
        pane_id = meta.pane and meta.pane.pane_id and meta.pane:pane_id() or nil,
        value = value,
        latency_ms = latency_ms,
        transport = meta.transport,
        osc_dropped = (not osc_seen) and 1 or 0,
        fallback_reload = (not osc_seen) and 1 or 0,
      })
    end
  end)

  -- attention.jump handler. Fires on picker-driven jumps, currently
  -- always via the file transport because the picker runs inside a
  -- tmux popup whose DCS pass-through doesn't reach wezterm. Same
  -- in-process mux activate Alt+j/k/l use, plus a background spawn of
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

  -- link.quick_select — command-palette path for opening URLs. No default
  -- hotkey (Alt+l is attention.jump-running); Ctrl+Shift+P → Link fires
  -- scripts/runtime/link-quick-select.sh → file-transport event → here.
  event_bus.on('link.quick_select', function(_payload, meta)
    if not meta.window or not meta.pane then return end
    if not actions_mod or type(actions_mod.link_quick_select_action) ~= 'function' then
      if logger then
        logger.warn('link', 'quick_select missing actions helper', {
          transport = meta.transport,
        })
      end
      return
    end
    local action = actions_mod.link_quick_select_action(wezterm, logger)
    local ok, err = pcall(function()
      meta.window:perform_action(action, meta.pane)
    end)
    if logger then
      logger.info('link', 'quick_select dispatched', {
        transport = meta.transport,
        ok = ok,
        err = ok and nil or tostring(err),
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

  -- Bring the gui's foreground workspace to `workspace_name` when the
  -- cross-workspace Alt+x picker selects a row whose owning workspace
  -- isn't the one currently visible. Mux-side activate functions
  -- (`Workspace.activate_only`, `Workspace.activate_overflow`,
  -- `Workspace.spawn_or_activate`) already work for any workspace's
  -- mux window, but they don't repaint the gui — without this hop the
  -- user clicks a tab in workspace B and stays staring at workspace A.
  --
  -- Two cases:
  --   1. Target workspace already has a mux window — issue a bare
  --      `SwitchToWorkspace` so the gui follows. Cheap; wezterm
  --      short-circuits the no-op switch when active already matches.
  --   2. Target workspace has no mux window (snapshot exists from a
  --      prior run, but the workspace was never opened in this
  --      session) — drive the full `Workspace.open` so visible_count
  --      tabs + the overflow placeholder get spawned, and the gui
  --      switches as a side-effect of cold-open. Without this, the
  --      mux-side activate functions called by the per-event handler
  --      would return false (no window to operate on) and the user
  --      would see Alt+x close with nothing visible.
  local function ensure_workspace_foregrounded(workspace_name, trace_label)
    if not workspace_name or workspace_name == '' then return end
    local ok_gui, gui_windows = pcall(wezterm.gui.gui_windows)
    if not ok_gui or type(gui_windows) ~= 'table' or #gui_windows == 0 then
      return
    end
    local gui_window = gui_windows[1]
    if not gui_window then return end
    local active_ok, active = pcall(function() return gui_window:active_workspace() end)
    if active_ok and active == workspace_name then return end
    local pane_ok, pane = pcall(function() return gui_window:active_pane() end)
    if not pane_ok or not pane then return end

    local has_window = false
    local ok_all, all_windows = pcall(wezterm.mux.all_windows)
    if ok_all and type(all_windows) == 'table' then
      for _, mw in ipairs(all_windows) do
        local ok_ws, ws = pcall(function() return mw:get_workspace() end)
        if ok_ws and ws == workspace_name then
          has_window = true
          break
        end
      end
    end

    if has_window or not workspace_module or not workspace_module.open then
      pcall(function()
        gui_window:perform_action(
          wezterm.action.SwitchToWorkspace { name = workspace_name },
          pane)
      end)
    else
      pcall(function()
        workspace_module.open(gui_window, pane, workspace_name)
      end)
    end
    if logger then
      logger.info('tab_visibility', 'cross-workspace gui switch', {
        workspace = workspace_name,
        source = trace_label or 'tab.*',
        had_mux_window = has_window,
      })
    end
  end

  -- tab.activate_visible: Alt+x picker selected a session that already
  -- has a wezterm tab in its workspace. Just activate that tab.
  event_bus.on('tab.activate_visible', function(payload, meta)
    local fields = parse_tab_payload(payload)
    if not fields or not fields.workspace or not fields.cwd then return end
    if not workspace_module or not workspace_module.activate_only then return end
    ensure_workspace_foregrounded(fields.workspace, 'tab.activate_visible')
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
    ensure_workspace_foregrounded(fields.workspace, 'tab.activate_overflow')
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
      -- Capture the session this overflow slot was previously hosting,
      -- before any of the maps below get overwritten. wezterm tab is a
      -- slot — when the slot stops hosting `prev_session`, attention
      -- entries on that session lose their host and should be archived
      -- into recent[] right now (instead of dangling until TTL).
      local prev_session
      if found_pane_id and tab_visibility
         and type(tab_visibility.session_for_pane) == 'function' then
        prev_session = tab_visibility.session_for_pane(found_pane_id)
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
      -- Archive attention entries that were anchored to the old session.
      -- Skipped when prev == new (re-attaching the same session, e.g. on
      -- a redundant Alt+x or workspace re-activate).
      if prev_session and prev_session ~= '' and prev_session ~= fields.session
         and attention and type(attention.forget_by_tmux_session) == 'function' then
        attention.forget_by_tmux_session(prev_session)
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
    ensure_workspace_foregrounded(workspace_name, 'tab.spawn_overflow')
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
