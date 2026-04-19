#!/usr/bin/env bash

host_check_run_vscode_case() {
  local trace_id="$1"
  local code_exe=""

  code_exe="$(host_check_detect_vscode_exe)"
  host_check_invoke_helper_request "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"vscode","action":"focus_or_open","payload":{"requested_dir":%s,"distro":%s,"code_command":[%s]}}' \
    "$(host_check_json_escape "$trace_id")" \
    "$(host_check_json_escape "$HOST_CHECK_TARGET_DIR")" \
    "$(host_check_json_escape "$HOST_CHECK_DISTRO")" \
    "$(host_check_json_escape "$code_exe")")" || return 1

  host_check_wait_for_trace_event "$trace_id" "helper completed request.*status=\"(reused|launched)\""
}
