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

local function load_workspace_module(name)
  return dofile(join_path(runtime_dir, 'lua', 'workspace', name .. '.lua'))
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

  local runtime = load_workspace_module('runtime').new {
    config = config,
    constants = constants,
    helpers = helpers,
    workspace_defs = workspace_defs,
  }

  local tabs = load_workspace_module('tabs').new {
    wezterm = wezterm,
    mux = mux,
    helpers = helpers,
    logger = logger,
    with_trace_id = with_trace_id,
    runtime = runtime,
  }

  local Workspace = {}

  function Workspace.open(window, pane, name)
    local trace_id = logger.trace_id('workspace')
    local items = runtime.workspace_items(name)
    local prereq_error = runtime.managed_workspace_prereq_error()

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

    if #tabs.workspace_windows(name) > 0 then
      logger.info('workspace', 'switching to existing workspace', with_trace_id(trace_id, {
        item_count = #items,
        workspace = name,
      }))
      tabs.sync_workspace_tabs(name, trace_id)
      return
    end

    logger.info('workspace', 'creating new workspace window', with_trace_id(trace_id, {
      first_cwd = items[1].cwd,
      item_count = #items,
      workspace = name,
    }))
    local initial_tab, _, mux_window = mux.spawn_window {
      workspace = name,
      domain = runtime.domain_name(),
      cwd = items[1].cwd,
      args = runtime.project_session_args(name, items[1], trace_id),
    }
    tabs.set_project_tab_title(initial_tab, items[1])

    for i = 2, #items do
      tabs.spawn_workspace_tab(mux_window, items[i], trace_id)
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

    local pane_ids = tabs.workspace_pane_ids(workspace)
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

  Workspace.items = runtime.workspace_items

  return Workspace
end

return M
