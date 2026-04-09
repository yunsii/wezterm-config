local wezterm = require 'wezterm'
local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local runtime_dir = join_path(wezterm.config_dir, '.wezterm-x')

local function load_module(name)
  return dofile(join_path(runtime_dir, 'lua', name .. '.lua'))
end

local helpers = load_module 'helpers'

local M = {}

function M.new(opts)
  local wezterm = opts.wezterm
  local mux = wezterm.mux
  local config = opts.config
  local constants = opts.constants
  local workspace_defs = dofile(join_path(runtime_dir, 'workspaces.lua'))
  local logger = load_module('logger').new {
    wezterm = wezterm,
    constants = constants,
  }

  local Workspace = {}

  local function with_trace_id(trace_id, fields)
    local merged = {}

    for key, value in pairs(fields or {}) do
      merged[key] = value
    end
    if trace_id and trace_id ~= '' then
      merged.trace_id = trace_id
    end

    return merged
  end

  local function runtime_script_roots()
    local roots = {}
    local seen = {}

    for _, root in ipairs {
      constants.repo_root,
      constants.main_repo_root,
    } do
      if root and root ~= '' and not seen[root] then
        roots[#roots + 1] = root
        seen[root] = true
      end
    end

    return roots
  end

  local function runtime_script_command(script_rel_path, script_args, opts)
    opts = opts or {}
    local roots = runtime_script_roots()
    local primary_script = roots[1] and (roots[1] .. '/' .. script_rel_path) or ''
    local fallback_script = roots[2] and (roots[2] .. '/' .. script_rel_path) or ''
    local trace_id = opts.trace_id or ''
    local command = {
      '/bin/sh',
      '-lc',
      [[
primary_script="$1"
fallback_script="$2"
trace_id="$3"
shift 3

run_script() {
  script_path="$1"
  shift

  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    if [ -n "$trace_id" ]; then
      exec env WEZTERM_RUNTIME_TRACE_ID="$trace_id" bash "$script_path" "$@"
    fi
    exec bash "$script_path" "$@"
  fi
}

run_script "$primary_script" "$@"
run_script "$fallback_script" "$@"

printf 'Managed workspace runtime script is unavailable: %s\n' "$primary_script" >&2
if [ -n "$fallback_script" ]; then
  printf 'Fallback runtime script is unavailable: %s\n' "$fallback_script" >&2
fi
exit 1
      ]],
      'sh',
      primary_script,
      fallback_script,
      trace_id,
    }

    for _, value in ipairs(script_args or {}) do
      command[#command + 1] = value
    end

    return command
  end

  local function managed_workspace_prereq_error()
    if #runtime_script_roots() == 0 then
      return 'Managed workspaces require a synced repo root. Run the wezterm-runtime-sync skill first.'
    end

    if constants.runtime_mode == 'hybrid-wsl' and (not config.default_domain or config.default_domain == '') then
      return 'Managed workspaces require default_domain in wezterm-x/local/constants.lua.'
    end

    return nil
  end

  local function managed_launcher_command(profile_name, trace_id)
    if not profile_name or profile_name == '' then
      return nil
    end

    if #runtime_script_roots() == 0 then
      return nil, 'Managed launcher "' .. profile_name .. '" requires a synced repo root.'
    end

    local managed_cli = constants.managed_cli or {}
    local profiles = managed_cli.profiles or {}
    local profile = profiles[profile_name]
    if not profile then
      return nil, 'Unknown managed launcher profile: ' .. profile_name
    end

    local variant = managed_cli.ui_variant or 'light'
    local command = helpers.copy_array(profile.command)
    if profile.variants and profile.variants[variant] then
      command = helpers.copy_array(profile.variants[variant])
    end

    if not command or #command == 0 then
      return nil, 'Managed launcher profile has no command: ' .. profile_name
    end

    local wrapped = runtime_script_command('scripts/runtime/run-managed-command.sh', nil, {
      trace_id = trace_id,
    })

    for _, part in ipairs(command) do
      wrapped[#wrapped + 1] = part
    end

    return wrapped
  end

  local function workspace_items(name)
    local raw = workspace_defs[name]
    if not raw then
      return {}
    end

    local defaults = raw.defaults or {}
    local source_items = raw.items or raw
    local items = {}

    for _, item in ipairs(source_items) do
      local normalized = type(item) == 'string' and { cwd = item } or { cwd = item.cwd }

      if normalized.cwd then
        local raw_command = item.command or defaults.command
        local launcher = item.launcher or defaults.launcher

        normalized.command = helpers.copy_array(raw_command)
        normalized.launcher = launcher

        if not normalized.command and launcher then
          normalized.command, normalized.command_error = managed_launcher_command(launcher)
        end

        items[#items + 1] = normalized
      end
    end

    return items
  end

  local function project_session_args(workspace_name, item, trace_id)
    local launch_command = nil

    if item.launcher then
      launch_command = managed_launcher_command(item.launcher, trace_id)
    else
      launch_command = item.command or {}
    end

    local session_command = runtime_script_command('scripts/runtime/open-project-session.sh', {
      workspace_name,
      item.cwd,
    }, {
      trace_id = trace_id,
    })

    for _, part in ipairs(launch_command or {}) do
      session_command[#session_command + 1] = part
    end

    return session_command
  end

  local function workspace_windows(name)
    local windows = {}

    for _, mux_window in ipairs(mux.all_windows()) do
      if mux_window:get_workspace() == name then
        windows[#windows + 1] = mux_window
      end
    end

    table.sort(windows, function(a, b)
      return a:window_id() < b:window_id()
    end)

    return windows
  end

  local function workspace_pane_ids(name)
    local pane_ids = {}
    local seen = {}

    for _, mux_window in ipairs(workspace_windows(name)) do
      for _, tab in ipairs(mux_window:tabs()) do
        for _, pane_info in ipairs(tab:panes_with_info()) do
          local pane = pane_info.pane
          local pane_id = pane and pane:pane_id()
          if pane_id and not seen[pane_id] then
            pane_ids[#pane_ids + 1] = pane_id
            seen[pane_id] = true
          end
        end
      end
    end

    return pane_ids
  end

  local function tab_pane_ids(tab)
    local pane_ids = {}
    local seen = {}

    if not tab then
      return pane_ids
    end

    for _, pane_info in ipairs(tab:panes_with_info()) do
      local pane = pane_info.pane
      local pane_id = pane and pane:pane_id()
      if pane_id and not seen[pane_id] then
        pane_ids[#pane_ids + 1] = pane_id
        seen[pane_id] = true
      end
    end

    return pane_ids
  end

  local function tab_path(tab)
    local pane = tab and tab:active_pane()
    return pane and helpers.cwd_to_path(pane:get_current_working_dir()) or nil
  end

  local function project_tab_title(item)
    return item and item.cwd and helpers.basename(item.cwd) or nil
  end

  local function set_project_tab_title(tab, item)
    local title = project_tab_title(item)
    if tab and title then
      tab:set_title(title)
    end
  end

  local function tab_matches_item(tab, item)
    if not tab or not item then
      return false
    end

    return tab:get_title() == project_tab_title(item) or tab_path(tab) == item.cwd
  end

  local function domain_name()
    if not config.default_domain or config.default_domain == '' then
      return nil
    end

    return { DomainName = config.default_domain }
  end

  local function spawn_workspace_tab(mux_window, item, trace_id)
    logger.info('workspace', 'spawning workspace tab', with_trace_id(trace_id, {
      cwd = item.cwd,
      workspace = mux_window:get_workspace(),
    }))
    local tab = mux_window:spawn_tab {
      cwd = item.cwd,
      domain = domain_name(),
      args = project_session_args(mux_window:get_workspace(), item, trace_id),
    }

    set_project_tab_title(tab, item)
    return tab
  end

  local function close_tab(tab)
    for _, pane_id in ipairs(tab_pane_ids(tab)) do
      wezterm.run_child_process {
        'wezterm',
        'cli',
        'kill-pane',
        '--pane-id',
        tostring(pane_id),
      }
    end
  end

  local function prune_workspace_tabs(target_window, desired_items)
    local stale_tabs = {}

    for _, info in ipairs(target_window:tabs_with_info()) do
      local matched = false

      for _, item in ipairs(desired_items) do
        if tab_matches_item(info.tab, item) then
          matched = true
          break
        end
      end

      if not matched then
        stale_tabs[#stale_tabs + 1] = info.tab
      end
    end

    if #stale_tabs == 0 then
      return
    end

    logger.info('workspace', 'pruning stale workspace tabs', {
      stale_count = #stale_tabs,
      workspace = target_window:get_workspace(),
      window_id = target_window:window_id(),
    })

    local desired_tab = nil
    if desired_items[1] then
      for _, info in ipairs(target_window:tabs_with_info()) do
        if tab_matches_item(info.tab, desired_items[1]) then
          desired_tab = info.tab
          break
        end
      end
    end

    if desired_tab then
      desired_tab:activate()
    end

    for _, tab in ipairs(stale_tabs) do
      close_tab(tab)
    end
  end

  local function sync_workspace_tabs(name, trace_id)
    local target_window = workspace_windows(name)[1]
    if not target_window then
      return
    end

    logger.info('workspace', 'syncing existing workspace window', with_trace_id(trace_id, {
      workspace = name,
      window_id = target_window:window_id(),
    }))
    mux.set_active_workspace(name)

    local gui_window = target_window:gui_window()
    local desired_items = workspace_items(name)

    for desired_index, item in ipairs(desired_items) do
      local matched

      for _, info in ipairs(target_window:tabs_with_info()) do
        if tab_matches_item(info.tab, item) then
          matched = info
          break
        end
      end

      if not matched then
        spawn_workspace_tab(target_window, item, trace_id)

        for _, info in ipairs(target_window:tabs_with_info()) do
          if tab_matches_item(info.tab, item) then
            matched = info
            break
          end
        end
      end

      if matched then
        set_project_tab_title(matched.tab, item)
      end

      if matched and gui_window and matched.index ~= (desired_index - 1) then
        local move_pane = matched.tab:active_pane()
        matched.tab:activate()
        gui_window:perform_action(wezterm.action.MoveTab(desired_index - 1), move_pane)
      end
    end

    prune_workspace_tabs(target_window, desired_items)
  end

  function Workspace.open(window, pane, name)
    local trace_id = logger.trace_id('workspace')
    local items = workspace_items(name)
    local prereq_error = managed_workspace_prereq_error()

    if prereq_error then
      logger.warn('workspace', 'managed workspace prerequisites failed', with_trace_id(trace_id, {
        error = prereq_error,
        workspace = name,
      }))
      window:toast_notification('WezTerm', prereq_error, nil, 4000)
      return
    end

    if #items == 0 then
      logger.warn('workspace', 'workspace has no configured directories', with_trace_id(trace_id, {
        workspace = name,
      }))
      window:toast_notification('WezTerm', 'No directories configured for workspace: ' .. name, nil, 3000)
      return
    end

    for _, item in ipairs(items) do
      if item.command_error then
        logger.warn('workspace', 'workspace item launcher resolution failed', with_trace_id(trace_id, {
          cwd = item.cwd,
          error = item.command_error,
          launcher = item.launcher,
          workspace = name,
        }))
        window:toast_notification('WezTerm', item.command_error, nil, 4000)
        return
      end
    end

    if #workspace_windows(name) > 0 then
      logger.info('workspace', 'switching to existing workspace', with_trace_id(trace_id, {
        item_count = #items,
        workspace = name,
      }))
      sync_workspace_tabs(name, trace_id)
      return
    end

    logger.info('workspace', 'creating new workspace window', with_trace_id(trace_id, {
      first_cwd = items[1].cwd,
      item_count = #items,
      workspace = name,
    }))
    local initial_tab, _, mux_window = mux.spawn_window {
      workspace = name,
      domain = domain_name(),
      cwd = items[1].cwd,
      args = project_session_args(name, items[1], trace_id),
    }
    set_project_tab_title(initial_tab, items[1])

    for i = 2, #items do
      spawn_workspace_tab(mux_window, items[i], trace_id)
    end

    initial_tab:activate()
    window:perform_action(wezterm.action.SwitchToWorkspace { name = name }, pane)
  end

  function Workspace.close(window, pane)
    local trace_id = logger.trace_id('workspace')
    local mux_window = window:mux_window()
    local workspace = mux_window and mux_window:get_workspace() or window:active_workspace()

    if not workspace or workspace == 'default' then
      logger.warn('workspace', 'refused to close built-in default workspace', with_trace_id(trace_id, {}))
      window:toast_notification('WezTerm', 'Refusing to close the built-in default workspace', nil, 3000)
      return
    end

    local pane_ids = workspace_pane_ids(workspace)
    if #pane_ids == 0 then
      logger.warn('workspace', 'no panes found while closing workspace', with_trace_id(trace_id, {
        workspace = workspace,
      }))
      window:toast_notification('WezTerm', 'No panes found in workspace: ' .. workspace, nil, 3000)
      return
    end

    logger.info('workspace', 'closing workspace', with_trace_id(trace_id, {
      pane_count = #pane_ids,
      workspace = workspace,
    }))
    window:perform_action(wezterm.action.SwitchToWorkspace { name = 'default' }, pane)

    for _, pane_id in ipairs(pane_ids) do
      wezterm.run_child_process {
        'wezterm',
        'cli',
        'kill-pane',
        '--pane-id',
        tostring(pane_id),
      }
    end
  end

  Workspace.items = workspace_items

  return Workspace
end

return M
