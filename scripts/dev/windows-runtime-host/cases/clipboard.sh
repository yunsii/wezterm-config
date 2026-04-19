#!/usr/bin/env bash

host_check_run_clipboard_case() {
  local trace_id="$1"
  local test_png="${HOST_CHECK_REPO_ROOT}/assets/copy-test.png"
  local text_payload=""
  local write_text_response=""
  local resolve_text_response=""
  local write_image_response=""
  local resolve_image_response=""

  [[ -f "$test_png" ]] || return 1
  text_payload="clipboard-smoke $(date '+%Y-%m-%d %H:%M:%S %z')"

  write_text_response="$(host_check_invoke_helper_request_capture "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"write_text","payload":{"text":%s}}' \
    "$(host_check_json_escape "${trace_id}-write-text")" \
    "$(host_check_json_escape "$text_payload")")")" || return 1
  [[ "$(host_check_env_value_from_text status "$write_text_response")" == "clipboard_written_text" ]] || return 1

  resolve_text_response="$(host_check_invoke_helper_request_capture "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"resolve_for_paste","payload":{}}' \
    "$(host_check_json_escape "${trace_id}-resolve-text")")")" || return 1
  [[ "$(host_check_env_value_from_text result_type "$resolve_text_response")" == "clipboard_text" ]] || return 1
  [[ "$(host_check_env_value_from_text result_text "$resolve_text_response")" == "$text_payload" ]] || return 1

  # Give Windows clipboard history tools enough time to register the image write
  # as a distinct update instead of coalescing it with the previous text write.
  sleep 1

  write_image_response="$(host_check_invoke_helper_request_capture "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"write_image_file","payload":{"image_path":%s}}' \
    "$(host_check_json_escape "${trace_id}-write-image")" \
    "$(host_check_json_escape "$(wslpath -w "$test_png")")")")" || return 1
  [[ "$(host_check_env_value_from_text status "$write_image_response")" == "clipboard_written_image" ]] || return 1

  resolve_image_response="$(host_check_invoke_helper_request_capture "$(printf '{"version":2,"trace_id":%s,"message_type":"request","domain":"clipboard","action":"resolve_for_paste","payload":{}}' \
    "$(host_check_json_escape "${trace_id}-resolve-image")")")" || return 1
  [[ "$(host_check_env_value_from_text result_type "$resolve_image_response")" == "clipboard_image" ]] || return 1
  [[ -n "$(host_check_env_value_from_text result_formats "$resolve_image_response")" ]] || return 1
}
