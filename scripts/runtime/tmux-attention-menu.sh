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

# In-script microbench instrumentation. Enabled by setting
# WEZTERM_BENCH_NO_POPUP=1 in the env. When enabled, every `bench_mark
# <stage>` records µs-since-start (via EPOCHREALTIME — zero fork, ~ns
# cost), and right before `tmux display-popup` we dump a `__BENCH__`
# line and exit instead of opening the popup. This lets
# scripts/dev/bench-menu-prep.sh drive N runs without disrupting the
# user's screen. Unset env var → all bench_* calls are inert no-ops.
if [[ -n "${WEZTERM_BENCH_NO_POPUP:-}" ]]; then
  bench_marks=()
  bench_t0="${EPOCHREALTIME//./}"
  bench_mark() { bench_marks+=("$1=$((${EPOCHREALTIME//./} - bench_t0))"); }
else
  bench_mark() { :; }
fi
bench_mark sourced

# Inline cheap forms of start_ms and trace_id using bash 5 builtins
# (EPOCHREALTIME / EPOCHSECONDS / RANDOM) so we never fork `date` for
# either. trace_id is a placeholder that the live-panes.json read below
# will overwrite when the lua handler stamped one — a single Alt+/
# generates ONE trace_id used by lua, this menu, and the picker.
start_ms=$(( ${EPOCHREALTIME//./} / 1000 ))
trace_id="attention-$EPOCHSECONDS-$$-$RANDOM"

# Skip attention_state_init in the read-only menu hot path: it does
# mkdir + a /mnt/c stat to check if the file exists, costing 5-10ms
# of pure cross-FS overhead per invocation. attention_state_read
# already returns empty JSON when the file is missing, so init is
# only useful for writers (hooks). Drop it here.
state_json="$(attention_state_read)"
bench_mark state_read

# Live-pane set per tmux socket, built only when .recent[] is non-empty
# so the typical "no recent yet" hot path pays nothing extra. Recent
# rows whose recorded (socket, pane) is no longer alive get filtered out
# of display below — jump-time has its own redundant probe to catch the
# race where the pane dies between menu render and Enter, but doing it
# here too keeps the picker from showing rows that can't be jumped.
alive_panes_json='{}'
recent_sockets="$(jq -r '[(.recent // [])[] | (.tmux_socket // "") | select(length > 0)] | unique | .[]' <<<"$state_json" 2>/dev/null || printf '')"
if [[ -n "$recent_sockets" ]]; then
  alive_pieces=()
  while IFS= read -r sock; do
    [[ -z "$sock" ]] && continue
    panes_raw="$(tmux -S "$sock" list-panes -a -F '#{pane_id}' 2>/dev/null || printf '')"
    alive_pieces+=("$(jq -n --arg s "$sock" --arg p "$panes_raw" \
      '{($s): ($p | split("\n") | map(select(length > 0)))}')")
  done <<<"$recent_sockets"
  if (( ${#alive_pieces[@]} > 0 )); then
    alive_panes_json="$(printf '%s\n' "${alive_pieces[@]}" | jq -s 'add')"
  fi
fi
bench_mark alive_panes

# `now_ms` and the cheap-empty-state shortcut both use bash builtins —
# zero forks. The previous explicit `jq -r '.entries | length'` count
# check (~5ms cold jq spawn per call) is redundant: an empty .entries
# also produces zero rows from the main pipeline below, which we already
# detect via item_count. Skip it.
now_ms=$(( ${EPOCHREALTIME//./} / 1000 ))

# Live pane → workspace / tab map. Single jq call (instead of the
# previous two: ts extract + panes extract) — packs both fields into
# one stdout buffer that bash splits via parameter expansion. Saves
# one cold jq spawn (~5ms) plus one /mnt/c file read (the file is
# already in the page cache after the first jq).
live_map='{}'
snapshot_ts=0
live_panes_path="$(attention_live_panes_path)"
if [[ -s "$live_panes_path" ]]; then
  combined="$(jq -rc '"\(.ts // 0)\(.trace // "")\(.panes // {} | tojson)"' "$live_panes_path" 2>/dev/null || printf '')"
  # Three SOH-delimited fields: ts | trace | panes_json. SOH (\x01)
  # is guaranteed not to appear in any of them (numeric, hyphen-and-
  # alnum trace_id, JSON-escaped tojson output).
  if [[ -n "$combined" && "$combined" == *$'\001'*$'\001'* ]]; then
    snapshot_ts="${combined%%$'\001'*}"
    rest_after_ts="${combined#*$'\001'}"
    snapshot_trace="${rest_after_ts%%$'\001'*}"
    panes_json="${rest_after_ts#*$'\001'}"
    [[ "$snapshot_ts" =~ ^[0-9]+$ ]] || snapshot_ts=0
    snapshot_age_ms=$((now_ms - snapshot_ts))
    if (( snapshot_age_ms >= 0 && snapshot_age_ms <= 5000 )) && [[ -n "$panes_json" ]]; then
      live_map="$panes_json"
      # Adopt the lua-stamped trace_id when present so this menu run
      # + the picker that follows share one id with the wezterm.log
      # entry from the lua handler. grep one trace_id across
      # runtime.log + wezterm.log to assemble the full per-press
      # timeline of a single Alt+/.
      if [[ -n "$snapshot_trace" ]]; then
        trace_id="$snapshot_trace"
        export WEZTERM_RUNTIME_TRACE_ID="$trace_id"
      fi
    fi
  fi
fi
bench_mark live_map

# Build the per-row tuples once. Sort order matches the right-status
# counter (waiting → done → running), with archived "recent" rows appended
# last so the popup mirrors the badge order on the status bar at a glance
# while still surfacing previously-active sessions for jump-back.
#
# Row body and reason are sanitized so embedded \t / \n / \r cannot break
# the TSV split below (reason is user-facing string from the agent).
#
# TSV layout per row:
#   status \t body \t age \t id \t
#   wezterm_pane_id \t tmux_socket \t tmux_window \t tmux_pane \t last_status
#
#   - status:       "running" | "waiting" | "done" | "recent" | "__sentinel__"
#   - id:           session_id for active; "recent::<sid>::<archived_ts>"
#                   for recent; "__clear_all__" for the sentinel
#   - wezterm_pane_id, tmux_socket, tmux_window, tmux_pane: coordinates
#     the picker uses to build the OSC attention_jump payload on Enter,
#     so the popup never has to re-read state.json. Empty for the
#     __sentinel__ row.
#   - last_status:  populated only for "recent" rows (the status the
#                   entry held when it was archived); empty otherwise.
#                   Lives at the END of the row so that for active rows
#                   it is a trailing empty field — bash `read` with
#                   `IFS=$'\t'` treats consecutive tabs as one separator
#                   (tab is whitespace IFS), so an empty MIDDLE field
#                   silently shifts every following field left by one.
#                   A trailing empty is preserved correctly.
rows_tsv="$(jq -r \
  --argjson live "$live_map" \
  --argjson alive "$alive_panes_json" \
  --argjson now "$now_ms" '
  def fmt_age($ms):
    (($ms / 1000) | floor) as $s
    | if $s < 60 then "\($s)s"
      elif (($s / 60) | floor) < 60 then "\((($s / 60) | floor))m"
      else "\((($s / 3600) | floor))h"
      end;
  def status_rank($s):
    if $s == "waiting" then 0
    elif $s == "done" then 1
    elif $s == "running" then 2
    else 3 end;
  def strip_tmux_prefix($v):
    ($v // "") | tostring | sub("^[@%]"; "");
  def nonempty($v):
    ($v // "") | tostring | length > 0;
  def sanitize($s):
    ($s // "") | tostring | gsub("[\t\n\r]"; " ");
  def label_prefix($e; $L):
    (if nonempty($L.workspace) then ($L.workspace | tostring) else "?" end) as $ws
    | (if (($L.tab_index // null) != null) then
         (if nonempty($L.tab_title)
            then "\($L.tab_index)_\($L.tab_title)"
            else "\($L.tab_index | tostring)" end)
       else "?" end) as $tab
    | (if nonempty($e.tmux_window) then
         (if nonempty($e.tmux_pane)
            then "\(strip_tmux_prefix($e.tmux_window))_\(strip_tmux_prefix($e.tmux_pane))"
            else strip_tmux_prefix($e.tmux_window) end)
       else "?" end) as $tmuxseg
    | (if nonempty($e.git_branch) then ($e.git_branch | tostring) else "?" end) as $branch
    | (if ($ws == "?" and $tab == "?" and $tmuxseg == "?" and $branch == "?")
         then null
         else "\($ws)/\($tab)/\($tmuxseg)/\($branch)" end);

  ((.entries // {}) | keys) as $active_sids
  | (
      ((.entries // {}) | to_entries | map(.value)
       | sort_by([status_rank(.status), (.ts // 0)])
       | map(
           . as $e
           | ($live[($e.wezterm_pane_id // "" | tostring)] // {}) as $L
           | (($now - (($e.ts // $now) | tonumber))) as $age_ms
           | (fmt_age($age_ms)) as $age_text_base
           | (if nonempty($e.wezterm_pane_id) then $age_text_base
              else "\($age_text_base), no pane" end) as $age_text
           | (label_prefix($e; $L)) as $prefix
           | (if nonempty($e.reason) then ($e.reason | tostring) else $e.status end) as $reason
           | (if $prefix == null then $reason else "\($prefix)  \($reason)" end) as $body
           | "\($e.status)\t\(sanitize($body))\t\($age_text)\t\($e.session_id)\t\($e.wezterm_pane_id // "")\t\($e.tmux_socket // "")\t\($e.tmux_window // "")\t\($e.tmux_pane // "")\t"
         ))
      +
      ((.recent // [])
       | map(select((.session_id // "") as $sid | ($active_sids | index($sid)) == null))
       | map(select(
           (.tmux_socket // "") as $s | (.tmux_pane // "") as $p
           | ($s == "" or $p == "" or (($alive[$s] // []) | index($p)) != null)
         ))
       | sort_by(-(.archived_ts // 0))
       | map(
           . as $r
           | ($live[($r.wezterm_pane_id // "" | tostring)] // {}) as $L
           | (($now - (($r.archived_ts // $now) | tonumber))) as $age_ms
           | (fmt_age($age_ms)) as $age_text
           | (label_prefix($r; $L)) as $prefix
           | (if nonempty($r.last_reason) then ($r.last_reason | tostring) else ($r.last_status // "recent") end) as $reason
           | (if $prefix == null then $reason else "\($prefix)  \($reason)" end) as $body
           | "recent\t\(sanitize($body))\t\($age_text)\trecent::\($r.session_id)::\($r.archived_ts // 0)\t\($r.wezterm_pane_id // "")\t\($r.tmux_socket // "")\t\($r.tmux_window // "")\t\($r.tmux_pane // "")\t\($r.last_status // "")"
         ))
    )
  | .[]
' <<<"$state_json" 2>/dev/null || printf '')"
bench_mark jq_rows

if [[ -z "$rows_tsv" ]]; then
  tmux display-message -d 1500 'No pending agent attention'
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
while IFS=$'\t' read -r s b a id wp sock win pane ls; do
  [[ -n "$s" ]] || continue
  row_status+=("$s")
  row_body+=("$b")
  row_age+=("$a")
  row_last_status+=("$ls")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$s" "$b" "$a" "$id" "$wp" "$sock" "$win" "$pane" "$ls" >> "$prefetch_file"
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
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' '__sentinel__' "clear all · ${item_count} entries" '' '__clear_all__' '' '' '' '' '' >> "$prefetch_file"
total_rows=$((item_count + 1))
bench_mark tsv_write

# Prefer the static Go picker binary when present. Its cold start is
# ~2-5ms vs ~30-80ms for the bash picker (bash boot + 3 lib sources +
# render lib eval inside the popup pty), and it owns its own first
# render so menu.sh skips the bash frame priming entirely.
#
# When the binary is missing (machine without Go installed at sync time),
# fall back to the bash picker, which still expects a pre-rendered frame
# file primed via the shared render lib.
attention_jump_script="$script_dir/attention-jump.sh"
repo_root="$(cd "$script_dir/../.." && pwd)"
picker_binary="$repo_root/native/picker/bin/picker"

# Keypress reference: the Lua handler writes live-panes.json with ts =
# now_ms() right before forwarding `\x1b/`, so its ts is the closest
# we have to "moment user pressed Alt+/". Pass it through to the picker
# so its first render can show end-to-end key→paint latency in the
# diagnostic footer. Falls back to 0 (no latency display) when the
# snapshot is stale or missing.
keypress_ts="${snapshot_ts:-0}"
[[ "$keypress_ts" =~ ^[0-9]+$ ]] || keypress_ts=0

if [[ -x "$picker_binary" ]]; then
  bench_mark picker_branch
  # Capture menu_done_ts as late as possible (right before launching the
  # popup) so bucket M reflects all of menu.sh's actual work. Inline
  # EPOCHREALTIME (µs/1000 → ms) avoids the ~5ms `date` fork.
  menu_done_ts=$(( ${EPOCHREALTIME//./} / 1000 ))
  picker_command="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") $(printf %q "$picker_binary") attention $(printf %q "$prefetch_file") $(printf %q "$attention_jump_script") $(printf %q "$keypress_ts") $(printf %q "$menu_start_ts") $(printf %q "$menu_done_ts")"
  picker_kind='go'
  prefetch_frame_file=''
else
  prefetch_frame_file="$(mktemp -t wezterm-attention-frame.XXXXXX)"
  client_width="$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 100)"
  client_height="$(tmux display-message -p '#{client_height}' 2>/dev/null || echo 30)"
  popup_cols=$(( client_width * 80 / 100 - 2 ))
  (( popup_cols < 20 )) && popup_cols=20
  popup_rows=$(( client_height * 70 / 100 - 2 ))
  (( popup_rows < 6 )) && popup_rows=6
  visible_rows=$(( popup_rows - 4 ))
  (( visible_rows < 1 )) && visible_rows=1
  # Pre-render skips the latency badge: at this point the popup hasn't
  # spawned yet, so any number embedded here would be a fictional half-
  # measurement. picker.sh's post-load re-render is what shows the real
  # end-to-end key→interactive time.
  attention_picker_emit_frame "$popup_cols" "$visible_rows" 0 "$total_rows" 0 0 0 0 > "$prefetch_frame_file"
  menu_done_ts=$(( ${EPOCHREALTIME//./} / 1000 ))
  picker_command="WEZTERM_RUNTIME_TRACE_ID=$(printf %q "$trace_id") bash $(printf %q "$script_dir/tmux-attention-picker.sh") $(printf %q "$prefetch_file") $(printf %q "$prefetch_frame_file") $(printf %q "$keypress_ts") $(printf %q "$menu_start_ts") $(printf %q "$menu_done_ts")"
  picker_kind='bash'
fi

bench_mark prep_done

# Bench short-circuit: dump the timing checkpoints + exit instead of
# opening the popup. Drives scripts/dev/bench-menu-prep.sh.
if [[ -n "${WEZTERM_BENCH_NO_POPUP:-}" ]]; then
  printf '__BENCH__ picker_kind=%s %s\n' "$picker_kind" "${bench_marks[*]}"
  rm -f "$prefetch_file" "$prefetch_frame_file"
  exit 0
fi

if tmux display-popup -x C -y C -w 80% -h 70% -T 'Agent attention' -E "$picker_command"; then
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
