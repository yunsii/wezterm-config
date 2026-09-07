local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end


local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR')
if not runtime_dir or runtime_dir == '' then
  runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')
end
local runtime_state_dir = rawget(_G, 'WEZTERM_RUNTIME_STATE_DIR')

local helpers = dofile(join_path(runtime_dir, 'lua', 'helpers.lua'))
local defaults = dofile(join_path(runtime_dir, 'lua', 'config', 'defaults.lua'))
local managed_cli = dofile(join_path(runtime_dir, 'lua', 'config', 'managed_cli.lua'))
local appearance_presets = dofile(join_path(runtime_dir, 'lua', 'config', 'appearance-presets.lua'))

local host_os = defaults.detect_host_os(wezterm)
if not runtime_state_dir or runtime_state_dir == '' then
  runtime_state_dir = defaults.default_runtime_state_dir(host_os, join_path, wezterm)
end

local local_constants = helpers.load_optional_table(join_path(runtime_dir, 'local', 'constants.lua')) or {}
local shared_env = helpers.load_optional_env_file(join_path(runtime_dir, 'local', 'shared.env')) or {}
local repo_root_override = defaults.read_repo_root_override(runtime_dir, join_path)
-- Prefer the runtime-local copy (sync writes it next to repo-root.txt).
-- The repo_root_override path is a WSL-native path; Windows-side
-- wezterm.exe can't `io.open` it, so without the local copy the env
-- file's profile registrations (including `<base>_resume`) silently
-- vanish on the Windows leg of hybrid-wsl mode.
local repo_worktree_task_env = helpers.load_optional_env_file(join_path(runtime_dir, 'repo-worktree-task.env'))
  or (repo_root_override and (
    helpers.load_optional_env_file(join_path(repo_root_override, 'config', 'worktree-task.env'))
    or helpers.load_optional_env_file(join_path(repo_root_override, '.worktree-task', 'config.env'))
  )) or {}
local user_worktree_task_env = helpers.load_optional_env_file(defaults.default_worktree_task_user_config_path(join_path) or '') or {}
local repo_managed_cli_env = managed_cli.parse_managed_cli_env(repo_worktree_task_env, { wezterm_repo = repo_root_override })
local user_managed_cli_env = managed_cli.parse_managed_cli_env(user_worktree_task_env, { wezterm_repo = repo_root_override })
local local_managed_cli_profile = managed_cli.normalize_agent_profile_name(shared_env.MANAGED_AGENT_PROFILE)

local function vscode_command(base)
  local out = {}
  for _, v in ipairs(base) do
    out[#out + 1] = v
  end
  local profile = shared_env.WEZTERM_VSCODE_PROFILE
  if profile and profile ~= '' then
    out[#out + 1] = '--profile'
    out[#out + 1] = profile
  end
  return out
end

local function positive_integer_env(value)
  local number = tonumber(value)
  if not number or number < 1 then
    return nil
  end

  return math.floor(number)
end

local base_constants = {
  host_os = host_os,
  runtime_mode = defaults.default_runtime_mode(host_os),
  repo_root = nil,
  main_repo_root = nil,
  default_domain = nil,
  shell = {
    program = nil,
  },
  fonts = {
    terminal = defaults.default_terminal_font(wezterm, host_os),
    window = defaults.default_window_font(wezterm, host_os),
  },
  palette = {
    background = '#f1f0e9',
    foreground = '#393a34',
    cursor_bg = '#8c6c3e',
    cursor_fg = '#f8f5ee',
    cursor_border = '#8c6c3e',
    selection_bg = '#e6e0d4',
    selection_fg = '#2f302c',
    scrollbar_thumb = '#d8d3c9',
    split = '#e3ded3',
    ansi = {
      '#393a34',
      '#ab5959',
      '#5f8f62',
      '#b07d48',
      '#4d699b',
      '#7e5d99',
      '#4c8b8b',
      '#d7d1c6',
    },
    brights = {
      '#6f706a',
      '#c96b6b',
      '#73a56e',
      '#c7925b',
      '#6b86b7',
      '#9a79b4',
      '#68a5a5',
      '#f6f3eb',
    },
    indexed = {
      [255] = '#dedcd0',
    },
    tab_bar_background = '#f1f0e9',
    tab_inactive_bg = '#f1f0e9',
    tab_inactive_fg = '#6f685f',
    tab_hover_bg = '#e2dbcd',
    tab_hover_fg = '#2f302c',
    -- Focus tab: Tailwind cyan-500 selected chip + white text.
    -- Palette source: https://tailwindcss.com/docs/colors
    tab_active_bg = '#06b6d4', -- cyan-500
    tab_active_fg = '#ffffff', -- white
    new_tab_bg = '#f1f0e9',
    new_tab_fg = '#908b83',
    new_tab_hover_bg = '#e2dbcd',
    new_tab_hover_fg = '#2f302c',
    tab_edge = '#ddd8cd',
    tab_accent = '#b07d48',
    -- ── Agent-attention status colors ──────────────────────────────
    -- Sourced from the Tailwind default palette so focus / status hues
    -- stay on one system. Weight is carried by shade, not hand-mixed
    -- OKLCh ladders:
    --
    --   role            | tokens                         | job
    --   focus           | cyan-500 / white               | where I am
    --   waiting (soft)  | amber-200 / amber-900 / -700   | needs you
    --   done (soft)     | green-200 / green-900 / -700   | finished
    --   running (quiet) | sky-200 / sky-900 / sky-700    | in flight
    --
    -- Running uses sky (not cyan) so mid-turn tabs cannot be mistaken
    -- for the focused cyan-500 chip. Soft *-200 fills stay below the
    -- saturated *-500 focus block. Hexes are the published Tailwind v3
    -- defaults.
    --
    -- Retuning: pick another Tailwind token of the same role weight
    -- (e.g. focus → cyan-600, waiting → amber-300). Do not hand-mix a
    -- single channel. Rationale: docs/agent-attention.md.
    tab_attention_waiting_bg = '#fde68a', -- amber-200
    tab_attention_waiting_fg = '#78350f', -- amber-900
    tab_attention_waiting_glyph = '#b45309', -- amber-700
    tab_attention_done_bg = '#bbf7d0', -- green-200
    tab_attention_done_fg = '#14532d', -- green-900
    tab_attention_done_glyph = '#15803d', -- green-700
    tab_attention_running_bg = '#bae6fd', -- sky-200
    tab_attention_running_fg = '#0c4a6e', -- sky-900
    tab_attention_running_glyph = '#0369a1', -- sky-700
    -- Host-disk badge at crit. Deliberately outside the Tailwind attention
    -- tokens above: it is not an agent status, and "the disk is about to
    -- stop the machine" must never read as "an agent is waiting on you".
    -- disk_status.lua falls back to the amber pair when a preset palette
    -- omits these.
    disk_crit_bg = '#b4574b',
    disk_crit_fg = '#fbf1ef',
    ime_native_bg = '#6b86b7',
    ime_native_fg = '#f8f5ee',
    ime_alpha_bg = '#dbc39e',
    ime_alpha_fg = '#614321',
    ime_en_fg = '#908b83',
    ime_unknown_fg = '#908b83',
    -- ── Workspace identity badges ──────────────────────────────────
    -- Still OKLCh (not Tailwind): these answer workspace identity, not
    -- agent urgency, and stay quieter than the Tailwind *-200 status
    -- washes. Role fixes L/C; the workspace only picks a hue:
    --
    --   role | L    | C
    --   bg   | 0.88 | 0.030
    --   fg   | 0.40 | 0.050
    --
    --   workspace | hue
    --   default   |  85°  near-neutral, see below
    --   managed   |  45°  warm terracotta
    --   work      | 100°  golden olive
    --   config    | 262°  blue
    --
    -- `default` is the deliberate exception: it drops to C 0.010 (fg
    -- 0.018) so the unnamed workspace reads as grey. Colorless is the
    -- honest signal for "no identity", and at C 0.030 its hue would land
    -- within 5° of `work` — the two badges came out as the same beige.
    --
    -- The hues are spread on purpose. Before this ladder (2026-08-19)
    -- `default`, `managed` and `work` all sat between 78° and 85° and
    -- were told apart only by weight: `work` was 0.077 darker and 3.3x
    -- more saturated than `default`. Equalising L without moving the
    -- hues would have collapsed the three into one color.
    --
    -- Unknown workspaces fall back to `managed` (titles.lua
    -- workspace_badge_style), so that slot is also "every other
    -- workspace" — keep it distinguishable from the three named ones.
    workspace_badges = {
      default = {
        bg = '#dad7d0',
        fg = '#4c473d',
      },
      managed = {
        bg = '#e9d2c8',
        fg = '#5f3f31',
      },
      work = {
        bg = '#dcd8c2',
        fg = '#4e4828',
      },
      config = {
        bg = '#cdd8ec',
        fg = '#394863',
      },
    },
  },
  -- Window frosted-glass / transparency. Defaults keep an opaque window
  -- (no-op), so machines without an override render exactly as before.
  -- Applied in lua/ui.lua; override per-machine in
  -- wezterm-x/local/constants.lua. See docs/setup.md.
  appearance = {
    window_background_opacity = 1.0,
    text_background_opacity = 1.0,
    win32_system_backdrop = nil,        -- Windows 11: 'Acrylic' | 'Mica' | 'Tabbed'
    macos_window_background_blur = nil, -- macOS: integer blur radius, e.g. 20
    -- Some Windows GPUs render the default WebGpu front_end to an opaque
    -- swapchain, which kills window_background_opacity. Set 'OpenGL' there.
    front_end = nil,                    -- 'OpenGL' | 'WebGpu' | 'Software'
  },
  launch_menu = defaults.default_launch_menu(host_os),
  integrations = {
    vscode = {
      hybrid_wsl_command = vscode_command(defaults.default_vscode_command(host_os)),
      posix_command = vscode_command({ 'code' }),
      max_windows = positive_integer_env(shared_env.WEZTERM_VSCODE_MAX_WINDOWS),
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
      helper_script = 'scripts\\ensure-windows-runtime-helper.ps1',
      helper_client_exe = defaults.default_windows_runtime_helper_client_path(host_os, runtime_state_dir, join_path),
      helper_log_file = defaults.default_windows_helper_diagnostics_file(host_os, runtime_state_dir, join_path),
      helper_ipc_endpoint = defaults.default_windows_runtime_helper_ipc_endpoint(host_os),
      helper_state_path = defaults.default_windows_runtime_helper_state_path(host_os, runtime_state_dir, join_path),
      helper_request_timeout_ms = 5000,
      helper_heartbeat_timeout_seconds = 5,
      helper_heartbeat_interval_ms = 250,
      posix_shell = '/bin/bash',
      posix_script = wezterm.config_dir .. '/scripts/runtime/open-current-dir-in-vscode.sh',
    },
    chrome_debug = {
      cmd = 'cmd.exe',
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
    },
    clipboard_image = {
      powershell = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe',
      runtime_dir = runtime_dir,
      output_dir = defaults.default_clipboard_image_output_dir(host_os, runtime_state_dir, join_path),
      image_read_retry_count = 12,
      image_read_retry_delay_ms = 100,
      cleanup_max_age_hours = 48,
      cleanup_max_files = 32,
    },
  },
  managed_cli = {
    default_profile = 'claude',
    ui_variant = 'light',
    -- Profile commands below are bare fallbacks used only when no worktree-task
    -- env file populates them; the tracked source of truth for day-to-day
    -- auto-resume behavior lives in `config/worktree-task.env`.
    profiles = {
      claude = {
        command = { 'claude' },
        variants = {},
      },
      codex = {
        command = { 'codex' },
        variants = {
          light = { 'codex' },
          dark = { 'codex' },
        },
      },
    },
  },
  chrome_debug_browser = {
    executable = defaults.default_chrome_debug_executable(host_os),
    remote_debugging_port = 9222,
    user_data_dir = nil,
    headless = true,
    state_file = defaults.default_chrome_debug_state_file(runtime_state_dir, join_path),
  },
  -- Ctrl+K w session-bridge watch-loop badge (right-status between CDP and attention).
  session_bridge_watch = {
    status_file = defaults.default_session_bridge_watch_status_file(runtime_state_dir, join_path),
    heartbeat_timeout_ms = 35000,
    -- Same glyph the Alt+/ picker stamps on session-bridge watch rows.
    -- `''` drops it and leaves the bare `SB·N`.
    icon = '◆',
  },
  -- Host-disk badge (right-status, after SB). Producer is the
  -- wezterm-disk-guard systemd user timer; 13 min tolerates two missed
  -- 5 min samples before the badge admits it is stale.
  disk_guard = {
    status_file = defaults.default_disk_guard_status_file(runtime_state_dir, join_path),
    heartbeat_timeout_ms = 780000,
  },
  -- Guest memory-pressure badge (right-status, after D·). Producer is the
  -- wezterm-oom-record system unit, which republishes every 30 s; 90 s
  -- tolerates two missed writes before the badge admits it is stale.
  mem_guard = {
    status_file = defaults.default_mem_guard_status_file(runtime_state_dir, join_path),
    heartbeat_timeout_ms = 90000,
  },
  wakatime = {
    api_key = nil,
  },
  diagnostics = {
    wezterm = {
      enabled = true,
      level = 'info',
      file = defaults.default_diagnostics_file(runtime_state_dir, join_path),
      max_bytes = 5242880,
      max_files = 5,
      debug_key_events = false,
      categories = {},
      -- Key / status-tick latency. Slow events (duration >= threshold)
      -- land in category `latency` by default. Set emit_all = true to
      -- also write every sample under `latency.perf` (noisy at 4 Hz).
      -- See docs/diagnostics.md "Key / status latency".
      latency = {
        hotkey_slow_ms = 50,
        status_slow_ms = 40,
        emit_all = false,
      },
    },
  },
  attention = {
    state_file = defaults.default_attention_state_file(runtime_state_dir, join_path),
    live_panes_file = defaults.default_attention_live_panes_file(runtime_state_dir, join_path),
    -- Right-status counter glyphs. Monochrome 1-cell text code points by
    -- default so the segment sits with the typographic badges around it
    -- (`CDP·…`, `D·151G`, `M·88%`) instead of reading as a sticker; the
    -- rationale and the matching picker set live in
    -- docs/agent-attention.md. Override per machine in
    -- wezterm-x/local/constants.lua; `''` drops the glyph and leaves the
    -- bare `N waiting` counter. The tab-strip badge is deliberately not
    -- covered here — it is a color block with no glyph vocabulary.
    -- Changing these does NOT move the Alt+/ and Alt+g pickers, which
    -- carry their own copy of the set (native/picker/cmd_attention.go).
    icons = {
      waiting = '▲',
      done = '✓',
      running = '●',
    },
  },
  tab_visibility = {
    -- Per-workspace stats files written by scripts/runtime/tab-stats-bump.sh.
    -- The lua module reads <stats_dir>/<workspace_slug>.json on each
    -- recompute (throttled to recompute_interval_ms).
    stats_dir = defaults.default_tab_stats_dir(runtime_state_dir, join_path),
    visible_count = 5,
    warm_count = 3,
    half_life_days = 7,
    -- Decayed access-ledger visit bonus mixed into sticky rank_score.
    -- Between index(+40) and HEAD(+100); see docs/tab-visibility.md.
    access_weight = 60,
    recompute_interval_ms = 5000,
    activity_sample_interval_ms = 60000,
    swap_flash_ms = 800,
    -- Limit startup spawn to visible_count tabs (cold-start fallback to
    -- the workspaces.lua first-N order). Default false because the
    -- companion `Alt+t` overflow picker — the only way to reach
    -- unspawned sessions on demand — has not landed yet. Flipping this
    -- on without the picker would strand sessions beyond visible_count.
    -- Schema rationale + roadmap: docs/tab-visibility.md.
    spawn_visible_only = false,
  },
  wezterm_event_bus = {
    event_dir = defaults.default_wezterm_event_dir(runtime_state_dir, join_path),
  },
}

-- Appearance preset: selected by WEZTERM_APPEARANCE_PRESET (shared.env),
-- layered as base <- preset <- local so a machine can still override single
-- values in local/constants.lua. The tmux side of the same preset is rendered
-- by scripts/runtime/render-tmux-appearance.sh. See docs/appearance-presets.md.
local preset, preset_name = appearance_presets.resolve(shared_env.WEZTERM_APPEARANCE_PRESET)
local with_preset = helpers.deep_merge(base_constants, {
  appearance = preset.appearance,
  palette = preset.palette,
})
local constants = helpers.deep_merge(with_preset, local_constants)
constants.appearance_preset = preset_name
constants.managed_cli = constants.managed_cli or {}
constants.managed_cli.profiles = helpers.deep_merge(constants.managed_cli.profiles or {}, repo_managed_cli_env.profiles or {})
constants.managed_cli.profiles = helpers.deep_merge(constants.managed_cli.profiles or {}, user_managed_cli_env.profiles or {})
if repo_managed_cli_env.active_profile then
  constants.managed_cli.default_profile = repo_managed_cli_env.active_profile
end
if user_managed_cli_env.active_profile then
  constants.managed_cli.default_profile = user_managed_cli_env.active_profile
end
if local_managed_cli_profile then
  constants.managed_cli.default_profile = local_managed_cli_profile
end
do
  -- The env parser at lua/config/managed_cli.lua normalizes
  -- `WT_PROVIDER_AGENT_PROFILE_<X>_RESUME_COMMAND` profile names by
  -- mapping non-alphanum to `_`, so the registered key for the resume
  -- variant is `<base>_resume` (underscore). Shell-side code reads
  -- env vars directly and uses the literal `<base>-resume` form;
  -- those paths don't go through this resolver.
  local base = constants.managed_cli.default_profile
  local profiles = constants.managed_cli.profiles or {}
  if base and base ~= '' and profiles[base .. '_resume'] then
    constants.managed_cli.default_resume_profile = base .. '_resume'
  else
    constants.managed_cli.default_resume_profile = base
  end
end
if shared_env.WAKATIME_API_KEY and shared_env.WAKATIME_API_KEY ~= '' then
  constants.wakatime = constants.wakatime or {}
  constants.wakatime.api_key = shared_env.WAKATIME_API_KEY
end
constants.repo_root = repo_root_override or constants.repo_root
constants.main_repo_root = defaults.read_main_repo_root_override(runtime_dir, join_path) or constants.main_repo_root or constants.repo_root

return constants
