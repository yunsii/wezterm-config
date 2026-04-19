#!/usr/bin/env bash

host_check_run_chrome_case() {
  local trace_id="$1"
  local chrome_profile=""
  local expect_reuse=0

  chrome_profile="$(host_check_detect_chrome_profile_dir || true)"
  if [[ -z "$chrome_profile" ]]; then
    host_check_warn "chrome profile is not configured; skipping chrome request test"
    return 0
  fi

  if host_check_chrome_registry_has_entry || host_check_chrome_process_exists "$chrome_profile"; then
    expect_reuse=1
  fi

  host_check_invoke_helper_request "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"chrome","action":"focus_or_start","payload":{"chrome_path":%s,"remote_debugging_port":9222,"user_data_dir":%s}}' \
    "$(host_check_json_escape "$trace_id")" \
    "$(host_check_json_escape "chrome.exe")" \
    "$(host_check_json_escape "$chrome_profile")")" || return 1

  if (( expect_reuse == 1 )); then
    host_check_wait_for_trace_event "$trace_id" "helper completed request.*status=\"reused\"" || return 1
    host_check_wait_for_trace_event "$trace_id" "(focused cached debug chrome window|rebound existing debug chrome window)" || return 1
    return 0
  fi

  host_check_wait_for_trace_event "$trace_id" "helper completed request.*status=\"(reused|launched|launch_handoff_existing)\"" || return 1
  host_check_wait_for_trace_event "$trace_id" "(focused cached debug chrome window|rebound existing debug chrome window|bound launched debug chrome window|launched debug chrome)" || return 1
  if host_check_wait_for_trace_event "$trace_id" "launched debug chrome but did not bind a reusable window"; then
    return 1
  fi

  return 0
}
