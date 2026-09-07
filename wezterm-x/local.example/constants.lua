return {
  runtime_mode = 'hybrid-wsl',
  default_domain = 'WSL:your-distro-name',
  shell = {
    program = '/bin/zsh',
  },
  managed_cli = {
    ui_variant = 'light',
  },
  chrome_debug_browser = {
    -- Override executable if your browser binary is not on PATH.
    -- executable = 'google-chrome',
    -- Use a Windows path in hybrid-wsl and a local path in posix-local.
    user_data_dir = '/path/to/chrome-profile',
  },
  diagnostics = {
    wezterm = {
      enabled = true,
      level = 'info',
      max_bytes = 5242880,
      max_files = 5,
      debug_key_events = false,
      categories = {
        vscode = true,
        clipboard = true,
        command_panel = true,
        chrome = true,
        host_helper = true,
        workspace = true,
        tab_visibility = true,
        -- Slow key / status-tick events (threshold-gated). Keep enabled
        -- when using an allowlist, or those rows are filtered out.
        latency = true,
        -- Per-press audit (pressed + dispatched). Required when the
        -- allowlist is non-empty — otherwise "did this hotkey fire?"
        -- cannot be answered from wezterm.log.
        hotkey = true,
      },
      -- Thresholds for category=latency slow events. emit_all writes
      -- every sample under latency.perf (noisy at ~4 Hz status ticks).
      -- latency = {
      --   hotkey_slow_ms = 50,
      --   status_slow_ms = 40,
      --   emit_all = false,
      -- },
    },
  },
  -- Window look is chosen with WEZTERM_APPEARANCE_PRESET in shared.env
  -- ('opaque' | 'frosted'). The block below is OPTIONAL and only tunes the
  -- selected preset — it deep-merges over it. E.g. make the frosted preset a
  -- touch more solid, or force OpenGL if the default WebGpu renders opaque.
  -- Full model + gotchas: docs/appearance-presets.md.
  -- appearance = {
  --   window_background_opacity = 0.4,    -- lower = more see-through + more blur
  --   -- win32_system_backdrop = 'Mica',  -- override the preset's backdrop
  --   -- front_end = 'OpenGL',            -- escape hatch; NOT with acrylic
  --   -- macos_window_background_blur = 20,
  -- },
  -- palette = {                            -- override individual theme colors
  --   -- tab_active_bg = 'rgba(6,182,212,0.7)',   -- Tailwind cyan-500
  --   -- tab_active_fg = '#ffffff',
  --   -- Right-status counter + tab-badge colors. Shared with the disk /
  --   -- memory warning badges and the SB waiting state — see
  --   -- docs/agent-attention.md. Prefer Tailwind tokens:
  --   --   waiting amber-200/900/700, done green-200/900/700,
  --   --   running sky-200/900/700 (sky, not cyan — keep focus distinct).
  --   -- tab_attention_waiting_bg = '#fde68a',
  --   -- tab_attention_waiting_fg = '#78350f',
  --   -- `_glyph` tints only the counter's leading mark (▲ / ✓ / ●) so it
  --   -- separates from the label on the same block; omit it and the mark
  --   -- takes `_fg` like the label.
  --   -- tab_attention_waiting_glyph = '#b45309',
  --   -- tab_attention_done_glyph    = '#15803d',
  --   -- tab_attention_running_glyph = '#0369a1',
  -- },
  -- Right-status glyphs for the agent-attention counters. `''` drops the
  -- glyph and leaves a bare `2 waiting`. Does NOT move the Alt+/ and
  -- Alt+g pickers, which carry their own copy of the set.
  -- attention = {
  --   icons = { waiting = '▲', done = '✓', running = '●' },
  -- },
  -- Glyph on the session-bridge watch badge (`◆ SB·N`). `''` drops it.
  -- session_bridge_watch = {
  --   icon = '◆',
  -- },
  -- Frequency-driven tab layout. By default no workspace opts in, so
  -- existing tab bars behave identically. Enabled workspaces get
  -- slot-aware tab titles where each tab inside the visible_count window
  -- shows the top-N session by recent focus frequency, with a sticky
  -- slot algorithm so positions stay stable when ranks shuffle inside
  -- the top-N. Schema + algorithm: docs/tab-visibility.md.
  -- tab_visibility = {
  --   visible_count = 5,    -- per-machine overrides
  --   warm_count = 3,
  --   half_life_days = 7,
  --   access_weight = 60,   -- visit bonus mixed into sticky rank_score
  --   spawn_visible_only = true,
  -- },
}
