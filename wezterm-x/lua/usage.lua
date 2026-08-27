-- Hotkey usage counter: fire-and-forget bumps to
-- scripts/runtime/hotkey-usage-bump.sh. See that script for the JSON
-- counter file layout. The module stays thin on the hot path — it
-- resolves the bump script and spawns it; a missing script or
-- unavailable WSL distro is a silent no-op for the counter.
--
-- WezTerm-layer presses also emit `category="hotkey"` audit rows
-- (via the shared logger, when provided):
--   message="pressed"    — keymap wrap entered (binding fired)
--   message="dispatched" — perform_action returned (handler finished)
-- keymaps.lua owns those two lines; this module only bumps the counter
-- and may emit `pressed` when called standalone. Context stays cheap
-- (workspace / pane_id / domain) — no get_foreground_process_name on
-- the press path (hybrid-wsl cross-domain cost). If `hotkey` is missing
-- from diagnostics.wezterm.categories allowlist, rows are filtered out.

local path_sep = package.config:sub(1, 1)
local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local module_dir = join_path(rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.', 'lua', 'ui')
local common = dofile(join_path(module_dir, 'common.lua'))

local M = {}

local function collect_context_fields(context)
  local fields = {}
  if type(context) ~= 'table' then
    return fields
  end

  local window = context.window
  if window then
    local ok_ws, ws = pcall(function() return window:active_workspace() end)
    if ok_ws and type(ws) == 'string' and ws ~= '' then
      fields.workspace = ws
    end
  end

  local pane = context.pane
  if pane then
    local ok_id, pane_id = pcall(function() return pane:pane_id() end)
    if ok_id and pane_id ~= nil then
      fields.pane_id = tostring(pane_id)
    end

    local ok_dom, dom = pcall(function() return pane:get_domain_name() end)
    if ok_dom and type(dom) == 'string' and dom ~= '' then
      fields.domain = dom
    end
    -- Deliberately skip get_foreground_process_name / get_title here:
    -- both can cross into the guest on hybrid-wsl and the press path
    -- must stay sub-millisecond. Use category=latency slow rows when
    -- you need foreground on a sticky press.
  end

  return fields
end

function M.new(opts)
  local wezterm = opts.wezterm
  local constants = opts.constants
  local logger = opts.logger
  local runtime_mode = (constants and constants.runtime_mode) or 'hybrid-wsl'
  local host_os = constants and constants.host_os or 'linux'

  local repo_root = constants and constants.repo_root
  local script_path = nil
  if repo_root and repo_root ~= '' then
    script_path = repo_root .. '/scripts/runtime/hotkey-usage-bump.sh'
  end

  local wsl_distro = nil
  if runtime_mode == 'hybrid-wsl' and host_os == 'windows' then
    wsl_distro = common.wsl_distro_from_domain(constants.default_domain)
  end

  local function build_args(hotkey_id)
    if not script_path then return nil end
    if runtime_mode == 'hybrid-wsl' and host_os == 'windows' then
      if not wsl_distro then return nil end
      return { 'wsl.exe', '-d', wsl_distro, '--', 'bash', script_path, hotkey_id }
    end
    return { 'bash', script_path, hotkey_id }
  end

  local function bump(hotkey_id, context)
    if type(hotkey_id) ~= 'string' or hotkey_id == '' then return end
    local args = build_args(hotkey_id)
    if args then
      pcall(function() wezterm.background_child_process(args) end)
    end
  end

  -- Emit a hotkey audit row. message is typically "pressed" or
  -- "dispatched"; extra fields (duration_ms, …) are merged in.
  local function log_event(message, hotkey_id, context, extra)
    if not (logger and logger.info) then return end
    if type(hotkey_id) ~= 'string' or hotkey_id == '' then return end
    if type(message) ~= 'string' or message == '' then return end
    local fields = collect_context_fields(context)
    fields.hotkey_id = hotkey_id
    if type(extra) == 'table' then
      for k, v in pairs(extra) do
        fields[k] = v
      end
    end
    logger.info('hotkey', message, fields)
  end

  return { bump = bump, log_event = log_event, context_fields = collect_context_fields }
end

return M
