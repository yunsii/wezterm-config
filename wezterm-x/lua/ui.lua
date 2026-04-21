local M = {}
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local function current_runtime_dir(config_dir)
  local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
  if runtime_dir and runtime_dir ~= '' then
    return runtime_dir
  end

  return join_path(config_dir, '.wezterm-x')
end

local function load_ui_module(runtime_dir, name)
  return dofile(join_path(runtime_dir, 'lua', 'ui', name .. '.lua'))
end

function M.apply(opts)
  local wezterm = opts.wezterm
  local config = opts.config
  local constants = opts.constants
  local palette = constants.palette
  local workspace = opts.workspace
  local runtime_dir = current_runtime_dir(wezterm.config_dir)
  local runtime = load_ui_module(runtime_dir, 'runtime')
  local keymaps = load_ui_module(runtime_dir, 'keymaps')
  local logger = opts.logger
  local host = opts.host
  local helper_prewarm_started = false

  if constants.runtime_mode == 'hybrid-wsl' and constants.host_os == 'windows' then
    wezterm.on('gui-startup', function()
      if helper_prewarm_started then
        return
      end

      helper_prewarm_started = true
      logger.info('host_helper', 'prewarming windows helper in background', {
        reason = 'gui-startup',
      })

      local ensured, ensure_reason = host:ensure_running('gui-startup-prewarm', false)
      if ensured then
        return
      end

      logger.warn('host_helper', 'background prewarm for windows helper failed', {
        reason = 'gui-startup',
        ensure_reason = ensure_reason,
      })
    end)
  end

  config.font = constants.fonts.terminal
  config.font_size = 12.0
  config.line_height = 1.0
  config.front_end = 'WebGpu'
  if constants.default_domain and constants.default_domain ~= '' then
    config.default_domain = constants.default_domain
  end

  local default_program = runtime.default_wsl_tmux_program(constants)
  if default_program then
    config.default_prog = default_program
  end

  local wsl_domains = runtime.configured_wsl_domains(wezterm, constants)
  if wsl_domains then
    config.wsl_domains = wsl_domains
  end

  config.notification_handling = 'NeverShow'
  config.audible_bell = 'Disabled'
  config.visual_bell = { fade_in_duration_ms = 0, fade_out_duration_ms = 0 }
  -- Park mouse-reporting bypass on a rarely used modifier; pane-local selection
  -- should stay tmux-owned instead of exposing a terminal-wide drag path.
  config.bypass_mouse_reporting_modifiers = 'SUPER'
  -- Let focus clicks pass through so tmux/TUIs receive the first click too.
  config.swallow_mouse_click_on_window_focus = false
  config.swallow_mouse_click_on_pane_focus = false
  config.launch_menu = constants.launch_menu or {}
  local set_environment_variables = {
    COLORFGBG = '0;15',
    WEZTERM_RUNTIME_MODE = constants.runtime_mode or 'hybrid-wsl',
  }
  if constants.shell and constants.shell.program and constants.shell.program ~= '' then
    set_environment_variables.WEZTERM_MANAGED_SHELL = constants.shell.program
  end
  config.set_environment_variables = set_environment_variables

  config.window_decorations = 'RESIZE'
  config.window_padding = {
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
  }
  config.use_fancy_tab_bar = false
  config.enable_tab_bar = true
  config.show_tabs_in_tab_bar = true
  config.tab_bar_at_bottom = true
  config.tab_max_width = 24
  config.show_new_tab_button_in_tab_bar = true
  config.colors = {
    foreground = palette.foreground,
    background = palette.background,
    cursor_bg = palette.cursor_bg,
    cursor_fg = palette.cursor_fg,
    cursor_border = palette.cursor_border,
    selection_bg = palette.selection_bg,
    selection_fg = palette.selection_fg,
    scrollbar_thumb = palette.scrollbar_thumb,
    split = palette.split,
    ansi = palette.ansi,
    brights = palette.brights,
    tab_bar = {
      background = palette.tab_bar_background,
      inactive_tab_edge = palette.tab_bar_background,
      active_tab = {
        bg_color = palette.tab_active_bg,
        fg_color = palette.tab_active_fg,
      },
      inactive_tab = {
        bg_color = palette.tab_inactive_bg,
        fg_color = palette.tab_inactive_fg,
      },
      inactive_tab_hover = {
        bg_color = palette.tab_hover_bg,
        fg_color = palette.tab_hover_fg,
      },
      new_tab = {
        bg_color = palette.new_tab_bg,
        fg_color = palette.new_tab_fg,
      },
      new_tab_hover = {
        bg_color = palette.new_tab_hover_bg,
        fg_color = palette.new_tab_hover_fg,
      },
    },
  }
  config.window_frame = {
    font = constants.fonts.window,
    font_size = 10.0,
    active_titlebar_bg = palette.tab_bar_background,
    inactive_titlebar_bg = palette.tab_bar_background,
  }
  config.command_palette_bg_color = palette.background
  config.command_palette_fg_color = palette.foreground

  config.keys = keymaps.build {
    wezterm = wezterm,
    workspace = workspace,
    constants = constants,
    logger = logger,
    host = host,
  }

  config.mouse_bindings = {
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = wezterm.action.OpenLinkAtMouseCursor,
    },
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      action = wezterm.action.Nop,
    },
    {
      event = { Up = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      mouse_reporting = true,
      action = wezterm.action.OpenLinkAtMouseCursor,
    },
    {
      event = { Down = { streak = 1, button = 'Left' } },
      mods = 'CTRL',
      mouse_reporting = true,
      action = wezterm.action.Nop,
    },
  }

  config.default_cursor_style = 'BlinkingBlock'
  config.cursor_blink_rate = 600
  config.use_ime = true
  config.ime_preedit_rendering = 'Builtin'
  config.cell_width = 1.0
  config.status_update_interval = 250
end

return M
