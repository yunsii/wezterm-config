#!/usr/bin/env bash

windows_powershell_quote() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

windows_run_powershell_script_utf8() {
  local script_path="${1:?missing powershell script path}"
  shift

  local command=""
  command="[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  command+="[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  command+="\$OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  command+="& (Get-Item -LiteralPath $(windows_powershell_quote "$script_path") -ErrorAction Stop).FullName"

  local arg
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      command+=" $arg"
    else
      command+=" $(windows_powershell_quote "$arg")"
    fi
  done

  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$command"
}
