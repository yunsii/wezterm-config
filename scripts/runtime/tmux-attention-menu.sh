#!/usr/bin/env bash
# Wrapper that opens the agent-attention picker in a centered tmux popup.
#
# Bound to M-/ from tmux.conf. Performance shape mirrors tmux-worktree-menu:
#   1. Read state.json + the live-panes.json snapshot (written by the
#      WezTerm-side `attention.overlay` handler one keystroke ago) here in
#      the *outer* shell, so the popup body never spends time on jq /
#      filesystem work.
#   2. Run the row-building jq pipeline once and write the resulting tuples
#      to a TSV prefetch file. picker.sh just slurps the file with bash
#      builtins.
#   3. Pre-render the very first frame to a tmp file using the shared
#      renderer. picker.sh's first action — before any sourcing — is to
#      write that frame to its own pty, so popup content lands within
#      milliseconds regardless of cold-cache lib-sourcing variance.
#   4. Toast and exit when there is nothing pending — no point opening a
#      popup just to display "no entries".
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/menu-bench-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/attention-state-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-attention/render.sh"

# Capture the menu.sh start time IMMEDIATELY for the diagnostic footer
# split (`L = menu_start - keypress_ts`). Anything that runs before this
# line — bash boot, tmux dispatch, the WezTerm-side Lua handler — gets
# attributed to bucket L; anything after gets attributed to bucket M
# (menu work) or bucket P (picker init).
# Use bash 5's EPOCHREALTIME builtin (microsecond precision, zero fork)
# instead of `date +%s%3N` for menu_start_ts. The `date` fork costs
# ~5ms cold; we capture this stamp on the hot path before any work,
# so saving the fork shaves time off the L bucket of the diagnostic
# footer too.
menu_start_ts=$(( ${EPOCHREALTIME//./} / 1000 ))

# Microbench short-circuit for scripts/dev/bench-menu-prep.sh — see menu-bench-lib.sh.
menu_bench_init
bench_mark sourced

# Inline cheap forms of start_ms and trace_id using bash 5 builtins
# (EPOCHREALTIME / EPOCHSECONDS / RANDOM) so we never fork `date` for
# either. trace_id is a placeholder that the live-panes.json read below
# will overwrite when the lua handler stamped one — a single Alt+/
# generates ONE trace_id used by lua, this menu, and the picker.
start_ms=$(( ${EPOCHREALTIME//./} / 1000 ))
trace_id="attention-$EPOCHSECONDS-$$-$RANDOM"

# menu.sh no longer reads attention.json directly — picker_rows in
# the live-panes snapshot is the unified source (compute_picker_data
# in attention.lua). state_read is kept as a no-op for the bench
# trace, since downstream tooling parses the bench timeline by stage
# label.
live_panes_path="$(attention_live_panes_path)"
bench_mark state_read

# Live-window set per tmux socket, built only when the snapshot has at
# least one recent row so the typical "no recent yet" hot path pays
# nothing extra. Recent rows whose recorded (socket, window) is no
# longer alive get filtered out at the final TSV-projection step
# below. Window (not pane) is the gate: a worktree window routinely
# recycles panes after split/kill, and Enter can still select-window
# then land on a live pane in that window.
alive_windows_json='{}'
recent_sockets=''
if [[ -s "$live_panes_path" ]]; then
  recent_sockets="$(jq -r '[.picker_rows[]? | select(.status == "recent") | .tmux_socket // "" | select(length > 0)] | unique | .[]' "$live_panes_path" 2>/dev/null || printf '')"
fi
if [[ -n "$recent_sockets" ]]; then
  alive_pieces=()
  while IFS= read -r sock; do
    [[ -z "$sock" ]] && continue
    wins_raw="$(tmux -S "$sock" list-windows -a -F '#{window_id}' 2>/dev/null || printf '')"
    alive_pieces+=("$(jq -n --arg s "$sock" --arg w "$wins_raw" \
      '{($s): ($w | split("\n") | map(select(length > 0)))}')")
  done <<<"$recent_sockets"
  if (( ${#alive_pieces[@]} > 0 )); then
    alive_windows_json="$(printf '%s\n' "${alive_pieces[@]}" | jq -s 'add')"
  fi
fi
bench_mark alive_panes

# `now_ms` and the cheap-empty-state shortcut both use bash builtins —
# zero forks. The previous explicit `jq -r '.entries | length'` count
# check (~5ms cold jq spawn per call) is redundant: an empty .entries
# also produces zero rows from the main pipeline below, which we already
# detect via item_count. Skip it.
now_ms=$(( ${EPOCHREALTIME//./} / 1000 ))

# Live pane → workspace / tab map.
# Just read .panes — no freshness gate, no trace adoption. WezTerm's
# update-status tick re-writes this snapshot every
# attention.LIVE_SNAPSHOT_INTERVAL_MS (1s) so it is virtually always
# fresh; on the cold-restart edge (snapshot survives a WezTerm process
# swap) the keys may briefly point at the previous instance's panes,
# but the first update-status tick after wezterm.lua loads (≤250ms)
# overwrites them. Earlier versions defended against staleness with a
# three-segment ts+trace+panes split and a 5s freshness gate, which
# kept tripping on cross-WSL/Windows write→read races.
#
# The `panes` and `sessions` maps that the previous jq pipeline read
# from this file are no longer needed at the menu layer — picker_rows
# is precomputed Lua-side. Keep the bench_mark for trace alignment.
bench_mark live_map

# Picker rows now come pre-built from the wezterm-side snapshot
# (attention.lua compute_picker_data). The badge counters and these
# rows are produced from the same Lua predicate, so they cannot drift
# out of sync — the picker stays a renderer instead of a parallel
# filter pipeline.
#
# Shell-side still applies one final filter that wezterm cannot answer
# from Lua: hiding recent rows whose tmux window is no longer alive
# (rows would render but select-window would dead-end). The active
# block does not need this — an active entry implies a recent hook
# fire, which implies the tmux pane existed seconds ago.
#
# TSV layout per row (10 tab-separated fields):
#   status \t body \t age \t id \t wezterm_pane_id \t tmux_socket \t
#   tmux_window \t tmux_pane \t last_status \t tmux_session
#
#   - status:       "running" | "waiting" | "done" | "recent" | "__sentinel__"
#   - id:           session_id for active; "recent::<sid>::<archived_ts>"
#                   for recent; "__clear_all__" for the sentinel
#   - last_status / tmux_session live at the trailing edge so empty
#     middle fields cannot collapse via bash IFS=$'\t' read.
rows_tsv="$(jq -r --argjson alive "$alive_windows_json" '
  (.picker_rows // []) | .[]
  | . as $r
  | ($r.tmux_socket // "") as $s
  | ($r.tmux_window // "") as $w
  | (if ($r.status == "recent")
       then ($s != "" and $w != "" and (($alive[$s] // []) | index($w)) != null)
       else true end) as $alive_ok
  | select($alive_ok)
  | "\($r.status)\t\($r.body)\t\($r.age_text)\t\($r.id)\t\($r.wezterm_pane_id // "")\t\($r.tmux_socket // "")\t\($r.tmux_window // "")\t\($r.tmux_pane // "")\t\($r.last_status // "")\t\($r.tmux_session // "")"
' "$live_panes_path" 2>/dev/null || printf '')"
bench_mark jq_rows

# Session-bridge Ctrl+K w watch jobs (same TSV shape; status=sb).
sb_rows_tsv=""
if [[ -x "$script_dir/session-bridge-watch-picker-rows.sh" || -f "$script_dir/session-bridge-watch-picker-rows.sh" ]]; then
  sb_rows_tsv="$(bash "$script_dir/session-bridge-watch-picker-rows.sh" 2>/dev/null || printf '')"
fi
if [[ -n "$sb_rows_tsv" ]]; then
  if [[ -n "$rows_tsv" ]]; then
    rows_tsv+=$'\n'"$sb_rows_tsv"
  else
    rows_tsv="$sb_rows_tsv"
  fi
fi
bench_mark sb_watch_rows

if [[ -z "$rows_tsv" ]]; then
  tmux display-message -d 1500 'No pending agent attention / SB watch'
  runtime_log_info attention "popup menu skipped — empty rows" \
    "trace=$trace_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

# Drop into parallel arrays for the in-process pre-render, AND mirror to a
# tmp TSV so picker.sh can re-build the same arrays via a single bash
# `read` loop without re-running jq inside the popup pty.
prefetch_file="$(mktemp -t wezterm-attention-picker.XXXXXX)"
row_status=()
row_body=()
row_age=()
row_last_status=()
while IFS=$'\t' read -r s b a id wp sock win pane ls tsess; do
  [[ -n "$s" ]] || continue
  row_status+=("$s")
  row_body+=("$b")
  row_age+=("$a")
  row_last_status+=("$ls")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$s" "$b" "$a" "$id" "$wp" "$sock" "$win" "$pane" "$ls" "$tsess" >> "$prefetch_file"
done <<<"$rows_tsv"

item_count="${#row_status[@]}"
if (( item_count == 0 )); then
  rm -f "$prefetch_file"
  tmux display-message -d 1500 'No pending agent attention'
  runtime_log_info attention "popup menu skipped — empty after parse" \
    "trace=$trace_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi

# Append the destructive sentinel as the last row (TSV id = __clear_all__).
row_status+=("__sentinel__")
row_body+=("clear all · ${item_count} entries")
row_age+=("")
row_last_status+=("")
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '__sentinel__' "clear all · ${item_count} entries" '' '__clear_all__' '' '' '' '' '' '' >> "$prefetch_file"
total_rows=$((item_count + 1))
bench_mark tsv_write

# Go-only picker (cold start ~2-5ms). Bash path is emergency-only via
# WEZTERM_ALLOW_BASH_PICKER=1 — see picker-bin-lib.sh / docs/picker-release.md.
attention_jump_script="$script_dir/attention-jump.sh"
# shellcheck disable=SC1091
. "$script_dir/picker-bin-lib.sh"

# Pin the picker onto the file transport: it always runs inside
# `tmux display-popup -E`, whose sub-pty does NOT forward DCS pass-through
# to the parent client tty, so the OSC route would be silently dropped.
# Inject WEZBUS_EVENT_DIR so the picker doesn't redo wezterm-runtime path
# detection from inside the popup.
# shellcheck disable=SC1091
. "$script_dir/wezterm-event-lib.sh"
picker_event_dir="$(wezterm_event_dir)"
mkdir -p "$picker_event_dir" 2>/dev/null || true

# Keypress reference: read .ts off the same snapshot we just consumed
# for the live map. The Lua handler stamps it on every press-time write
# AND on every periodic tick, so this is at most LIVE_SNAPSHOT_INTERVAL_MS
# behind the actual press. Used by the picker footer's lua+menu+picker
# breakdown; 0 disables that segment.
keypress_ts=0
if [[ -s "$live_panes_path" ]]; then
  ts_raw="$(jq -r '.ts // 0' "$live_panes_path" 2>/dev/null || printf '0')"
  [[ "$ts_raw" =~ ^[0-9]+$ ]] && keypress_ts="$ts_raw"
fi

# Resolve the active wezterm workspace so the picker can rank
# current-workspace rows first and highlight the workspace badge column
# on each row. Mirrors tab-overflow-menu.sh: tmux session is the active
# pane's session, the @wezterm_workspace option is set on it by
# open-project-session.sh; default to "default" when missing.
current_workspace="$(tmux show-options -v @wezterm_workspace 2>/dev/null || true)"
if [[ -z "$current_workspace" ]]; then
  current_workspace="default"
fi

picker_binary=""
picker_rc=0
picker_binary="$(picker_bin_require "$script_dir" "Alt+/")" || picker_rc=$?
prefetch_frame_file=''
if (( picker_rc == 1 )); then
  rm -f "$prefetch_file"
  exit 0
fi
if (( picker_rc == 0 )); then
  bench_mark picker_branch
  # Capture menu_done_ts as late as possible (right before launching the
  # popup) so bucket M reflects all of menu.sh's actual work. Inline
  # EPOCHREALTIME (µs/1000 → ms) avoids the ~5ms `date` fork.
  menu_done_ts=$(( ${EPOCHREALTIME//./} / 1000 ))
  # SESSION_BRIDGE_SH: Alt+/ `x` on ◆ SB rows runs watch-stop --id.
  session_bridge_sh="$(cd "$script_dir/../.." && pwd)/openclaw/scripts/session-bridge.sh"
  picker_command="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") WEZTERM_EVENT_FORCE_FILE=1 WEZBUS_EVENT_DIR=$(printf %q "$picker_event_dir") SESSION_BRIDGE_SH=$(printf %q "$session_bridge_sh") WEZTERM_REPO=$(printf %q "$(cd "$script_dir/../.." && pwd)") $(printf %q "$picker_binary") attention $(printf %q "$prefetch_file") $(printf %q "$attention_jump_script") $(printf %q "$current_workspace") $(printf %q "$keypress_ts") $(printf %q "$menu_start_ts") $(printf %q "$menu_done_ts")"
  picker_kind='go'
else
  # WEZTERM_ALLOW_BASH_PICKER=1 emergency path.
  prefetch_frame_file="$(mktemp -t wezterm-attention-frame.XXXXXX)"
  client_width="$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 100)"
  client_height="$(tmux display-message -p '#{client_height}' 2>/dev/null || echo 30)"
  popup_cols=$(( client_width * 80 / 100 - 2 ))
  (( popup_cols < 20 )) && popup_cols=20
  popup_rows=$(( client_height * 70 / 100 - 2 ))
  (( popup_rows < 6 )) && popup_rows=6
  visible_rows=$(( popup_rows - 4 ))
  (( visible_rows < 1 )) && visible_rows=1
  attention_picker_emit_frame "$popup_cols" "$visible_rows" 0 "$total_rows" 0 0 0 0 > "$prefetch_frame_file"
  menu_done_ts=$(( ${EPOCHREALTIME//./} / 1000 ))
  picker_command="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") WEZTERM_EVENT_FORCE_FILE=1 WEZBUS_EVENT_DIR=$(printf %q "$picker_event_dir") bash $(printf %q "$script_dir/tmux-attention-picker.sh") $(printf %q "$prefetch_file") $(printf %q "$prefetch_frame_file") $(printf %q "$keypress_ts") $(printf %q "$menu_start_ts") $(printf %q "$menu_done_ts")"
  picker_kind='bash'
fi

bench_mark prep_done

if menu_bench_active; then
  rm -f "$prefetch_file" "$prefetch_frame_file"
  menu_bench_dump_and_exit "picker_kind=$picker_kind"
fi

if bash "$script_dir/tmux-display-popup.sh" -x C -y C -w 80% -h 70% -T 'Agent attention' -E "$picker_command"; then
  rm -f "$prefetch_file" "$prefetch_frame_file"
  runtime_log_info attention "popup menu completed" \
    "trace=$trace_id" "duration_ms=$(runtime_log_duration_ms "$start_ms")" \
    "item_count=$item_count" "picker_kind=$picker_kind"
  exit 0
fi

rm -f "$prefetch_file" "$prefetch_frame_file"
runtime_log_warn attention "popup menu failed to launch" "trace=$trace_id" "picker_kind=$picker_kind"
tmux display-message 'Agent attention popup failed to launch'
exit 1
