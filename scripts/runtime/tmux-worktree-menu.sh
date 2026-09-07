#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/menu-bench-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/attention-state-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-user-interact-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/access-ledger-lib.sh"

# Microbench short-circuit for scripts/dev/bench-menu-prep.sh --target worktree.
menu_bench_init
bench_mark sourced

session_name="${1:-}"
current_window_id="${2:-}"
cwd="${3:-$PWD}"
context=""
current_worktree_root=""
repo_common_dir=""
repo_label=""
main_worktree_root=""
list_root=""
start_ms="$(runtime_log_now_ms)"
trace_id="$(runtime_log_current_trace_id)"

if [[ -z "$session_name" ]]; then
  runtime_log_error worktree "worktree menu failed: missing tmux session" "current_window_id=$current_window_id" "cwd=$cwd"
  tmux display-message 'Worktree menu failed: missing tmux session'
  exit 1
fi

runtime_log_info worktree "worktree menu invoked" "session_name=$session_name" "current_window_id=$current_window_id" "cwd=$cwd"

context="$(tmux_worktree_context_for_context "$current_window_id" "$cwd" || true)"
if [[ -z "$context" ]]; then
  runtime_log_warn worktree "worktree menu could not resolve current context" "session_name=$session_name" "current_window_id=$current_window_id" "cwd=$cwd"
  tmux display-message 'Current pane is not inside a git worktree'
  exit 0
fi

IFS=$'\t' read -r current_worktree_root repo_common_dir main_worktree_root repo_label <<< "$context"
list_root="$main_worktree_root"
bench_mark context_resolved
runtime_log_info worktree "worktree menu resolved current context" \
  "session_name=$session_name" \
  "current_window_id=$current_window_id" \
  "cwd=$cwd" \
  "current_worktree_root=$current_worktree_root" \
  "repo_common_dir=$repo_common_dir" \
  "main_worktree_root=$main_worktree_root" \
  "repo_label=$repo_label"

# Build prefetched items as both a TSV file (consumed by picker.sh's input
# loop) and parallel arrays (consumed in-process by the shared frame
# renderer below for first-frame priming).
prefetch_file="$(mktemp -t wezterm-worktree-picker.XXXXXX)"
item_labels=()
item_paths=()
item_branches=()
item_window_ids=()
item_accelerators=()
accelerators=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i j k l m n o p q r s t u v w x y z)
# Attribute any typing on the current window before we read the stamps
# (user may have been editing here without a focus change to flush on).
if [[ -n "$current_window_id" ]]; then
  tmux_user_interact_flush_current "$session_name" "$current_window_id" || true
fi
# Opening the picker is itself a user visit of the current worktree —
# keep the durable ledger warm so Alt+x / post-restart restore agree.
if [[ -n "$current_worktree_root" ]]; then
  access_ledger_touch "$session_name" "$current_worktree_root" >/dev/null 2>&1 || true
fi

# One pass over the session's panes (with per-path git-resolution dedup)
# beats N×tmux_worktree_find_window calls — every find_window call would
# otherwise re-walk the same windows and re-fork git for each pane.
# Third column is `@wezterm_user_interact_ts` (user key/mouse), not
# tmux `window_activity` (pane output) — see tmux-user-interact-lib.sh.
declare -A worktree_window_index=()
declare -A worktree_window_interact=()
while IFS=$'\t' read -r idx_root idx_window_id idx_interact; do
  [[ -n "$idx_root" && -n "$idx_window_id" ]] || continue
  worktree_window_index["$idx_root"]="$idx_window_id"
  worktree_window_interact["$idx_root"]="${idx_interact:-0}"
done < <(tmux_worktree_build_window_index "$session_name" "$repo_common_dir")
# Durable ledger fills gaps after tmux death (all live interact ts=0).
# Convert ms → seconds to match @wezterm_user_interact_ts units; take max
# so a live stamp still wins when both exist.
declare -A worktree_ledger_interact=()
while IFS=$'\t' read -r ledger_path ledger_ms; do
  [[ -n "$ledger_path" && "$ledger_ms" =~ ^[0-9]+$ ]] || continue
  worktree_ledger_interact["$ledger_path"]=$(( ledger_ms / 1000 ))
done < <(access_ledger_all_worktree_ms_tsv)
# Agent-attention status per tmux window of this session, joined onto the
# worktree rows below by window id (`@N`) — the tmux window IS the
# worktree, so the join is exact.
#
# Live `.entries` only: an empty status cell means "nothing pending here
# right now", exactly like the wezterm tab badge and right-status
# counters, which also read `.entries` alone. Archived `recent[]`
# tombstones were rendered here as dimmed `last ✓ 3m` until 2026-07-27
# and are deliberately gone: on-disk tombstones live for 7 days (Lua's
# 30-minute TTL only governs `.entries`), so a worktree kept showing an
# hours-old `last ● 4h` / `last ✓ 10h` while every wezterm surface
# considered that session idle. A `last:running` tombstone is not even a
# result — it means the record was evicted mid-run.
#
# Same cost as reading the wezterm-side `live-panes.json` snapshot that
# Alt+/ consumes (one /mnt/c read + one jq, ~5ms on a keypress path; see
# docs/performance.md's cross-FS rule — the wezterm tick side is
# untouched), and attention.json is the source of truth rather than a
# derived 1 Hz snapshot, so the read stays here.
#
# Rows sort by status precedence, so the first row seen for a window wins
# (split panes inside one worktree window can produce more than one).
declare -A window_status=()
attention_state_file="$(attention_state_path)"
if [[ -s "$attention_state_file" ]]; then
  while IFS=$'\t' read -r as_window as_status as_age as_reason; do
    [[ -n "$as_window" ]] || continue
    if [[ -z "${window_status[$as_window]+set}" ]]; then
      window_status["$as_window"]="$as_status"$'\t'"$as_age"$'\t'"$as_reason"
    fi
  done < <(jq -r \
    --arg sess "$session_name" \
    --argjson now "$start_ms" \
    --argjson ttl 1800000 '
      def age($ms): (($now - $ms) / 1000 | floor) as $s
        | if $s < 0 then "0s"
          elif $s < 60 then "\($s)s"
          elif $s < 3600 then "\(($s / 60) | floor)m"
          else "\(($s / 3600) | floor)h" end;
      def rank: if . == "waiting" then 0 elif . == "running" then 1
                elif . == "done" then 2 else 3 end;
      def clean: (. // "") | gsub("[\t\r\n]"; " ");
      [ (.entries // {}) | to_entries[] | .value
        | select((.tmux_session // "") == $sess and (.tmux_window // "") != "")
        | select(($now - (.ts // 0)) < $ttl)
        | { w: .tmux_window, s: (.status // ""), a: age(.ts // $now),
            r: (.reason | clean) } ]
      | sort_by(.s | rank)
      | .[] | [.w, .s, .a, .r] | @tsv
    ' "$attention_state_file" 2>/dev/null || true)
fi
bench_mark attention_joined

# Rows are collected in `git worktree list` order first, then ranked
# most-recently-interacted first (user key/mouse via
# @wezterm_user_interact_ts — see the sort below). The accelerators
# `1-9,0,a-z` are assigned AFTER the sort, so `[1]` always means "the
# worktree you last typed in" rather than "whatever git happens to list
# first" or "whichever agent just streamed output".
ranked_rows=()
git_order=0
while IFS=$'\t' read -r worktree_label worktree_path branch_name; do
  [[ -n "$worktree_path" ]] || continue
  prefetch_window_id="${worktree_window_index[$worktree_path]:-}"
  # Sort / age clock — shared access_ledger_visit_ts_s (also feeds the
  # tab-activity sampler's hot-path set). Bulk ledger map keeps the
  # Alt+g keypress path to one jq read. Agent hooks do NOT feed this.
  row_interact="$(access_ledger_visit_ts_s "$worktree_path" \
    "${worktree_window_interact[$worktree_path]:-0}" \
    "${worktree_ledger_interact[$worktree_path]:-0}")"
  [[ "$row_interact" =~ ^[0-9]+$ ]] || row_interact=0
  attention_cells=$'\t\t'
  if [[ -n "$prefetch_window_id" && -n "${window_status[$prefetch_window_id]:-}" ]]; then
    attention_cells="${window_status[$prefetch_window_id]}"
  elif [[ -z "$prefetch_window_id" ]] && (( row_interact > 0 )); then
    # No live tmux window and no attention badge: show last-visit /
    # created age (not `(new)`). Selecting still creates+resumes.
    now_s=$(( start_ms / 1000 ))
    age_s=$(( now_s - row_interact ))
    (( age_s < 0 )) && age_s=0
    if (( age_s < 60 )); then
      visit_age="${age_s}s"
    elif (( age_s < 3600 )); then
      visit_age="$(( age_s / 60 ))m"
    elif (( age_s < 86400 )); then
      visit_age="$(( age_s / 3600 ))h"
    else
      visit_age="$(( age_s / 86400 ))d"
    fi
    attention_cells=$'\t'"$visit_age"$'\t'
  fi
  ranked_rows+=("$row_interact"$'\t'"$git_order"$'\t'"$worktree_label"$'\t'"$worktree_path"$'\t'"$branch_name"$'\t'"$prefetch_window_id"$'\t'"$attention_cells")
  git_order=$((git_order + 1))
done < <(tmux_worktree_list "$list_root" || true)

if (( ${#ranked_rows[@]} > 0 )); then
  # -k1,1nr: user-interact ts desc. -k2,2n: ties keep git-list order, so a
  # repo whose worktrees have never been touched renders exactly as before.
  while IFS=$'\t' read -r _ _ worktree_label worktree_path branch_name prefetch_window_id row_status row_age row_reason; do
    [[ -n "$worktree_path" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$worktree_label" "$worktree_path" "$branch_name" "$prefetch_window_id" \
      "$row_status" "$row_age" "$row_reason" >> "$prefetch_file"
    item_labels+=("$worktree_label")
    item_paths+=("$worktree_path")
    item_branches+=("$branch_name")
    item_window_ids+=("$prefetch_window_id")
    if (( ${#item_labels[@]} <= ${#accelerators[@]} )); then
      item_accelerators+=("${accelerators[$((${#item_labels[@]} - 1))]}")
    else
      item_accelerators+=("")
    fi
  done < <(printf '%s\n' "${ranked_rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n)
fi
bench_mark prefetched_items
runtime_log_info worktree "worktree menu prefetched items" "session_name=$session_name" "repo_label=$repo_label" "item_count=${#item_paths[@]}" "prefetch_file=$prefetch_file"

# Pre-render the first frame to a tmp file so the popup body can `cat` it
# before bash sourcing finishes inside the popup pty. This bounds the
# perceived "no content → content" jank at "bash startup + 1 syscall"
# instead of "bash startup + 5 lib sources + array build". popup_cols /
# popup_rows mirror the `display-popup -w 70% -h 75%` geometry below
# (minus 2 cells for the popup border on each axis); a brief mismatch with
# picker.sh's stty-based render is invisible because both paint the same
# bytes for a fresh popup with no scrollback.
# Go-only picker (cold start ~2-5ms; owns first paint). Bash path is
# emergency-only via WEZTERM_ALLOW_BASH_PICKER=1.
# shellcheck disable=SC1091
. "$script_dir/picker-bin-lib.sh"
prefetch_frame_file=''
picker_kind='go'
open_script="$script_dir/tmux-worktree-open.sh"
picker_binary=""
picker_rc=0
picker_binary="$(picker_bin_require "$script_dir" "Alt+g")" || picker_rc=$?
if (( picker_rc == 1 )); then
  rm -f "$prefetch_file"
  exit 0
fi

if (( picker_rc == 0 )); then
  picker_kind='go'
  # EPOCHREALTIME (µs/1000 → ms) avoids the ~5ms `date` fork on the popup
  # hot path; matches the inlined idiom in tmux-attention-menu.sh.
  menu_done_ts=$(( ${EPOCHREALTIME//./} / 1000 ))
  picker_command=$(printf 'WEZTERM_RUNTIME_TRACE_ID=%q %q worktree %q %q %q %q %q %q %q %q %q %q' \
    "$trace_id" "$picker_binary" \
    "$prefetch_file" "$open_script" \
    "$session_name" "$current_window_id" "$cwd" \
    "$current_worktree_root" "$repo_label" \
    "$start_ms" "$start_ms" "$menu_done_ts")
else
  # WEZTERM_ALLOW_BASH_PICKER=1 emergency path.
  picker_kind='bash'
  prefetch_frame_file="$(mktemp -t wezterm-worktree-frame.XXXXXX)"
  if (( ${#item_paths[@]} > 0 )); then
    client_width="$(tmux display-message -p '#{client_width}' 2>/dev/null || echo 100)"
    client_height="$(tmux display-message -p '#{client_height}' 2>/dev/null || echo 30)"
    popup_cols=$(( client_width * 70 / 100 - 2 ))
    (( popup_cols < 20 )) && popup_cols=20
    popup_rows=$(( client_height * 75 / 100 - 2 ))
    (( popup_rows < 6 )) && popup_rows=6
    visible_rows=$(( popup_rows - 6 ))
    (( visible_rows < 1 )) && visible_rows=1

    initial_selected=0
    for idx in "${!item_paths[@]}"; do
      if [[ "${item_paths[$idx]}" == "$current_worktree_root" ]]; then
        initial_selected="$idx"
        break
      fi
    done

    # shellcheck disable=SC1091
    source "$script_dir/tmux-worktree/render.sh"
    worktree_picker_emit_frame "$popup_cols" "$visible_rows" "$initial_selected" "${#item_paths[@]}" "$current_worktree_root" "$repo_label" > "$prefetch_frame_file"
  fi
  picker_command="WEZTERM_RUNTIME_TRACE_ID=$(tmux_worktree_shell_quote "$trace_id") bash $(tmux_worktree_shell_quote "$script_dir/tmux-worktree-picker.sh") $(tmux_worktree_shell_quote "$session_name") $(tmux_worktree_shell_quote "$current_window_id") $(tmux_worktree_shell_quote "$list_root") $(tmux_worktree_shell_quote "$cwd") $(tmux_worktree_shell_quote "$current_worktree_root") $(tmux_worktree_shell_quote "$repo_label") $(tmux_worktree_shell_quote "$prefetch_file") $(tmux_worktree_shell_quote "$prefetch_frame_file")"
fi
bench_mark frame_rendered
bench_mark prep_done

if menu_bench_active; then
  rm -f "$prefetch_file" "$prefetch_frame_file"
  menu_bench_dump_and_exit "picker_kind=$picker_kind" "item_count=${#item_paths[@]}"
fi

runtime_log_info worktree "opening worktree popup picker" "session_name=$session_name" "repo_label=$repo_label" "list_root=$list_root"
if bash "$script_dir/tmux-display-popup.sh" -x C -y C -w 70% -h 75% -T "Worktrees: $repo_label" -E "$picker_command"; then
  rm -f "$prefetch_file" "$prefetch_frame_file"
  runtime_log_info worktree "worktree popup picker completed" "session_name=$session_name" "repo_label=$repo_label" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
  exit 0
fi
rm -f "$prefetch_file" "$prefetch_frame_file"

runtime_log_warn worktree "popup picker unavailable, falling back to display-menu" "session_name=$session_name" "repo_label=$repo_label"

menu_args=(display-menu -T "Worktrees: $repo_label" -x R -y P)
item_count=0

# Reuse the already-ranked arrays instead of re-walking git: they carry
# the same user-interact-first order as the popup and their window ids are
# already resolved, so this path no longer forks `tmux_worktree_find_window`
# once per worktree.
for index in "${!item_paths[@]}"; do
  worktree_label="${item_labels[$index]}"
  worktree_path="${item_paths[$index]}"
  branch_name="${item_branches[$index]}"

  marker=' '
  if [[ "$worktree_path" == "$current_worktree_root" ]]; then
    marker='*'
  fi
  menu_label="$marker $worktree_label"
  if [[ -n "$branch_name" ]]; then
    menu_label="$menu_label [$branch_name]"
  fi
  # No "(new)" suffix: window presence does not matter for selection
  # (create+resume on demand). The Go picker shows last-visit age instead.

  accelerator="${item_accelerators[$index]}"

  command_string="run-shell 'WEZTERM_RUNTIME_TRACE_ID=$(tmux_worktree_shell_quote "$trace_id") bash $(tmux_worktree_shell_quote "$script_dir/tmux-worktree-open.sh") $(tmux_worktree_shell_quote "$session_name") $(tmux_worktree_shell_quote "$worktree_path") $(tmux_worktree_shell_quote "$current_window_id") $(tmux_worktree_shell_quote "$cwd")'"
  menu_args+=("$menu_label" "$accelerator" "$command_string")
  ((item_count += 1))
done

if (( item_count == 0 )); then
  tmux display-message "No git worktrees found for $repo_label"
  exit 0
fi

runtime_log_info worktree "opening worktree menu fallback" "session_name=$session_name" "repo_label=$repo_label" "item_count=$item_count"
runtime_log_info worktree "worktree menu fallback opened" "session_name=$session_name" "repo_label=$repo_label" "item_count=$item_count" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
tmux "${menu_args[@]}"
