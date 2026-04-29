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
local repo_managed_cli_env = managed_cli.parse_managed_cli_env(repo_worktree_task_env)
local user_managed_cli_env = managed_cli.parse_managed_cli_env(user_worktree_task_env)
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
    tab_active_bg = '#d2c5ae',
    tab_active_fg = '#221f1a',
    new_tab_bg = '#f1f0e9',
    new_tab_fg = '#908b83',
    new_tab_hover_bg = '#e2dbcd',
    new_tab_hover_fg = '#2f302c',
    tab_edge = '#ddd8cd',
    tab_accent = '#b07d48',
    tab_attention_waiting_bg = '#c7925b',
    tab_attention_waiting_fg = '#1f1a11',
    tab_attention_running_bg = '#a5bbd4',
    tab_attention_running_fg = '#1b2534',
    tab_attention_done_bg = '#a7c89b',
    tab_attention_done_fg = '#1e2a1c',
    ime_native_bg = '#6b86b7',
    ime_native_fg = '#f8f5ee',
    ime_alpha_bg = '#dbc39e',
    ime_alpha_fg = '#614321',
    ime_en_fg = '#908b83',
    ime_unknown_fg = '#908b83',
    workspace_badges = {
      default = {
        bg = '#e5dfd3',
        fg = '#5f5a52',
      },
      managed = {
        bg = '#ddd0bb',
        fg = '#614321',
      },
      work = {
        bg = '#dbc39e',
        fg = '#4f3516',
      },
      config = {
        bg = '#d7dfed',
        fg = '#294267',
      },
    },
  },
  launch_menu = defaults.default_launch_menu(host_os),
  integrations = {
    vscode = {
      hybrid_wsl_command = vscode_command(defaults.default_vscode_command(host_os)),
      posix_command = vscode_command({ 'code' }),
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
          light = { 'codex', '-c', 'tui.theme="github"' },
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
    },
  },
  attention = {
    state_file = defaults.default_attention_state_file(runtime_state_dir, join_path),
    live_panes_file = defaults.default_attention_live_panes_file(runtime_state_dir, join_path),
  },
  tab_visibility = {
    -- Per-workspace stats files written by scripts/runtime/tab-stats-bump.sh.
    -- The lua module reads <stats_dir>/<workspace_slug>.json on each
    -- recompute (throttled to recompute_interval_ms).
    stats_dir = defaults.default_tab_stats_dir(runtime_state_dir, join_path),
    visible_count = 5,
    warm_count = 3,
    half_life_days = 7,
    recompute_interval_ms = 5000,
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

local constants = helpers.deep_merge(base_constants, local_constants)
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
