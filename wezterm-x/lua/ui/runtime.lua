local path_sep = package.config:sub(1, 1)

local function join_path(...)
  return table.concat({ ... }, path_sep)
end

local module_dir = join_path(rawget(_G, 'WEZTERM_RUNTIME_DIR') or '.', 'lua', 'ui')
local common = dofile(join_path(module_dir, 'common.lua'))

local M = {}

function M.default_wsl_tmux_program(constants)
  if constants.runtime_mode ~= 'hybrid-wsl' or constants.host_os ~= 'windows' then
    return nil
  end

  if not constants.default_domain or constants.default_domain == '' then
    return nil
  end

  local roots = common.runtime_script_roots(constants)
  if #roots == 0 then
    return nil
  end

  local primary_script = roots[1] and (roots[1] .. '/scripts/runtime/open-default-shell-session.sh') or ''
  local fallback_script = roots[2] and (roots[2] .. '/scripts/runtime/open-default-shell-session.sh') or ''

  return {
    '/bin/sh',
    '-lc',
    [[
primary_script="$1"
fallback_script="$2"
cwd="${PWD:-}"
if [ -z "$cwd" ] || printf '%s' "$cwd" | grep -Eq '^/mnt/[a-z]/Users/[^/]+$'; then
  cwd="$HOME"
fi
shift 2

run_script() {
  script_path="$1"
  shift

  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    exec bash "$script_path" "$@"
  fi
}

run_script "$primary_script" "$cwd"
run_script "$fallback_script" "$cwd"

printf 'Default WSL tmux runtime script is unavailable: %s\n' "$primary_script" >&2
if [ -n "$fallback_script" ]; then
  printf 'Fallback default WSL tmux runtime script is unavailable: %s\n' "$fallback_script" >&2
fi
exit 1
    ]],
    'sh',
    primary_script,
    fallback_script,
  }
end

function M.configured_wsl_domains(wezterm, constants)
  local ok, domains = pcall(wezterm.default_wsl_domains)
  if not ok or type(domains) ~= 'table' then
    return nil
  end

  local default_program = M.default_wsl_tmux_program(constants)
  if not default_program then
    return domains
  end

  local target_distro = common.wsl_distro_from_domain(constants.default_domain)
  if not target_distro or target_distro == '' then
    return domains
  end

  local configured = {}
  local matched = false
  for _, domain in ipairs(domains) do
    local item = {}
    for key, value in pairs(domain) do
      item[key] = value
    end
    if item.name == constants.default_domain or item.distribution == target_distro then
      local program = {}
      for _, part in ipairs(default_program) do
        program[#program + 1] = part
      end
      item.default_prog = program
      matched = true
    end
    configured[#configured + 1] = item
  end

  if not matched and wezterm.log_warn then
    wezterm.log_warn(
      'default WSL tmux program was not applied because no WSL domain matched default_domain='
        .. tostring(constants.default_domain)
        .. ' distribution='
        .. tostring(target_distro)
    )
  end

  return configured
end

return M
