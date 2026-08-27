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

  -- One-shot bulk compute of `cwd → canonical session name` via the
  -- `print-session-names.sh` helper. Single subprocess regardless of
  -- item count (vs forking once per item, which would blow the
  -- Workspace.open hot path). Returns `{}` on any failure — callers
  -- treat that as "no session map available, fall back to declared
  -- order" in `tab_visibility.preferred_item_order`. Uses wsl.exe on
  -- the hybrid-wsl Windows host, plain bash everywhere else.
  local function compute_cwd_to_session(workspace_name, items, trace_id)
    if type(items) ~= 'table' or #items == 0 then return {} end
    local repo_root = constants and constants.repo_root
    if not repo_root or repo_root == '' then
      logger.warn('workspace', 'no repo_root for session-name compute', with_trace_id(trace_id, {
        workspace = workspace_name,
      }))
      return {}
    end
    local script_path = repo_root .. '/scripts/runtime/tmux-worktree/print-session-names.sh'

    local args
    local runtime_mode = (constants and constants.runtime_mode) or 'hybrid-wsl'
    if runtime_mode == 'hybrid-wsl' and constants and constants.host_os == 'windows' then
      local domain = constants.default_domain or ''
      local distro = type(domain) == 'string' and domain:match('^WSL:(.+)$') or nil
      if not distro then
        logger.warn('workspace', 'no WSL distro for session-name compute', with_trace_id(trace_id, {
          workspace = workspace_name,
          default_domain = domain,
        }))
        return {}
      end
      args = { 'wsl.exe', '-d', distro, '--', 'bash', script_path, workspace_name }
    else
      args = { 'bash', script_path, workspace_name }
    end
    for _, item in ipairs(items) do
      if item and item.cwd and item.cwd ~= '' then
        args[#args + 1] = item.cwd
      end
    end

    local ok, success, stdout, stderr = pcall(wezterm.run_child_process, args)
    if not ok then
      logger.warn('workspace', 'session-name compute raised', with_trace_id(trace_id, {
        workspace = workspace_name,
        error = success,
      }))
      return {}
    end
    if not success then
      logger.warn('workspace', 'session-name compute failed', with_trace_id(trace_id, {
        workspace = workspace_name,
        stderr = stderr,
      }))
      return {}
    end

    local out = {}
    for line in (stdout or ''):gmatch('[^\n]+') do
      local cwd, sess = line:match('^(.-)\t(.*)$')
      if cwd and sess and sess ~= '' then
        out[cwd] = sess
      end
    end
    return out
  end

  local function runtime_script_args(script_name, trace_id, ...)
    local repo_root = constants and constants.repo_root
    if not repo_root or repo_root == '' then
      logger.warn('workspace', 'no repo_root for runtime script', with_trace_id(trace_id, {
        script = script_name,
      }))
      return nil
    end
    local script_path = repo_root .. '/scripts/runtime/' .. script_name
    local args
    local runtime_mode = (constants and constants.runtime_mode) or 'hybrid-wsl'
    if runtime_mode == 'hybrid-wsl' and constants and constants.host_os == 'windows' then
      local domain = constants.default_domain or ''
      local distro = type(domain) == 'string' and domain:match('^WSL:(.+)$') or nil
      if not distro then
        logger.warn('workspace', 'no WSL distro for runtime script', with_trace_id(trace_id, {
          script = script_name,
          default_domain = domain,
        }))
        return nil
      end
      args = { 'wsl.exe', '-d', distro, '--', 'bash', script_path }
    else
      args = { 'bash', script_path }
    end
    for _, arg in ipairs({ ... }) do
      args[#args + 1] = arg
    end
    return args
  end

  -- Pick the spawn-list when the workspace has opted into tab_visibility
  -- AND the user has explicitly enabled spawn cap (`spawn_visible_only`).
  -- Two layers of selection:
  --   1. Cap `items` at `visible_count` (otherwise we'd spawn the full
  --      `workspaces.lua` list).
  --   2. Order the kept items by sticky slot. Activity score (with
  --      `__refresh_*` aggregation) decides top-N membership and initializes
  --      cold slots; later score changes among the same members preserve
  --      their positions. Items without activity fill from `workspaces.lua`
  --      declared order.
  -- Without `spawn_capped` we leave the list untouched — there's no
  -- cap, no overflow tab, every item gets a wezterm tab in declared
  -- order. Reordering an uncapped list would visually shuffle every
  -- existing tab on hot Alt+w; see Phase 2b for that work.
  -- Returns (capped_items, cwd_to_session_map). The map is the same one
  -- preferred_item_order consumes, hoisted into the return so callers
  -- that need the canonical session for an item (overflow handoff
  -- detection in sync_workspace_tabs) can reuse it without re-shelling.
  -- Callers that don't need it just drop the extra return.
  local function maybe_cap_items(workspace_name, items, trace_id, opts)
    opts = opts or {}
    if not tab_visibility or not tab_visibility.spawn_capped(workspace_name) then
      return items, {}
    end
    local cfg = tab_visibility.config and tab_visibility.config() or {}
    local cap = tonumber(cfg.visible_count) or 5
    if #items == 0 then return items, {} end
    local cwd_to_session = {}
    if not opts.skip_session_compute then
      cwd_to_session = compute_cwd_to_session(workspace_name, items, trace_id)
    end
    local capped = tab_visibility.preferred_item_order(workspace_name, items, cwd_to_session, cap)
    return capped, cwd_to_session
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

    -- Only managed-launcher workspaces belong in the Alt+x picker.
    -- Demo / dev workspaces like `mock-deck` declare items with raw
    -- `command = { ... }` and no launcher; surfacing them as overflow
    -- rows is noise. Skip when nothing resolved to a launcher (per-item
    -- launcher or workspace defaults.launcher, both flattened into
    -- raw_items by runtime.workspace_items). If a previous configuration
    -- left a snapshot behind, remove it so the picker stays in lockstep
    -- with the current rule.
    local any_launcher = false
    for _, item in ipairs(raw_items or {}) do
      if item.launcher then
        any_launcher = true
        break
      end
    end
    if not any_launcher then
      pcall(os.remove, path)
      return
    end

    -- Build the set of cwds currently spawned as wezterm tabs in this
    -- workspace's mux window. Empty when the workspace has no window
    -- yet (cold start or first-ever open).
    --
    -- Title-first, cwd-once. tab_matches_item falls back to
    -- pane:get_current_working_dir() on title miss; without this split
    -- that was O(tabs × items) cross-FS lookups and blocked the UI
    -- thread ~800ms every 5s (phase_prefetch_ms). Managed tabs already
    -- carry project titles, so the cwd path is the exception.
    local spawned_cwds = {}
    for _, mux_window in ipairs(mux.all_windows()) do
      if mux_window:get_workspace() == workspace_name then
        for _, info in ipairs(mux_window:tabs_with_info()) do
          local tab = info.tab
          local item_for_match = nil
          for _, candidate in ipairs(raw_items or {}) do
            if tabs.tab_matches_item(tab, candidate, false) then
              item_for_match = candidate
              break
            end
          end
          if not item_for_match and tabs.tab_path then
            local path = tabs.tab_path(tab)
            if path then
              for _, candidate in ipairs(raw_items or {}) do
                if tabs.tab_matches_item(tab, candidate, path) then
                  item_for_match = candidate
                  break
                end
              end
            end
          end
          if item_for_match then
            spawned_cwds[item_for_match.cwd] = true
          end
        end
      end
    end

    -- Reuse previously written session names when cwd is unchanged. Session
    -- names are deterministic on (workspace, repo/cwd); recomputing them
    -- shells out to git once per item and was the Alt+x menu's dominant
    -- cost (~300ms for 14 work rows). Only bulk-compute missing cwds.
    local prev_sessions = {}
    local prev_body = nil
    do
      local prev_fd = io.open(path, 'rb')
      if prev_fd then
        prev_body = prev_fd:read('*a')
        prev_fd:close()
        if type(prev_body) == 'string' and prev_body ~= '' then
          local ok_dec, prev = pcall(function()
            return wezterm.serde.json_decode(prev_body)
          end)
          if ok_dec and type(prev) == 'table' and type(prev.items) == 'table' then
            for _, e in ipairs(prev.items) do
              if type(e) == 'table' and e.cwd and e.session and e.session ~= '' then
                prev_sessions[e.cwd] = e.session
              end
            end
          end
        end
      end
    end

    local need_session = {}
    for _, item in ipairs(raw_items or {}) do
      if item.cwd and not prev_sessions[item.cwd] then
        need_session[#need_session + 1] = item
      end
    end
    local computed_sessions = {}
    if #need_session > 0 then
      computed_sessions = compute_cwd_to_session(workspace_name, need_session, trace_id)
    end

    local entries = {}
    for _, item in ipairs(raw_items or {}) do
      if item.cwd then
        local label = item.cwd:match('([^/]+)$') or item.cwd
        local session = prev_sessions[item.cwd]
          or computed_sessions[item.cwd]
          or ''
        entries[#entries + 1] = {
          cwd = item.cwd,
          label = label,
          has_tab = spawned_cwds[item.cwd] == true,
          session = session,
        }
      end
    end
    local body
    local ok_enc, encoded = pcall(function()
      return wezterm.serde.json_encode({ version = 2, workspace = workspace_name, items = entries })
    end)
    if ok_enc and type(encoded) == 'string' then
      body = encoded
    else
      -- Fallback: hand-craft minimal JSON if json_encode is unavailable.
      local parts = {}
      for _, e in ipairs(entries) do
        parts[#parts + 1] = string.format(
          '{"cwd":"%s","label":"%s","has_tab":%s,"session":"%s"}',
          e.cwd:gsub('\\', '\\\\'):gsub('"', '\\"'),
          e.label:gsub('\\', '\\\\'):gsub('"', '\\"'),
          e.has_tab and 'true' or 'false',
          (e.session or ''):gsub('\\', '\\\\'):gsub('"', '\\"'))
      end
      body = string.format(
        '{"version":2,"workspace":"%s","items":[%s]}',
        workspace_name:gsub('\\', '\\\\'):gsub('"', '\\"'),
        table.concat(parts, ','))
    end
    -- Skip NTFS rewrite when nothing changed. has_tab / session / label
    -- are stable across most 5s ticks; rewriting anyway just burned
    -- UI-thread time and woke AV scanners.
    if type(prev_body) == 'string' and prev_body == body then
      return
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
  local last_activity_sample_ms = {}

  local function now_ms()
    local ok, now_str = pcall(function()
      return wezterm.time.now():format '%s%3f'
    end)
    if ok and type(now_str) == 'string' and now_str:match '^%d+$' then
      return tonumber(now_str)
    end
    return nil
  end

  function Workspace.open(window, pane, name)
    local trace_id = logger.trace_id('workspace')
    local start_ms = now_ms()
    -- When opened from a WezTerm-layer hotkey wrap, keymaps.lua stashes
    -- the manifest id so these rows correlate with hotkey/pressed +
    -- hotkey/dispatched. Absent when called from other entry points
    -- (palette toast, startup, overflow spawn, …).
    local active_hotkey_id = rawget(_G, '__WEZTERM_ACTIVE_HOTKEY_ID')
    if type(active_hotkey_id) ~= 'string' or active_hotkey_id == '' then
      active_hotkey_id = nil
    end
    local function open_fields(extra)
      local fields = with_trace_id(trace_id, extra)
      if active_hotkey_id then
        fields.hotkey_id = active_hotkey_id
      end
      return fields
    end
    local raw_items = runtime.workspace_items(name)
    -- Don't write the items snapshot here unconditionally — it costs
    -- mux walk + json encode + cross-FS NTFS write per Alt+w press,
    -- and is only consumed by the Alt+x overflow picker. We refresh
    -- it on the cold-open path below (when a new mux window is being
    -- created), and the Alt+x handler in action_registry refreshes
    -- every configured workspace's snapshot on demand via
    -- Workspace.refresh_all_items_snapshots so edits to
    -- workspaces.lua surface in the picker without forcing a cold
    -- reopen. Hot Alt+w stays at the pre-snapshot latency.
    local workspace_exists = #tabs.workspace_windows(name) > 0
    local items, cwd_to_session = maybe_cap_items(name, raw_items, trace_id, {
      skip_session_compute = workspace_exists,
    })
    if #items < #raw_items then
      logger.info('workspace', 'capped startup items by tab_visibility', open_fields({
        workspace = name,
        configured_count = #raw_items,
        spawned_count = #items,
      }))
    end
    local prereq_error = runtime.managed_workspace_prereq_error()

    if prereq_error then
      logger.warn('workspace', 'managed workspace prerequisites failed', open_fields({
        error = prereq_error,
        workspace = name,
      }))
      window:toast_notification('WezTerm', prereq_error, nil, 4000)
      return
    end

    if #items == 0 then
      logger.warn('workspace', 'workspace has no configured directories', open_fields({
        workspace = name,
      }))
      window:toast_notification('WezTerm', 'No directories configured for workspace: ' .. name, nil, 3000)
      return
    end

    for _, item in ipairs(items) do
      if item.command_error then
        logger.warn('workspace', 'workspace item launcher resolution failed', open_fields({
          cwd = item.cwd,
          error = item.command_error,
          launcher = item.launcher,
          workspace = name,
        }))
        window:toast_notification('WezTerm', item.command_error, nil, 4000)
        return
      end
    end

    if workspace_exists then
      logger.info('workspace', 'switching to existing workspace', open_fields({
        item_count = #items,
        skipped_session_compute = true,
        workspace = name,
      }))
      -- Phase 2b: under spawn_capped, both spawn and prune use brain
      -- top-N (`items`). preserve_focus protects the active tab from
      -- prune and skips MoveTab repositioning so the tab the user is
      -- on doesn't get closed or have its position cascaded by the
      -- focus storm. Without spawn_capped, fall back to the legacy
      -- soft-cap behavior (spawn = capped, prune = full list) so a
      -- workspace with no cap doesn't suddenly start losing tabs.
      local capped = tab_visibility and tab_visibility.spawn_capped(name)
      local prune_keep = capped and items or raw_items
      local sync_opts = capped and {
        preserve_focus = true,
        cwd_to_session = cwd_to_session,
      } or nil
      tabs.sync_workspace_tabs(name, trace_id, items, prune_keep, sync_opts)
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
      local finish_ms = now_ms()
      logger.info('workspace', 'workspace open completed', open_fields({
        duration_ms = start_ms and finish_ms and (finish_ms - start_ms) or nil,
        mode = 'existing',
        skipped_session_compute = true,
        workspace = name,
      }))
      return
    end

    logger.info('workspace', 'creating new workspace window', open_fields({
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
    local finish_ms = now_ms()
    logger.info('workspace', 'workspace open completed', open_fields({
      duration_ms = start_ms and finish_ms and (finish_ms - start_ms) or nil,
      mode = 'created',
      skipped_session_compute = false,
      workspace = name,
    }))
  end

  -- Phase 2b live hot reorder. Called from titles.lua's update-status
  -- after `tab_visibility.tick` reports that the brain's slot
  -- assignment changed since the previous tick — that's the signal
  -- that some session entered top-N (needs to be spawned) or fell out
  -- of top-N (its tab needs to be pruned). Rank changes among the same
  -- top-N members do not move tabs. preserve_focus mode keeps the user's
  -- currently-active tab alive and restores focus after any MoveTab
  -- reordering; if the active tab is demoted, prune skips it for this
  -- round.
  --
  -- Only fires when:
  --   - tab_visibility is enabled AND spawn_capped (no cap means every
  --     item is already a tab — no swap to make).
  --   - the workspace has at least one mux window (you can't reorder
  --     a workspace that hasn't been opened yet — cold-open already
  --     does the work).
  --   - the items list is non-empty.
  function Workspace.maybe_hot_reorder(workspace_name)
    if not workspace_name or workspace_name == '' then return end
    if not (tab_visibility and tab_visibility.spawn_capped(workspace_name)) then
      return
    end
    if #tabs.workspace_windows(workspace_name) == 0 then
      return
    end
    local trace_id = logger.trace_id('workspace')
    local raw_items = runtime.workspace_items(workspace_name)
    if not raw_items or #raw_items == 0 then return end
    local items, cwd_to_session = maybe_cap_items(workspace_name, raw_items, trace_id)
    if not items or #items == 0 then return end

    logger.info('workspace', 'live hot reorder triggered', with_trace_id(trace_id, {
      workspace = workspace_name,
      desired_count = #items,
    }))
    tabs.sync_workspace_tabs(workspace_name, trace_id, items, items, {
      preserve_focus = true,
      reorder_tabs = true,
      cwd_to_session = cwd_to_session,
    })
  end

  -- Low-frequency git fingerprint sampler. It runs only for capped
  -- workspaces that actually have overflow, and only in the background.
  -- The sampler writes tab-stats v4 activity fields; the next
  -- tab_visibility.tick sees the changed stats file and hot-reorders if
  -- the activity top-N changed.
  function Workspace.maybe_sample_tab_activity(workspace_name, now_ms)
    if not workspace_name or workspace_name == '' then return false end
    if not (tab_visibility and tab_visibility.spawn_capped(workspace_name)) then
      return false
    end
    if #tabs.workspace_windows(workspace_name) == 0 then
      return false
    end
    local raw_items = runtime.workspace_items(workspace_name)
    if not workspace_needs_overflow(workspace_name, raw_items) then
      return false
    end
    local cfg = tab_visibility.config and tab_visibility.config() or {}
    local interval = tonumber(cfg.activity_sample_interval_ms) or 60000
    local last = last_activity_sample_ms[workspace_name] or 0
    if now_ms and last > 0 and (now_ms - last) < interval then
      return false
    end
    last_activity_sample_ms[workspace_name] = now_ms or 0
    local trace_id = logger.trace_id('tab_visibility')
    local args = runtime_script_args('tab-activity-sample.sh', trace_id, workspace_name, 'all')
    if not args then return false end
    logger.info('tab_visibility', 'sampling tab activity', with_trace_id(trace_id, {
      workspace = workspace_name,
      interval_ms = interval,
    }))
    pcall(wezterm.background_child_process, args)
    return true
  end

  -- Cached actions module for the overflow-collision retarget below.
  -- Lazy-loaded so workspace_manager doesn't add a hard import edge on
  -- ui/actions for the common case where no collision ever fires (most
  -- workspaces never have an overflow promotion); resolved once and
  -- memoized after that.
  local cached_actions_mod
  local function load_actions_mod()
    if cached_actions_mod ~= nil then return cached_actions_mod end
    local ok, mod = pcall(load_module, 'ui/actions')
    cached_actions_mod = (ok and mod) or false
    return cached_actions_mod
  end

  -- Auto-detach the overflow pane when its currently-projected session
  -- has just been promoted into top-N. The hot-reorder path spawns a
  -- new visible tab via open-project-session.sh, which reuses the
  -- existing tmux session — at that moment two wezterm panes (the new
  -- visible tab AND the overflow pane) are both attached to the same
  -- tmux client, so loading output mirrors. The fix is to retarget the
  -- overflow pane back to the per-workspace browse session
  -- (`wezterm_<slug>_overflow`) so the new visible tab owns the session
  -- alone.
  --
  -- Same defer pattern as preserve_focus prune in sync_workspace_tabs:
  -- when `active_pane_id` matches the overflow pane (user is currently
  -- looking at it), no-op for this tick — retargeting the user's view
  -- mid-watch would be jarring. Next update-status tick after the user
  -- navigates elsewhere will catch the collision and resolve it.
  --
  -- Called every update-status tick (cheap: a few map lookups, no
  -- shell-out unless retarget needed). Idempotent — once retargeted,
  -- the overflow session matches browse_session and the function
  -- early-returns.
  function Workspace.maybe_clear_overflow_collision(workspace_name, active_pane_id)
    if not workspace_name or workspace_name == '' then return false end
    if not tab_visibility or type(tab_visibility.is_in_visible) ~= 'function' then
      return false
    end
    local map = rawget(_G, '__WEZTERM_TAB_OVERFLOW') or {}
    local entry = map[workspace_name]
    if not entry or not entry.pane_id then return false end
    local session = entry.session
    if not session or session == '' then return false end
    local slug = tab_visibility.workspace_slug(workspace_name)
    local browse_session = 'wezterm_' .. slug .. '_overflow'
    if session == browse_session then return false end
    if not tab_visibility.is_in_visible(workspace_name, session) then
      return false
    end
    -- Active-tab protection — defer when the user is on the overflow pane.
    if active_pane_id ~= nil
       and tostring(active_pane_id) == tostring(entry.pane_id) then
      return false
    end
    local actions_mod = load_actions_mod()
    if not actions_mod or type(actions_mod.tab_overflow_attach_args) ~= 'function' then
      return false
    end
    local trace_id = logger.trace_id('tab_visibility')
    local args = actions_mod.tab_overflow_attach_args(
      constants, nil, workspace_name, browse_session, logger, trace_id)
    if not args then return false end
    logger.info('tab_visibility', 'overflow collision detected — retargeting to browse', with_trace_id(trace_id, {
      workspace = workspace_name,
      promoted_session = session,
      browse_session = browse_session,
      overflow_pane_id = entry.pane_id,
    }))
    pcall(wezterm.background_child_process, args)
    -- Mirror the new state into the in-memory maps so subsequent ticks
    -- early-return on the `session == browse_session` guard, instead of
    -- racing the background subprocess and firing duplicate retargets.
    if type(tab_visibility.set_overflow_attach) == 'function' then
      tab_visibility.set_overflow_attach(workspace_name, browse_session)
    end
    if type(tab_visibility.set_pane_session) == 'function' then
      tab_visibility.set_pane_session(entry.pane_id, browse_session)
    end
    return true
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

  Workspace.refresh_items_snapshot = refresh_items_snapshot

  -- On-demand refresh hook for the Alt+x overflow picker. Iterates
  -- every workspace declared in workspaces.lua (including local
  -- overrides) so edits made since the last cold-open surface in the
  -- picker without the user having to close + reopen the workspace
  -- window. `refresh_items_snapshot` is a no-op for workspaces with
  -- no configured items or where tab_visibility is disabled, so this
  -- is safe to call across the whole def table.
  function Workspace.refresh_all_items_snapshots()
    for name, _ in pairs(workspace_defs) do
      refresh_items_snapshot(name)
    end
  end

  return Workspace
end

return M
