local M = {}

function M.new(opts)
  local wezterm = opts.wezterm
  local mux = opts.mux
  local helpers = opts.helpers
  local logger = opts.logger
  local with_trace_id = opts.with_trace_id
  local runtime = opts.runtime

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

  local function spawn_workspace_tab(mux_window, item, trace_id)
    logger.info('workspace', 'spawning workspace tab', with_trace_id(trace_id, {
      cwd = item.cwd,
      workspace = mux_window:get_workspace(),
    }))
    local tab = mux_window:spawn_tab {
      cwd = item.cwd,
      domain = runtime.domain_name(),
      args = runtime.project_session_args(mux_window:get_workspace(), item, trace_id),
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
    local desired_items = runtime.workspace_items(name)

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

  return {
    workspace_windows = workspace_windows,
    workspace_pane_ids = workspace_pane_ids,
    set_project_tab_title = set_project_tab_title,
    spawn_workspace_tab = spawn_workspace_tab,
    sync_workspace_tabs = sync_workspace_tabs,
  }
end

return M
