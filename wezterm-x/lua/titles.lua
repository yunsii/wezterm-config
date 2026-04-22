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
  local host = opts.host
  local logger = opts.logger
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
      local badge_bg, badge_fg = attention.badge_colors(palette, badge.status)
      table.insert(segments, { Background = { Color = badge_bg } })
      table.insert(segments, { Foreground = { Color = badge_fg } })
      table.insert(segments, { Attribute = { Intensity = 'Bold' } })
      table.insert(segments, { Text = ' ' .. badge.marker .. ' ' })
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

  wezterm.on('update-status', function(window, pane)
    local overrides = window:get_config_overrides()
    if overrides and next(overrides) ~= nil then
      window:set_config_overrides({})
      return
    end

    local workspace = window:active_workspace() or 'default'
    window:set_left_status(format_workspace_label(workspace))

    local right_segments = {}
    local ime_segment = render_ime_segment()
    if ime_segment then
      table.insert(right_segments, ime_segment)
    end
    if attention and attention.reload_state then
      attention.reload_state()
    end
    if attention and attention.maybe_prune then
      attention.maybe_prune()
    end
    if attention and attention.maybe_ack_focused then
      attention.maybe_ack_focused(window, pane)
    end
    local attention_waiting, attention_done
    if attention then
      attention_waiting, attention_done = attention.collect()
    end
    local attention_segment = attention and attention.render_status_segment(palette) or nil
    if attention_segment then
      table.insert(right_segments, attention_segment)
    end
    window:set_right_status(table.concat(right_segments, ' '))

    if logger and attention then
      local waiting_count = attention_waiting and #attention_waiting or 0
      local done_count = attention_done and #attention_done or 0
      local signature = waiting_count == 0 and done_count == 0
          and 'empty'
        or string.format('w=%d,d=%d', waiting_count, done_count)
      if last_rendered_status ~= signature then
        last_rendered_status = signature
        logger.info('attention', 'render_status', {
          waiting = waiting_count,
          done = done_count,
          window_id = window:window_id(),
        })
      end
    end
  end)
end

return M
