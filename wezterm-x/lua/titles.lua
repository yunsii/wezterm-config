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
  local actions_mod = nil
  if constants then
    -- Lazy-load actions only when titles is wired with constants; the
    -- jump-trigger consumer in update-status needs it to build the
    -- wsl.exe-wrapped argv for `attention-jump.sh --direct` (the tmux
    -- side of a picker-driven jump).
    local ok, mod = pcall(load_module, 'ui/actions')
    if ok then actions_mod = mod end
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

  wezterm.on('update-status', function(window, pane)
    local overrides = window:get_config_overrides()
    if overrides and next(overrides) ~= nil then
      window:set_config_overrides({})
      return
    end

    local workspace = window:active_workspace() or 'default'
    window:set_left_status(format_workspace_label(workspace))

    -- update-status owns the periodic housekeeping: state reload, TTL
    -- prune scheduling, and focus-based auto-ack. The user-var-changed
    -- fast path skips these because the hook side already refreshed
    -- state.json and nothing in the prune / ack pipelines benefits from
    -- firing more often than once per tick.
    if attention and attention.reload_state then
      attention.reload_state()
    end
    if attention and attention.maybe_prune then
      attention.maybe_prune()
    end
    if attention and attention.maybe_ack_focused then
      attention.maybe_ack_focused(window, pane)
    end

    -- Picker-driven jump trigger. The picker drops a small JSON file
    -- with the parsed coords on Enter; we consume + dispatch here on
    -- the 250ms tick. Same in-process mux activate Alt+,/. use, just
    -- with a file as the IPC primitive instead of OSC (tmux popup
    -- DCS pass-through is unreliable, see attention.consume_jump_trigger).
    if attention and attention.consume_jump_trigger then
      local coords = attention.consume_jump_trigger()
      if coords then
        local activated = attention.activate_in_gui(coords.wezterm_pane, window, pane)
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
          local args = actions_mod.attention_jump_args(constants, pane, trailing, logger, nil)
          if args then
            pcall(wezterm.background_child_process, args)
          end
        end
        if logger then
          logger.info('attention', 'trigger jump dispatched', {
            kind         = coords.kind,
            session_id   = coords.session_id,
            archived_ts  = coords.archived_ts,
            wezterm_pane = coords.wezterm_pane,
            activated    = activated,
          })
        end
      end
    end

    refresh_right_status(window, pane)
    log_rendered_status(window)
  end)

  -- Fast path: the attention hook emits OSC 1337 SetUserVar=attention_tick
  -- after every state transition, and WezTerm delivers it here. Reload
  -- state and repaint the right-status segment immediately instead of
  -- waiting up to 250ms for the next update-status tick.
  --
  -- `value` is the hook-side `tick_ms` (epoch ms) decoded from base64 by
  -- WezTerm. `latency_ms` is the gap between the shell-side OSC emit and
  -- this Lua handler firing — i.e. WSL→tmux→wezterm OSC delivery latency
  -- (subject to WSL/Windows clock skew, so treat sub-100ms values as
  -- noise; the signal is when it spikes into seconds).
  wezterm.on('user-var-changed', function(window, pane, name, value)
    if not attention then
      return
    end
    if name == attention.USER_VAR_TICK then
      if attention.reload_state then
        attention.reload_state()
      end
      refresh_right_status(window, pane)
      log_rendered_status(window)
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
          pane_id = pane and pane.pane_id and pane:pane_id() or nil,
          value = value,
          latency_ms = latency_ms,
        })
      end
      return
    end
    -- Picker-driven jumps used to come through here as
    -- `attention_jump` user-vars, but tmux's `display-popup -E` does
    -- not forward DCS pass-through from the popup pty to the parent
    -- client tty, so the OSC route silently dropped its payloads. The
    -- live path is now a file trigger consumed by `update-status`
    -- above (see attention.consume_jump_trigger).
    end
  end)
end

return M
