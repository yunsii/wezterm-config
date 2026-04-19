#!/usr/bin/env bash

windows_powershell_quote() {
  local value="${1-}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

windows_powershell_utf8_prologue() {
  printf '%s' "[Console]::InputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  printf '%s' "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  printf '%s' "\$OutputEncoding = [System.Text.UTF8Encoding]::new(\$false); "
  printf '%s' "\$ProgressPreference = 'SilentlyContinue'; "
}

windows_run_powershell_command_utf8() {
  local script_body="${1:?missing powershell command}"

  local command="" encoded_command=""
  command="$(windows_powershell_utf8_prologue)$script_body"
  encoded_command="$(
    printf '%s' "$command" \
      | iconv -f UTF-8 -t UTF-16LE \
      | base64 \
      | tr -d '\r\n'
  )"

  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded_command"
}

windows_run_powershell_script_utf8() {
  local script_path="${1:?missing powershell script path}"
  shift

  local command=""
  command+="& (Get-Item -LiteralPath $(windows_powershell_quote "$script_path") -ErrorAction Stop).FullName"

  local arg
  for arg in "$@"; do
    if [[ "$arg" == -* ]]; then
      command+=" $arg"
    else
      command+=" $(windows_powershell_quote "$arg")"
    fi
  done

  windows_run_powershell_command_utf8 "$command"
}
