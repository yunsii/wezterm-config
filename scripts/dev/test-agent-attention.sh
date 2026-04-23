#!/usr/bin/env bash
# Self-verifying smoke test for the agent-attention pipeline.
#
# The pipeline under test:
#   emit-agent-status.sh <status>
#     → attention-state-lib.sh upserts state.json
#     → OSC 1337 attention_tick nudges WezTerm
#     → wezterm-x/lua/attention.lua reloads state, re-renders
#
# Default mode asserts state.json reflects each transition AND that the
# WezTerm diagnostics log captures the tick-driven reload, then ends with
# the pane's entry removed. Subcommands keep backwards-compat for visual
# demos and targeted emits.
#
# Usage:
#   test-agent-attention.sh                 # self-test (default)
#   test-agent-attention.sh cycle-visual    # slow human-in-the-loop demo
#   test-agent-attention.sh running [reason]
#   test-agent-attention.sh waiting [reason]
#   test-agent-attention.sh done    [reason]
#   test-agent-attention.sh cleared
#   test-agent-attention.sh resolved        # PostToolUse: waiting/missing → running; running/done no-op
#   test-agent-attention.sh clear-all       # truncate state.json + nudge
#   test-agent-attention.sh show            # print current state.json

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
hook="$repo_root/scripts/claude-hooks/emit-agent-status.sh"

# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/windows-runtime-paths-lib.sh"
# shellcheck disable=SC1091
. "$repo_root/scripts/runtime/attention-state-lib.sh"

require_pane_context() {
  if [[ ! -e /dev/tty ]]; then
    echo "no /dev/tty — run this from an interactive WezTerm pane" >&2
    exit 1
  fi
  if [[ ! -x "$hook" ]]; then
    echo "hook emitter missing or not executable: $hook" >&2
    exit 1
  fi
}

resolve_log_file() {
  if ! windows_runtime_detect_paths; then
    echo "could not resolve Windows runtime paths (hybrid-wsl only)" >&2
    exit 1
  fi
  printf '%s/logs/wezterm.log' "$WINDOWS_RUNTIME_STATE_WSL"
}

emit_status() {
  local status="$1" reason="${2:-}"
  local payload
  if [[ -n "$reason" ]] && command -v jq >/dev/null 2>&1; then
    local encoded_reason
    encoded_reason="$(printf '%s' "$reason" | jq -Rs .)"
    payload="$(printf '{"hook_event_name":"test","session_id":"pane:%s","message":%s}' \
      "${WEZTERM_PANE:-unknown}" "$encoded_reason")"
  else
    payload="$(printf '{"hook_event_name":"test","session_id":"pane:%s"}' \
      "${WEZTERM_PANE:-unknown}")"
  fi
  printf '%s' "$payload" | "$hook" "$status"
}

state_entry_for_current_pane() {
  local sid="pane:${WEZTERM_PANE:-unknown}"
  attention_state_read | jq --arg sid "$sid" '.entries[$sid] // null'
}

baseline_line_count() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -l < "$file" | tr -d '[:space:]'
  else
    echo 0
  fi
}

wait_for_log_line() {
  local file="$1" baseline="$2"
  local timeout_ticks=60
  local tick=0
  while (( tick < timeout_ticks )); do
    if [[ -f "$file" ]]; then
      if awk -v start="$baseline" 'NR > start' "$file" \
        | grep -qE 'category="attention" message="tick received"'; then
        return 0
      fi
    fi
    sleep 0.1
    tick=$((tick + 1))
  done
  return 1
}

verify_upsert() {
  local log_file="$1" status="$2" reason="$3"
  local baseline entry entry_status entry_reason
  baseline="$(baseline_line_count "$log_file")"

  emit_status "$status" "$reason"

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    printf '  FAIL  %s: no entry in state.json\n' "$status"
    return 1
  fi
  entry_status="$(printf '%s' "$entry" | jq -r '.status')"
  if [[ "$entry_status" != "$status" ]]; then
    printf '  FAIL  %s: state.json.status is %s\n' "$status" "$entry_status"
    return 1
  fi
  if [[ -n "$reason" ]]; then
    entry_reason="$(printf '%s' "$entry" | jq -r '.reason')"
    if [[ "$entry_reason" != "$reason" ]]; then
      printf '  FAIL  %s: state.json.reason is %s (want %s)\n' "$status" "$entry_reason" "$reason"
      return 1
    fi
  fi

  if ! wait_for_log_line "$log_file" "$baseline"; then
    printf '  FAIL  %s: no tick log within 6s\n' "$status"
    return 1
  fi

  printf '  PASS  %s\n' "$status"
  return 0
}

verify_cleared() {
  local log_file="$1"
  local baseline entry
  baseline="$(baseline_line_count "$log_file")"

  emit_status cleared ''

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" != "null" ]]; then
    printf '  FAIL  cleared: entry still present (%s)\n' "$entry"
    return 1
  fi
  if ! wait_for_log_line "$log_file" "$baseline"; then
    printf '  FAIL  cleared: no tick log within 6s\n'
    return 1
  fi
  printf '  PASS  cleared\n'
}

# PostToolUse semantics. `waiting` flips to `running` in place; `missing`
# upserts a fresh `running` (focus-ack may have forgot the waiting entry
# before the hook fired, but running still needs to reflect that Claude
# is mid-turn); `running` and `done` are no-ops so auto-allowed tools do
# not spam OSC ticks or stomp a Stop that landed between tool calls.
verify_resolved_transitions_waiting() {
  local entry entry_status
  emit_status waiting 'self-test: resolved-from-waiting'
  emit_status resolved ''

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    printf '  FAIL  resolved: entry dropped (should transition to running)\n'
    return 1
  fi
  entry_status="$(printf '%s' "$entry" | jq -r '.status')"
  if [[ "$entry_status" != "running" ]]; then
    printf '  FAIL  resolved: status is %s (want running)\n' "$entry_status"
    return 1
  fi
  printf '  PASS  resolved (waiting → running)\n'
}

verify_resolved_creates_running_when_missing() {
  local entry entry_status entry_reason
  emit_status cleared ''
  emit_status resolved ''

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    printf '  FAIL  resolved: no entry after upsert (expected running)\n'
    return 1
  fi
  entry_status="$(printf '%s' "$entry" | jq -r '.status')"
  if [[ "$entry_status" != "running" ]]; then
    printf '  FAIL  resolved: status is %s (want running)\n' "$entry_status"
    return 1
  fi
  entry_reason="$(printf '%s' "$entry" | jq -r '.reason')"
  if [[ "$entry_reason" != "" ]]; then
    printf '  FAIL  resolved: reason is %q (want empty)\n' "$entry_reason"
    return 1
  fi
  printf '  PASS  resolved (missing → running)\n'
}

verify_resolved_noop_when_running() {
  local entry entry_status entry_reason marker
  marker='self-test: resolved-noop-running'
  emit_status running "$marker"
  emit_status resolved ''

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    printf '  FAIL  resolved: running entry was dropped\n'
    return 1
  fi
  entry_status="$(printf '%s' "$entry" | jq -r '.status')"
  if [[ "$entry_status" != "running" ]]; then
    printf '  FAIL  resolved: status is %s (want running)\n' "$entry_status"
    return 1
  fi
  entry_reason="$(printf '%s' "$entry" | jq -r '.reason')"
  if [[ "$entry_reason" != "$marker" ]]; then
    printf '  FAIL  resolved: reason overwritten (%s → %s)\n' "$marker" "$entry_reason"
    return 1
  fi
  printf '  PASS  resolved no-op (running stays running)\n'
}

verify_resolved_noop_when_done() {
  local entry entry_status entry_reason marker
  marker='self-test: resolved-noop-done'
  emit_status done "$marker"
  emit_status resolved ''

  entry="$(state_entry_for_current_pane)"
  if [[ "$entry" == "null" || -z "$entry" ]]; then
    printf '  FAIL  resolved: done entry was dropped\n'
    return 1
  fi
  entry_status="$(printf '%s' "$entry" | jq -r '.status')"
  if [[ "$entry_status" != "done" ]]; then
    printf '  FAIL  resolved: status is %s (want done)\n' "$entry_status"
    return 1
  fi
  entry_reason="$(printf '%s' "$entry" | jq -r '.reason')"
  if [[ "$entry_reason" != "$marker" ]]; then
    printf '  FAIL  resolved: reason overwritten (%s → %s)\n' "$marker" "$entry_reason"
    return 1
  fi
  printf '  PASS  resolved no-op (done stays done)\n'
}

cmd_self_test() {
  require_pane_context
  local log_file
  log_file="$(resolve_log_file)"
  if [[ ! -f "$log_file" ]]; then
    echo "wezterm diagnostics log not found: $log_file" >&2
    echo "has WezTerm been reloaded with attention.lua in place?" >&2
    exit 1
  fi

  echo "self-test: state=$(attention_state_path) log=$log_file"
  local failures=0
  verify_upsert "$log_file" running 'self-test: running' || failures=$((failures + 1))
  verify_upsert "$log_file" waiting 'self-test: waiting' || failures=$((failures + 1))
  verify_upsert "$log_file" done    'self-test: done'    || failures=$((failures + 1))
  verify_resolved_transitions_waiting                    || failures=$((failures + 1))
  verify_resolved_creates_running_when_missing           || failures=$((failures + 1))
  verify_resolved_noop_when_running                      || failures=$((failures + 1))
  verify_resolved_noop_when_done                         || failures=$((failures + 1))
  verify_cleared "$log_file"                             || failures=$((failures + 1))

  if (( failures > 0 )); then
    echo "FAILED (${failures}/8)"
    exit 1
  fi
  echo "OK 8/8"
}

cmd_cycle_visual() {
  require_pane_context
  local pause=3
  echo "[1/4] running  (hold ${pause}s)"; emit_status running 'visual: running'
  sleep "$pause"
  echo "[2/4] waiting  (hold ${pause}s)"; emit_status waiting 'visual: waiting'
  sleep "$pause"
  echo "[3/4] done     (hold ${pause}s)"; emit_status done 'visual: done'
  sleep "$pause"
  echo "[4/4] cleared"; emit_status cleared ''
}

cmd_single() {
  require_pane_context
  emit_status "$1" "${2:-}"
  printf 'emitted %s\n' "$1"
}

cmd_clear_all() {
  require_pane_context
  attention_state_truncate
  # Nudge WezTerm so it reloads and drops badges / counts immediately.
  if [[ -e /dev/tty ]]; then
    local encoded seq tick_ms
    tick_ms="$(attention_state_now_ms)"
    encoded="$(printf '%s' "$tick_ms" | base64 | tr -d '\n')"
    seq="$(printf '\033]1337;SetUserVar=attention_tick=%s\007' "$encoded")"
    if [[ -n "${TMUX-}" ]]; then
      local escaped="${seq//$'\033'/$'\033\033'}"
      printf '\033Ptmux;%s\033\\' "$escaped" >/dev/tty 2>/dev/null || true
    else
      printf '%s' "$seq" >/dev/tty 2>/dev/null || true
    fi
  fi
  echo "truncated $(attention_state_path)"
}

cmd_show() {
  attention_state_read | jq .
}

case "${1:-self-test}" in
  self-test|"")                           cmd_self_test ;;
  cycle-visual)                           cmd_cycle_visual ;;
  running|waiting|done|cleared|resolved)  cmd_single "$1" "${2:-}" ;;
  clear-all)                              cmd_clear_all ;;
  show)                                   cmd_show ;;
  -h|--help)
    sed -n '3,19p' "$0"
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    echo "try: $0 --help" >&2
    exit 1
    ;;
esac
