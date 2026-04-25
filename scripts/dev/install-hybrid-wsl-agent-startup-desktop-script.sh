#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WT_LIB_DIR="$REPO_ROOT/scripts/runtime/worktree/lib"
WINDOWS_SHELL_LIB="$REPO_ROOT/scripts/runtime/windows-shell-lib.sh"

# shellcheck disable=SC1091
source "$WT_LIB_DIR/helpers.sh"
# shellcheck disable=SC1091
source "$WT_LIB_DIR/git.sh"
# shellcheck disable=SC1091
source "$WT_LIB_DIR/config.sh"
# shellcheck disable=SC1091
source "$WT_LIB_DIR/core.sh"
# shellcheck disable=SC1091
source "$WINDOWS_SHELL_LIB"

usage() {
  cat <<'EOF'
usage:
  scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh [options]

options:
  --cwd PATH           Resolve the project agent CLI from this repository path. Default: current directory
  --variant MODE       default, light, or dark. Default: default
  --distro NAME        Override the WSL distro name embedded in the generated PowerShell script
  --desktop-path PATH  Override the Windows Desktop path (WSL path form)
  --output-path PATH   Write the generated PowerShell wrapper to this exact WSL path
  --output-name NAME   File name under the desktop path. Default: measure-hybrid-wsl-agent-startup-<repo>.ps1
  -h, --help           Show this help

This command resolves the current project's configured agent CLI through the
same worktree-task config chain used by the tmux-agent provider, then writes a
Windows PowerShell wrapper script onto the Desktop that runs the generic
measure-hybrid-wsl-agent-startup.ps1 template with those resolved defaults.
EOF
}

ps_quote() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

resolve_windows_desktop_wsl_path() {
  local sync_target_file="$REPO_ROOT/.sync-target"
  local sync_target=""
  local desktop_win=""
  local users_dir="/mnt/c/Users"
  local candidate=""
  local profile=""
  local -a user_profiles=()

  if [[ -f "$sync_target_file" ]]; then
    sync_target="$(< "$sync_target_file")"
    sync_target="$(wt_trim "$sync_target")"
    if [[ -n "$sync_target" && -d "$sync_target/Desktop" ]]; then
      printf '%s\n' "$sync_target/Desktop"
      return 0
    fi
  fi

  if [[ -n "${USERPROFILE:-}" ]] && command -v wslpath >/dev/null 2>&1; then
    candidate="$(wslpath -u "$USERPROFILE" 2>/dev/null || true)"
    if [[ -n "$candidate" && -d "$candidate/Desktop" ]]; then
      printf '%s\n' "$candidate/Desktop"
      return 0
    fi
  fi

  if [[ -d "$users_dir" ]]; then
    for profile in "$users_dir"/*; do
      profile="$(basename "$profile")"
      case "$profile" in
        All\ Users|Default|Default\ User|Public|desktop.ini)
          continue
          ;;
      esac
      [[ -d "$users_dir/$profile/Desktop" ]] || continue
      user_profiles+=("$users_dir/$profile")
    done
    if [[ ${#user_profiles[@]} -eq 1 ]]; then
      printf '%s/Desktop\n' "${user_profiles[0]}"
      return 0
    fi
  fi

  if command -v powershell.exe >/dev/null 2>&1; then
    desktop_win="$(windows_run_powershell_command_utf8 "[Environment]::GetFolderPath('Desktop')" | tr -d '\r' | tail -n 1)"
  fi

  [[ -n "$desktop_win" ]] || wt_die "failed to resolve Windows Desktop path; use --desktop-path"

  if command -v wslpath >/dev/null 2>&1; then
    wslpath -u "$desktop_win"
    return 0
  fi

  wt_die "wslpath is required to convert the Windows Desktop path; use --desktop-path"
}

resolve_command_spec_for_variant() {
  local variant="${1:?missing variant}"
  local command_spec="${WT_PROVIDER_AGENT_COMMAND:-}"

  case "$variant" in
    default)
      ;;
    light)
      if [[ -n "${WT_PROVIDER_AGENT_COMMAND_LIGHT:-}" ]]; then
        command_spec="${WT_PROVIDER_AGENT_COMMAND_LIGHT}"
      fi
      ;;
    dark)
      if [[ -n "${WT_PROVIDER_AGENT_COMMAND_DARK:-}" ]]; then
        command_spec="${WT_PROVIDER_AGENT_COMMAND_DARK}"
      fi
      ;;
    *)
      wt_die "unsupported variant: $variant"
      ;;
  esac

  [[ -n "$command_spec" ]] || wt_die "resolved agent profile has no command for variant '$variant'"
  printf '%s\n' "$command_spec"
}

parse_command_spec() {
  local spec="${1:?missing command spec}"

  python3 - "$spec" <<'PY'
import shlex
import sys

spec = sys.argv[1]
for part in shlex.split(spec):
    print(part)
PY
}

wsl_path_to_unc() {
  local distro="${1:?missing distro}"
  local path="${2:?missing path}"

  python3 - "$distro" "$path" <<'PY'
import sys

distro = sys.argv[1]
path = sys.argv[2]
parts = [p for p in path.split("/") if p]
unc = r"\\wsl$\%s" % distro
if parts:
    unc += "\\" + "\\".join(parts)
print(unc)
PY
}

write_wrapper_script() {
  local output_path="${1:?missing output path}"
  local distro="${2:?missing distro}"
  local repo_root="${3:?missing repo root}"
  local template_unc_path="${4:?missing template path}"
  local login_shell="${5:?missing login shell}"
  local agent_name="${6:?missing agent name}"
  shift 6
  local interactive_args=("$@")

  {
    printf 'param([switch]$Pause = $true)\n\n'
    printf '$TemplatePath = %s\n' "$(ps_quote "$template_unc_path")"
    printf '$Params = @{\n'
      printf '  Distro = %s\n' "$(ps_quote "$distro")"
    printf '  RepoRoot = %s\n' "$(ps_quote "$repo_root")"
    printf '  LoginShell = %s\n' "$(ps_quote "$login_shell")"
    printf '  AgentName = %s\n' "$(ps_quote "$agent_name")"
    printf '  AgentInteractiveArgs = @(\n'
    local arg
    for arg in "${interactive_args[@]}"; do
      printf '    %s\n' "$(ps_quote "$arg")"
    done
    printf '  )\n'
    printf '}\n\n'
    printf 'if ($Pause) {\n'
    printf '  $Params.Pause = $true\n'
    printf '}\n\n'
    printf '& $TemplatePath @Params\n'
  } > "$output_path"
}

cwd="${PWD}"
variant="default"
distro="${WSL_DISTRO_NAME:-}"
desktop_path=""
output_path=""
output_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)
      [[ $# -ge 2 ]] || wt_die "--cwd requires a value"
      cwd="$2"
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || wt_die "--variant requires a value"
      variant="$2"
      shift 2
      ;;
    --distro)
      [[ $# -ge 2 ]] || wt_die "--distro requires a value"
      distro="$2"
      shift 2
      ;;
    --desktop-path)
      [[ $# -ge 2 ]] || wt_die "--desktop-path requires a value"
      desktop_path="$2"
      shift 2
      ;;
    --output-path)
      [[ $# -ge 2 ]] || wt_die "--output-path requires a value"
      output_path="$2"
      shift 2
      ;;
    --output-name)
      [[ $# -ge 2 ]] || wt_die "--output-name requires a value"
      output_name="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      wt_die "unknown option: $1"
      ;;
  esac
done

[[ -n "$distro" ]] || wt_die "failed to resolve WSL distro name; use --distro"

wt_core_resolve_repo_context "$cwd"
wt_config_load

command_spec="$(resolve_command_spec_for_variant "$variant")"
mapfile -t command_parts < <(parse_command_spec "$command_spec")
[[ ${#command_parts[@]} -gt 0 ]] || wt_die "resolved command is empty"

agent_name="${command_parts[0]}"
interactive_args=("${command_parts[@]:1}")
login_shell="${WT_PROVIDER_LOGIN_SHELL:-${SHELL:-}}"
if [[ -z "$login_shell" ]]; then
  for login_shell in /bin/zsh /usr/bin/zsh /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    [[ -x "$login_shell" ]] && break
  done
fi
[[ -n "$login_shell" ]] || wt_die "failed to resolve login shell"

if [[ -z "$output_path" ]]; then
  if [[ -z "$desktop_path" ]]; then
    desktop_path="$(resolve_windows_desktop_wsl_path)"
  fi
  mkdir -p "$desktop_path"
  if [[ -z "$output_name" ]]; then
    output_name="measure-hybrid-wsl-agent-startup-${WT_REPO_LABEL}.ps1"
  fi
  output_path="$desktop_path/$output_name"
fi

template_unc_path="$(wsl_path_to_unc "$distro" "$REPO_ROOT/scripts/dev/measure-hybrid-wsl-agent-startup.ps1")"

write_wrapper_script "$output_path" "$distro" "$REPO_ROOT" "$template_unc_path" "$login_shell" "$agent_name" "${interactive_args[@]}"

printf 'Wrote Desktop agent CLI startup script:\n'
printf '  %s\n' "$output_path"
printf 'Resolved repo context:\n'
printf '  cwd=%s\n' "$WT_RESOLVED_CWD"
printf '  repo_root=%s\n' "$WT_REPO_ROOT"
printf 'Resolved agent command:\n'
printf '  profile=%s\n' "${WT_PROVIDER_AGENT_PROFILE:-}"
printf '  variant=%s\n' "$variant"
printf '  login_shell=%s\n' "$login_shell"
printf '  command=%s\n' "$command_spec"
