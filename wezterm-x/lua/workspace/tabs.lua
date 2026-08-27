local M = {}

-- Title used for the tab-visibility overflow placeholder tab. format-
-- tab-title relies on tab.tab_title to keep this rendered as `…`. The
-- prune / alignment-check logic identifies the tab by user_var marker
-- (M.OVERFLOW_USER_VAR_NAME / M.OVERFLOW_USER_VAR_VALUE) — a
-- title-based check would silently miss when a refresh path or a
-- user-driven set_title rewrites the tab title.
M.OVERFLOW_TAB_TITLE = '…'
M.OVERFLOW_USER_VAR_NAME = 'we_tab_role'
M.OVERFLOW_USER_VAR_VALUE = 'overflow'

function M.new(opts)
  local wezterm = opts.wezterm
  local mux = opts.mux
  local helpers = opts.helpers
  local logger = opts.logger
  local with_trace_id = opts.with_trace_id
  local runtime = opts.runtime

  local function tab_title_safe(tab)
    if not tab or type(tab.get_title) ~= 'function' then return nil end
    local ok, t = pcall(function() return tab:get_title() end)
    if ok then return t end
    return nil
  end

  -- Identify the overflow tab by user_var marker rather than by title.
  -- Title-based detection is fragile: refresh paths, user-driven
  -- set_title, or any code path that resets the title would silently
  -- de-classify the tab and let prune / alignment-check kill it.
  -- Active-pane user_var is checked because that is the layer wezterm's
  -- pane events surface; the var was set by spawn_overflow_tab.
  local function pane_user_var(pane, name)
    if not pane or type(pane.get_user_vars) ~= 'function' then return nil end
    local ok, vars = pcall(function() return pane:get_user_vars() end)
    if not ok or type(vars) ~= 'table' then return nil end
    return vars[name]
  end

  local function is_overflow_tab(tab)
    if not tab then return false end
    -- Walk tabs_with_info / tab.active_pane to reach the pane object.
    local active_pane = nil
    if type(tab.active_pane) == 'function' then
      local ok, p = pcall(function() return tab:active_pane() end)
      if ok then active_pane = p end
    end
    if active_pane and pane_user_var(active_pane, M.OVERFLOW_USER_VAR_NAME)
       == M.OVERFLOW_USER_VAR_VALUE then
      return true
    end
    -- Fallback to title for backwards compatibility with any overflow
    -- tab spawned before the user_var marker landed.
    return tab_title_safe(tab) == M.OVERFLOW_TAB_TITLE
  end

  local function find_overflow_tab(mux_window)
    if not mux_window then return nil end
    for _, info in ipairs(mux_window:tabs_with_info()) do
      if is_overflow_tab(info.tab) then return info.tab end
    end
    return nil
  end

  local function spawn_overflow_tab(mux_window, workspace_slug, trace_id)
    if not mux_window then return nil end
    if find_overflow_tab(mux_window) then return nil end
    workspace_slug = workspace_slug or 'default'
    -- The browse session is the per-workspace placeholder the overflow
    -- pane attaches to in its initial (Browse) state. Holding the
    -- pane on a real tmux client lets us later `tmux switch-client
    -- -c <tty> -t <target>` to project a different session into the
    -- same pane without restarting the wezterm pane process.
    local browse_session = 'wezterm_' .. workspace_slug .. '_overflow'
    -- Create the browse session if missing, then exec tmux attach.
    -- All inline because WEZTERM_RUNTIME_DIR is a Windows path on
    -- hybrid-wsl and the WSL bash can't reach a file there.
    --
    -- Before exec, record this pane's tty into a WSL-local state file.
    -- tab-overflow-attach.sh reads it later to target this client with
    -- `tmux switch-client -c <tty> -t <target_session>`. /tmp is fine —
    -- the tty itself is WSL-local, and on reboot the overflow tab is
    -- gone too so the file's lifetime matches the client's.
    local cwd = os.getenv('HOME') or '~'
    local script = string.format([[
session=%q
slug=%q
state_file="/tmp/wezterm-overflow-${slug}-tty.txt"
mkdir -p /tmp
printf '%%s\n' "$(tty)" > "$state_file"
if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" \
    bash -lc 'clear
printf "\n  📦  Overflow tab — browse mode\n\n"
printf "  Sessions outside the top-N visible window project into this pane.\n"
printf "  Press Alt+t to open the picker; pick a session and the view here\n"
printf "  switches to it.\n\n"
exec sleep infinity'
  # Tag the browse session with a role marker so refresh / reset paths
  # can identify it explicitly. Not enumerated by workspace_session_names
  # because it carries no @wezterm_workspace, but the role tag lets
  # future tooling find it deterministically.
  tmux set-option -t "$session" -q @wezterm_session_role tab_visibility_overflow_browse
fi
exec tmux attach -t "$session"
]], browse_session, workspace_slug)
    logger.info('workspace', 'spawning overflow placeholder tab', with_trace_id(trace_id, {
      workspace = mux_window:get_workspace(),
      browse_session = browse_session,
    }))
    local tab = mux_window:spawn_tab {
      domain = runtime.domain_name(),
      cwd = cwd,
      args = { 'bash', '-lc', script },
    }
    if tab and type(tab.set_title) == 'function' then
      pcall(function() tab:set_title(M.OVERFLOW_TAB_TITLE) end)
    end
    -- Register the overflow pane id in the tab_visibility _G map so the
    -- attention-side fallbacks (auto-ack + Alt+/ jump) can recover when
    -- a hook-stored wezterm_pane_id no longer exists. Initial state is
    -- the browse session — Alt+t picker updates the session field on
    -- each subsequent switch-client. Lazily dofile to avoid a hard
    -- dependency cycle.
    if tab then
      local pane_id = nil
      local active_pane = nil
      pcall(function() active_pane = tab:active_pane() end)
      if active_pane and type(active_pane.pane_id) == 'function' then
        pcall(function() pane_id = active_pane:pane_id() end)
      end
      -- Tag the overflow pane with a user_var so is_overflow_tab
      -- identifies it independently of the title — refresh / set_title
      -- paths can rewrite the title without de-classifying the tab.
      if active_pane and type(active_pane.set_user_var) == 'function' then
        pcall(function()
          active_pane:set_user_var(M.OVERFLOW_USER_VAR_NAME, M.OVERFLOW_USER_VAR_VALUE)
        end)
      end
      if pane_id then
        local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or ''
        local module_path = runtime_dir .. '/lua/ui/tab_visibility.lua'
        local ok, tab_visibility = pcall(dofile, module_path)
        if ok and tab_visibility and type(tab_visibility.set_overflow_pane) == 'function' then
          local workspace_name = nil
          pcall(function() workspace_name = mux_window:get_workspace() end)
          if workspace_name then
            tab_visibility.set_overflow_pane(workspace_name, pane_id, browse_session)
          end
          -- Evict any leftover `pane-session/<pane_id>.txt` before
          -- seeding this pane. wezterm recycles pane ids across
          -- restarts and open-project-session.sh never deletes the
          -- files it writes for managed session panes, so the id handed
          -- to a fresh placeholder often still has a file naming the
          -- previous occupant's session. The snapshot's staleness guard
          -- only catches cross-workspace mismatches, so a
          -- same-workspace leftover would make this tab claim that
          -- session and duplicate its attention badge onto `…`.
          if type(tab_visibility.forget_pane_session) == 'function' then
            tab_visibility.forget_pane_session(pane_id)
          end
          -- Mirror into the unified pane→session map so attention-side
          -- focus / jump / badge code resolves the overflow pane the
          -- same way it resolves visible managed tabs (one lookup, one
          -- truth source). Initial value is the browse session; the
          -- tab.activate_overflow handler refreshes it after each
          -- switch-client.
          if type(tab_visibility.set_pane_session) == 'function' then
            tab_visibility.set_pane_session(pane_id, browse_session)
          end
        end
      end
    end
    return tab
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
    if not item then
      return nil
    end
    -- Optional display override (e.g. brand name when the checkout dir
    -- still uses a legacy basename). Falls back to the cwd basename.
    if type(item.title) == 'string' and item.title ~= '' then
      return item.title
    end
    return item.cwd and helpers.basename(item.cwd) or nil
  end

  local function set_project_tab_title(tab, item)
    local title = project_tab_title(item)
    if tab and title then
      tab:set_title(title)
    end
  end

  -- cached_path:
  --   nil   → resolve via tab_path (pane:get_current_working_dir) on title miss
  --   false → title-only probe; never touch cwd (hot path for snapshot scans)
  --   string → use the pre-resolved cwd; never re-enter get_current_working_dir
  -- Callers that match one tab against many items MUST pass false then a
  -- once-resolved string — otherwise each failed title compare re-enters
  -- the guest on hybrid-wsl (~800ms per 5s update-status tick measured).
  local function tab_matches_item(tab, item, cached_path)
    if not tab or not item then
      return false
    end

    if tab:get_title() == project_tab_title(item) then
      return true
    end
    if cached_path == false then
      return false
    end
    local path = cached_path
    if path == nil then
      path = tab_path(tab)
    end
    return path == item.cwd
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

  local function prune_workspace_tabs(target_window, desired_items, protected_tab_id)
    local stale_tabs = {}
    local skipped_protected = false

    for _, info in ipairs(target_window:tabs_with_info()) do
      -- Never prune the overflow placeholder — it's not in workspaces.lua
      -- but is owned by the tab-visibility layer.
      if is_overflow_tab(info.tab) then
        goto continue
      end

      local matched = false

      for _, item in ipairs(desired_items) do
        if tab_matches_item(info.tab, item) then
          matched = true
          break
        end
      end

      if not matched then
        -- Phase 2b: skip closing the workspace's currently-active tab
        -- even when its item dropped out of `desired_items`. Protects
        -- the user's focus from disappearing mid-typing during live
        -- hot reorder. The next sync (after the user navigates away)
        -- will release protection and prune normally — the demoted
        -- tab's tmux session keeps running in the background until
        -- then, reachable via Alt+x.
        if protected_tab_id ~= nil and info.tab:tab_id() == protected_tab_id then
          skipped_protected = true
        else
          stale_tabs[#stale_tabs + 1] = info.tab
        end
      end

      ::continue::
    end

    if #stale_tabs == 0 then
      if skipped_protected then
        logger.info('workspace', 'prune skipped active tab (protected)', {
          workspace = target_window:get_workspace(),
          window_id = target_window:window_id(),
        })
      end
      return
    end

    logger.info('workspace', 'pruning stale workspace tabs', {
      stale_count = #stale_tabs,
      protected_skipped = skipped_protected,
      workspace = target_window:get_workspace(),
      window_id = target_window:window_id(),
    })

    -- Pre-prune activation of `desired_items[1]` is only safe when no
    -- tab is being protected — otherwise we'd steal focus from the
    -- protected tab right before / right after the prune. The caller
    -- (sync_workspace_tabs) handles focus restoration when
    -- `preserve_focus` is on.
    if protected_tab_id == nil then
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
    end

    for _, tab in ipairs(stale_tabs) do
      close_tab(tab)
    end
  end

  local function workspace_is_aligned(target_window, desired_items)
    -- Strip the overflow placeholder before comparing — it's owned by
    -- the tab-visibility layer, not by workspaces.lua, so its presence
    -- is orthogonal to whether the user's configured items are
    -- represented.
    local infos = {}
    for _, info in ipairs(target_window:tabs_with_info()) do
      if not is_overflow_tab(info.tab) then
        infos[#infos + 1] = info
      end
    end
    if #infos ~= #desired_items then
      return false
    end
    for i, info in ipairs(infos) do
      local item = desired_items[i]
      if not tab_matches_item(info.tab, item) then
        return false
      end
      -- Title can drift when items[].title changes while cwd still
      -- matches; force a sync pass so set_project_tab_title runs.
      if tab_title_safe(info.tab) ~= project_tab_title(item) then
        return false
      end
    end
    return true
  end

  -- desired_items_override caps the spawn loop (only these get spawned
  -- if missing); prune_keep_items_override caps the prune loop (tabs
  -- matching anything in this list are kept). The two lists differ
  -- under spawn_visible_only=true on the legacy soft-cap path: spawn
  -- limited to top-N, prune kept everything so pre-cap tabs survived
  -- a stray Alt+w. With Phase 2b (preserve_focus opt), strict cap
  -- becomes safe to ship — the active tab is protected from prune.
  --
  -- opts.preserve_focus (Phase 2b live hot reorder + strict-cap Alt+w):
  --   - Capture the workspace's currently-active tab id and pass it to
  --     prune_workspace_tabs so a demoted-but-currently-active tab
  --     survives this round (releases on next sync once the user
  --     navigates away).
  --   - By default, skip MoveTab repositioning so we don't cascade
  --     `:activate()` calls through every moved tab — that's the
  --     focus-stealing pattern that made hot Alt+w jarring under
  --     Phase 2a. opts.reorder_tabs opts back into MoveTab when top-N
  --     membership changes; focus is restored at the end of the sync.
  --   - Restore the original active tab at the end in case
  --     `mux_window:spawn_tab` activated the freshly-spawned tab as a
  --     side effect.
  --   The trade-off: when preserve_focus is on, tab POSITIONS may not
  --   match `desired_items`'s order — newly-spawned tabs land at the
  --   end of the strip rather than in their brain-ranked slot. The set
  --   matches (visible tabs == top-N + protected); only ordering
  --   differs. Cold-open still gets correct order because spawn order
  --   = brain order in that path.
  local function sync_workspace_tabs(name, trace_id, desired_items_override, prune_keep_items_override, opts)
    opts = opts or {}
    local target_window = workspace_windows(name)[1]
    if not target_window then
      return
    end

    local desired_items = desired_items_override or runtime.workspace_items(name)
    local prune_keep_items = prune_keep_items_override or desired_items

    -- Alignment check uses the prune-keep set. If the existing window
    -- already covers that, there's nothing to do — fast-switch.
    if workspace_is_aligned(target_window, prune_keep_items) then
      logger.info('workspace', 'workspace already aligned, fast switch', with_trace_id(trace_id, {
        workspace = name,
        window_id = target_window:window_id(),
        item_count = #prune_keep_items,
      }))
      mux.set_active_workspace(name)
      return
    end

    -- Capture the protected tab id BEFORE any mutation. `active_tab()`
    -- on the mux window reflects the user's last-seen tab in this
    -- workspace; protection covers it across spawn (which may activate
    -- the new tab as a side effect) and prune (which would otherwise
    -- close it when its session falls out of brain top-N). Fallback:
    -- scan tabs_with_info for the `is_active` row when the direct
    -- accessor isn't available on this wezterm build.
    local protected_tab_id = nil
    if opts.preserve_focus then
      local ok_active, active_tab = pcall(function() return target_window:active_tab() end)
      if ok_active and active_tab and type(active_tab.tab_id) == 'function' then
        local ok_id, id = pcall(function() return active_tab:tab_id() end)
        if ok_id then protected_tab_id = id end
      end
      if protected_tab_id == nil then
        for _, info in ipairs(target_window:tabs_with_info()) do
          if info.is_active and type(info.tab.tab_id) == 'function' then
            local ok_id, id = pcall(function() return info.tab:tab_id() end)
            if ok_id then protected_tab_id = id end
            break
          end
        end
      end
    end

    logger.info('workspace', 'syncing existing workspace window', with_trace_id(trace_id, {
      workspace = name,
      window_id = target_window:window_id(),
      preserve_focus = opts.preserve_focus and true or false,
      protected_tab_id = protected_tab_id,
    }))
    mux.set_active_workspace(name)

    local gui_window = target_window:gui_window()

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

      -- MoveTab cascades focus through every moved tab via the
      -- mandatory `:activate()` — wezterm has no positional-move that
      -- bypasses activation. preserve_focus normally accepts
      -- positional drift to avoid that focus storm, but sticky-slot
      -- replacement explicitly opts back in and restores focus afterward.
      if (not opts.preserve_focus or opts.reorder_tabs)
        and matched
        and gui_window
        and matched.index ~= (desired_index - 1)
      then
        local move_pane = matched.tab:active_pane()
        matched.tab:activate()
        gui_window:perform_action(wezterm.action.MoveTab(desired_index - 1), move_pane)
      end
    end

    prune_workspace_tabs(target_window, prune_keep_items, protected_tab_id)

    -- Keep the overflow placeholder at the tail. Under preserve_focus
    -- we skip the per-item MoveTab loop above to avoid a cascading
    -- focus storm — but the overflow tab isn't in desired_items, and
    -- a freshly-spawned visible tab gets appended *after* it, leaving
    -- the strip rendered as `…|new_tab` instead of `new_tab|…`. One
    -- single MoveTab here is not a storm; the focus restore below
    -- returns the user to their protected tab.
    if gui_window then
      local infos = target_window:tabs_with_info()
      local overflow_info, last_index = nil, -1
      for _, info in ipairs(infos) do
        if info.index > last_index then last_index = info.index end
        if is_overflow_tab(info.tab) then overflow_info = info end
      end
      if overflow_info and overflow_info.index ~= last_index then
        pcall(function() overflow_info.tab:activate() end)
        local move_pane = overflow_info.tab:active_pane()
        if move_pane then
          pcall(function()
            gui_window:perform_action(wezterm.action.MoveTab(last_index), move_pane)
          end)
        end
      end
    end

    -- Overflow → visible-tab handoff. When the protected tab is the
    -- overflow placeholder AND the session it is currently hosting was
    -- just promoted into top-N (so we spawned a real visible tab for
    -- it in the loop above), the user's focus should follow the
    -- session into its new permanent home — not stick to the now-
    -- redundant overflow slot. Without this branch the user observes:
    --   1. their session graduates from `…` into a proper tab (good)
    --   2. focus stays on `…` where the session is now redundantly
    --      mirrored via the shared tmux client (bad)
    --   3. overflow stays mirrored until they manually navigate away,
    --      because maybe_clear_overflow_collision defers when overflow
    --      is the active pane.
    -- Picking up the new visible tab here breaks the defer cycle on
    -- the very next tick — collision-clear fires, retargets overflow
    -- to browse, and the user sees a clean strip with focus where
    -- their work is.
    local handoff_target_tab
    if opts.preserve_focus and protected_tab_id and opts.cwd_to_session then
      local protected_info
      for _, info in ipairs(target_window:tabs_with_info()) do
        if type(info.tab.tab_id) == 'function' then
          local ok, id = pcall(function() return info.tab:tab_id() end)
          if ok and id == protected_tab_id then
            protected_info = info
            break
          end
        end
      end
      if protected_info and is_overflow_tab(protected_info.tab) then
        local runtime_dir = rawget(_G, 'WEZTERM_RUNTIME_DIR') or ''
        local tv_path = runtime_dir .. '/lua/ui/tab_visibility.lua'
        local ok_tv, tv = pcall(dofile, tv_path)
        if ok_tv and tv and type(tv.session_for_pane) == 'function' then
          local overflow_pane_id
          local ok_pane, ap = pcall(function() return protected_info.tab:active_pane() end)
          if ok_pane and ap and type(ap.pane_id) == 'function' then
            pcall(function() overflow_pane_id = ap:pane_id() end)
          end
          local overflow_session
          if overflow_pane_id then
            overflow_session = tv.session_for_pane(overflow_pane_id)
          end
          local browse_session
          if type(tv.workspace_slug) == 'function' then
            browse_session = 'wezterm_' .. tv.workspace_slug(name) .. '_overflow'
          end
          if overflow_session and overflow_session ~= ''
             and overflow_session ~= browse_session then
            -- Reverse-lookup: find the desired_item whose canonical
            -- session matches overflow's hosted session, then find
            -- the visible tab for that item.
            local target_cwd
            for cwd, sess in pairs(opts.cwd_to_session) do
              if sess == overflow_session then
                target_cwd = cwd
                break
              end
            end
            if target_cwd then
              for _, item in ipairs(desired_items) do
                if item.cwd == target_cwd then
                  for _, info in ipairs(target_window:tabs_with_info()) do
                    if not is_overflow_tab(info.tab)
                       and tab_matches_item(info.tab, item) then
                      handoff_target_tab = info.tab
                      break
                    end
                  end
                  break
                end
              end
            end
          end
        end
      end
    end

    if handoff_target_tab then
      logger.info('workspace', 'overflow handoff: activating new visible tab', with_trace_id(trace_id, {
        workspace = name,
        protected_tab_id = protected_tab_id,
      }))
      pcall(function() handoff_target_tab:activate() end)
    elseif opts.preserve_focus and protected_tab_id then
      -- Restore the originally-active tab. spawn_workspace_tab can
      -- activate the freshly-spawned tab as a side effect on some
      -- wezterm builds; this is a cheap no-op when focus already sits
      -- on the protected tab.
      for _, info in ipairs(target_window:tabs_with_info()) do
        if type(info.tab.tab_id) == 'function' then
          local ok, id = pcall(function() return info.tab:tab_id() end)
          if ok and id == protected_tab_id then
            pcall(function() info.tab:activate() end)
            break
          end
        end
      end
    end
  end

  return {
    workspace_windows = workspace_windows,
    workspace_pane_ids = workspace_pane_ids,
    set_project_tab_title = set_project_tab_title,
    spawn_workspace_tab = spawn_workspace_tab,
    sync_workspace_tabs = sync_workspace_tabs,
    tab_matches_item = tab_matches_item,
    tab_path = tab_path,
    spawn_overflow_tab = spawn_overflow_tab,
    find_overflow_tab = find_overflow_tab,
    is_overflow_tab = is_overflow_tab,
  }
end

return M
