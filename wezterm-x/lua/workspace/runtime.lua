local M = {}

function M.new(opts)
  local config = opts.config
  local constants = opts.constants
  local helpers = opts.helpers
  local workspace_defs = opts.workspace_defs

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

  local function domain_name()
    if not config.default_domain or config.default_domain == '' then
      return nil
    end

    return { DomainName = config.default_domain }
  end

  return {
    managed_workspace_prereq_error = managed_workspace_prereq_error,
    workspace_items = workspace_items,
    project_session_args = project_session_args,
    domain_name = domain_name,
  }
end

return M
