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
  local tab_visibility = opts.tab_visibility
  local workspace_defs = dofile(join_path(runtime_dir, 'workspaces.lua'))
  local logger = load_module('logger').new {
    wezterm = wezterm,
    constants = constants,
  }

  -- Cap spawnable items at workspace open when the workspace has opted
  -- into tab_visibility AND the user has explicitly enabled spawn cap.
  -- Cold-start fallback is "first N from workspaces.lua" — the user's
  -- intended priority order. Items beyond visible_count are reachable
  -- only via the overflow picker (Alt+t, PR3 phase 2) and the existing
  -- `Alt+/` attention overlay; until that picker ships,
  -- spawn_visible_only stays default-false to avoid stranding sessions.
  local function maybe_cap_items(workspace_name, items)
    if not tab_visibility or not tab_visibility.spawn_capped(workspace_name) then
      return items
    end
    local cfg = tab_visibility.config and tab_visibility.config() or {}
    local cap = tonumber(cfg.visible_count) or 5
    if #items <= cap then return items end
    local capped = {}
    for i = 1, cap do capped[i] = items[i] end
    return capped
  end

  -- Whether the workspace needs the overflow placeholder tab. Only true
  -- when there are MORE configured items than the visible cap; for a
  -- workspace with one or two items (e.g. `config`), the overflow tab
  -- would be a permanent empty placeholder with no sessions to project.
  local function workspace_needs_overflow(workspace_name, items)
    if not tab_visibility or not tab_visibility.is_enabled(workspace_name) then
      return false
    end
    local cfg = tab_visibility.config and tab_visibility.config() or {}
    local cap = tonumber(cfg.visible_count) or 5
    return type(items) == 'table' and #items > cap
  end

  -- Forward declarations. `runtime` and `tabs` are initialized below
  -- (after with_trace_id is defined), but several closure bodies above
  -- need to reference them lexically; without these `local` lines,
  -- those bodies would resolve `runtime`/`tabs` to globals (which are
  -- nil) and crash silently when called. The snapshot helpers also get
  -- forward-declared so Workspace.open can call them; their actual
  -- bodies are assigned below the runtime/tabs init for the same
  -- reason.
  local runtime
  local tabs
  local maybe_write_items_snapshot
  local refresh_items_snapshot

  -- Persist the workspace items snapshot so the Alt+t overflow menu
  -- (bash side) can list configured items + know which already have a
  -- wezterm tab. Bash CANNOT trust `tmux list-sessions` for the
  -- spawned-vs-not split: tmux sessions outlive their wezterm tab (a
  -- closed tab leaves the tmux session running). Only wezterm knows
  -- which cwds currently own a tab in the workspace window — so we
  -- compute that here and write `has_tab` per item.
  local function _maybe_write_items_snapshot_impl(workspace_name, raw_items, trace_id)
    if not tab_visibility or not tab_visibility.is_enabled(workspace_name) then
      return
    end
    local cfg = tab_visibility.config and tab_visibility.config() or {}
    local stats_dir = cfg.stats_dir
    if not stats_dir or stats_dir == '' then return end
    local slug = tab_visibility.workspace_slug(workspace_name)
    local path = stats_dir .. path_sep .. slug .. '-items.json'

    -- Build the set of cwds currently spawned as wezterm tabs in this
    -- workspace's mux window. Empty when the workspace has no window
    -- yet (cold start or first-ever open).
    local spawned_cwds = {}
    for _, mux_window in ipairs(mux.all_windows()) do
      if mux_window:get_workspace() == workspace_name then
        for _, info in ipairs(mux_window:tabs_with_info()) do
          local item_for_match = nil
          for _, candidate in ipairs(raw_items or {}) do
            if tabs.tab_matches_item(info.tab, candidate) then
              item_for_match = candidate
              break
            end
          end
          if item_for_match then
            spawned_cwds[item_for_match.cwd] = true
          end
        end
      end
    end

    local entries = {}
    for _, item in ipairs(raw_items or {}) do
      if item.cwd then
        local label = item.cwd:match('([^/]+)$') or item.cwd
        entries[#entries + 1] = {
          cwd = item.cwd,
          label = label,
          has_tab = spawned_cwds[item.cwd] == true,
        }
      end
    end
    local body
    local ok_enc, encoded = pcall(function()
      return wezterm.serde.json_encode({ version = 1, workspace = workspace_name, items = entries })
    end)
    if ok_enc and type(encoded) == 'string' then
      body = encoded
    else
      -- Fallback: hand-craft minimal JSON if json_encode is unavailable.
      local parts = {}
      for _, e in ipairs(entries) do
        parts[#parts + 1] = string.format(
          '{"cwd":"%s","label":"%s","has_tab":%s}',
          e.cwd:gsub('\\', '\\\\'):gsub('"', '\\"'),
          e.label:gsub('\\', '\\\\'):gsub('"', '\\"'),
          e.has_tab and 'true' or 'false')
      end
      body = string.format(
        '{"version":1,"workspace":"%s","items":[%s]}',
        workspace_name:gsub('\\', '\\\\'):gsub('"', '\\"'),
        table.concat(parts, ','))
    end
    local fd = io.open(path, 'wb')
    if not fd then
      logger.warn('workspace', 'tab-visibility items snapshot write failed', with_trace_id(trace_id, {
        workspace = workspace_name,
        path = path,
      }))
      return
    end
    fd:write(body)
    fd:close()
  end

  -- Public entry placeholder — assigned after `runtime` is initialized.
  local function _refresh_items_snapshot_impl(workspace_name)
    if not workspace_name or workspace_name == '' then return end
    local raw_items = runtime.workspace_items(workspace_name)
    if not raw_items or #raw_items == 0 then return end
    maybe_write_items_snapshot(workspace_name, raw_items, nil)
  end

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

  runtime = load_workspace_module('runtime').new {
    config = config,
    constants = constants,
    helpers = helpers,
    workspace_defs = workspace_defs,
  }

  tabs = load_workspace_module('tabs').new {
    wezterm = wezterm,
    mux = mux,
    helpers = helpers,
    logger = logger,
    with_trace_id = with_trace_id,
    runtime = runtime,
  }

  -- Bind the snapshot helpers now that `runtime` and `tabs` exist
  -- (they were forward-declared above so Workspace.open / Alt+t
  -- handlers can reach them via lexical scope).
  maybe_write_items_snapshot = _maybe_write_items_snapshot_impl
  refresh_items_snapshot = _refresh_items_snapshot_impl

  local Workspace = {}

  function Workspace.open(window, pane, name)
    local trace_id = logger.trace_id('workspace')
    local raw_items = runtime.workspace_items(name)
    -- Don't write the items snapshot here unconditionally — it costs
    -- mux walk + jq encode + cross-FS NTFS write per Alt+w press, and
    -- is only consumed by the Alt+t overflow menu. We refresh it on
    -- the cold-open path below (when a new mux window is being
    -- created) and lazily when the overflow menu fires (TODO: add a
    -- refresh-on-demand event in PR4). Hot Alt+w stays at the
    -- pre-snapshot latency.
    local items = maybe_cap_items(name, raw_items)
    if #items < #raw_items then
      logger.info('workspace', 'capped startup items by tab_visibility', with_trace_id(trace_id, {
        workspace = name,
        configured_count = #raw_items,
        spawned_count = #items,
      }))
    end
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
      -- Spawn loop uses capped items (don't auto-respawn cap-excluded
      -- entries on Alt+w), but prune compares against the full configured
      -- list so existing tabs that got spawned before the cap turned on
      -- survive the reconcile.
      tabs.sync_workspace_tabs(name, trace_id, items, raw_items)
      -- Self-heal the overflow placeholder. Two directions:
      --   - missing + needed → respawn (user closed it, refresh-session
      --     dropped it, etc.).
      --   - present + not needed → kill (workspace items dropped below
      --     the cap, OR enabled_workspaces gate was just removed and the
      --     workspace fits — config / mock-deck single-tab shouldn't
      --     carry a permanent empty `…`).
      -- find_overflow_tab is a single tabs_with_info walk; the
      -- needs_overflow check is O(1).
      if tab_visibility and tab_visibility.is_enabled(name) then
        local target_window = tabs.workspace_windows(name)[1]
        if target_window then
          local needs = workspace_needs_overflow(name, raw_items)
          local present = tabs.find_overflow_tab(target_window)
          if needs and not present then
            logger.info('workspace', 'overflow tab missing — respawning', with_trace_id(trace_id, {
              workspace = name,
            }))
            tabs.spawn_overflow_tab(target_window, tab_visibility.workspace_slug(name), trace_id)
          elseif present and not needs then
            logger.info('workspace', 'overflow tab unneeded — closing', with_trace_id(trace_id, {
              workspace = name,
              item_count = type(raw_items) == 'table' and #raw_items or 0,
            }))
            pcall(function() present:activate() end)
            pcall(function()
              local active_pane = present:active_pane()
              if active_pane and active_pane.kill then pcall(function() active_pane:kill() end) end
            end)
          end
        end
      end
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

    -- Cold-open: append the overflow placeholder tab only when the
    -- workspace has more configured items than the visible cap.
    -- Workspaces that fit (e.g. `config` with one repo) get no
    -- placeholder — a permanent empty `…` tab with nothing to project
    -- would be noise.
    if workspace_needs_overflow(name, raw_items) then
      tabs.spawn_overflow_tab(mux_window, tab_visibility.workspace_slug(name), trace_id)
    end

    initial_tab:activate()
    window:perform_action(wezterm.action.SwitchToWorkspace { name = name }, pane)

    -- Cold-open path only: write the items snapshot now that the
    -- window exists and tabs are spawned. The overflow picker reads
    -- this file at Alt+t time. Hot re-Alt+w skips the write — the
    -- snapshot from the most recent cold open is good enough until
    -- workspaces.lua is edited.
    maybe_write_items_snapshot(name, raw_items, trace_id)
  end

  -- Spawn or activate a single configured item by cwd. Used by the Alt+t
  -- overflow picker after the user picks an unspawned session: if the
  -- workspace already has a tab matching the cwd, activate it; otherwise
  -- spawn a new tab via the same managed-spawn path used at workspace
  -- open. Returns true on activation/spawn success, false on no-op
  -- (workspace not open, item not configured).
  function Workspace.spawn_or_activate(workspace_name, cwd)
    local trace_id = logger.trace_id('workspace')
    if not workspace_name or workspace_name == '' or not cwd or cwd == '' then
      return false
    end
    local windows = tabs.workspace_windows(workspace_name)
    local target_window = windows[1]
    if not target_window then
      logger.warn('workspace', 'overflow spawn skipped: workspace window not open', with_trace_id(trace_id, {
        workspace = workspace_name,
        cwd = cwd,
      }))
      return false
    end
    local raw_items = runtime.workspace_items(workspace_name)
    local item = nil
    for _, candidate in ipairs(raw_items) do
      if candidate.cwd == cwd then
        item = candidate
        break
      end
    end
    if not item then
      logger.warn('workspace', 'overflow spawn skipped: cwd not in workspaces.lua', with_trace_id(trace_id, {
        workspace = workspace_name,
        cwd = cwd,
      }))
      return false
    end
    -- If a tab already exists for this item, just activate it.
    for _, info in ipairs(target_window:tabs_with_info()) do
      if tabs.tab_matches_item(info.tab, item) then
        logger.info('workspace', 'overflow spawn → activating existing tab', with_trace_id(trace_id, {
          workspace = workspace_name,
          cwd = cwd,
          tab_index = info.index,
        }))
        info.tab:activate()
        return true
      end
    end
    logger.info('workspace', 'overflow spawn → creating new tab', with_trace_id(trace_id, {
      workspace = workspace_name,
      cwd = cwd,
    }))
    local new_tab = tabs.spawn_workspace_tab(target_window, item, trace_id)
    if new_tab then new_tab:activate() end
    return true
  end

  -- Activate-only: locate the wezterm tab matching this cwd in the
  -- workspace and bring it forward, but never spawn. Returns true on
  -- successful activation, false if the workspace has no window or
  -- no tab matches.
  function Workspace.activate_only(workspace_name, cwd)
    if not workspace_name or workspace_name == '' or not cwd or cwd == '' then
      return false
    end
    local target_window = tabs.workspace_windows(workspace_name)[1]
    if not target_window then return false end
    local raw_items = runtime.workspace_items(workspace_name)
    local item = nil
    for _, candidate in ipairs(raw_items) do
      if candidate.cwd == cwd then item = candidate; break end
    end
    if not item then return false end
    for _, info in ipairs(target_window:tabs_with_info()) do
      if tabs.tab_matches_item(info.tab, item) then
        info.tab:activate()
        return true
      end
    end
    return false
  end

  -- Activate the overflow placeholder tab for this workspace. Used by
  -- the Alt+t picker after switch-client'ing the overflow pane to a
  -- chosen warm session, so the user lands on the tab whose contents
  -- they just changed. Title stays `…` regardless of what the pane is
  -- projecting — overflow is the "rotating slot", its identity is
  -- positional not session-bound.
  function Workspace.activate_overflow(workspace_name)
    if not workspace_name or workspace_name == '' then return false end
    local target_window = tabs.workspace_windows(workspace_name)[1]
    if not target_window then return false end
    local overflow = tabs.find_overflow_tab(target_window)
    if not overflow then return false end
    overflow:activate()
    return true
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
