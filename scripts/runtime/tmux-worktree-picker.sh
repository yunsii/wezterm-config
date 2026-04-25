#!/usr/bin/env bash
set -euo pipefail

# Parse args BEFORE sourcing anything so the cat-priming below can run with
# only bash builtins. On WSL2 with cold disk caches, sourcing the runtime
# log + worktree libs can spike to 30–80ms; doing the prime first bounds
# time-to-first-paint at "bash startup + one syscall" instead of also
# waiting on those sources.
session_name="${1:-}"
current_window_id="${2:-}"
list_root="${3:-$PWD}"
cwd="${4:-$PWD}"
prefetched_current_root="${5:-}"
prefetched_repo_label="${6:-}"
prefetched_file="${7:-}"
prefetched_frame_file="${8:-}"

# First-paint fast path: emit the frame menu.sh pre-rendered before doing
# any work. Use bash's `$(<file)` slurp instead of `cat` to skip the
# fork+exec of /bin/cat (5–30ms on WSL2 cold cache) — at this point bash
# is the only thing standing between the popup pty being live and the
# user seeing content, so every saved syscall counts. Subsequent re-
# renders (driven by Up/Down) repaint via the shared renderer over the
# same screen with absolute positioning, so this priming write and the
# live frame are byte-identical and there is no visible swap.
printf '\033[?25l'
if [[ -n "$prefetched_frame_file" && -r "$prefetched_frame_file" ]]; then
  printf '%s' "$(<"$prefetched_frame_file")"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree/render.sh"

context=""
current_worktree_root=""
repo_label=""
start_ms="$(runtime_log_now_ms)"
trace_id="$(runtime_log_current_trace_id)"

if [[ -z "$session_name" ]]; then
  runtime_log_error worktree "worktree picker failed: missing tmux session" "current_window_id=$current_window_id" "list_root=$list_root" "cwd=$cwd"
  printf 'Worktree picker failed: missing tmux session.\n'
  exit 1
fi

# Skip the tmux has-session probe and the pre-paint log line when prefetch is
# present: menu.sh already validated the session and any extra tmux RPC /
# log fsync delays first paint inside the popup.
if [[ -z "$prefetched_file" || ! -r "$prefetched_file" ]]; then
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    runtime_log_error worktree "worktree picker failed: missing tmux session target" "session_name=$session_name" "current_window_id=$current_window_id" "list_root=$list_root" "cwd=$cwd"
    printf 'Worktree picker failed: missing session %s.\n' "$session_name"
    exit 1
  fi
  runtime_log_info worktree "worktree picker invoked" "session_name=$session_name" "current_window_id=$current_window_id" "list_root=$list_root" "cwd=$cwd" "prefetched_file=$prefetched_file"
fi

accelerators=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i j k l m n o p q r s t u v w x y z)
item_labels=()
item_paths=()
item_branches=()
item_window_ids=()
item_accelerators=()

append_item() {
  local worktree_label="$1"
  local worktree_path="$2"
  local branch_name="$3"
  local local_window_id="$4"

  [[ -n "$worktree_path" ]] || return 0

  item_labels+=("$worktree_label")
  item_paths+=("$worktree_path")
  item_branches+=("$branch_name")
  item_window_ids+=("$local_window_id")
  if (( ${#item_labels[@]} <= ${#accelerators[@]} )); then
    item_accelerators+=("${accelerators[$((${#item_labels[@]} - 1))]}")
  else
    item_accelerators+=("")
  fi
}

if [[ -n "$prefetched_file" && -r "$prefetched_file" ]]; then
  current_worktree_root="$prefetched_current_root"
  repo_label="${prefetched_repo_label:-repo}"
  while IFS=$'\t' read -r worktree_label worktree_path branch_name local_window_id; do
    append_item "$worktree_label" "$worktree_path" "$branch_name" "$local_window_id"
  done < "$prefetched_file"
else
  context="$(tmux_worktree_context_for_context "$current_window_id" "$cwd" || true)"
  if [[ -n "$context" ]]; then
    IFS=$'\t' read -r current_worktree_root _ _ repo_label <<< "$context"
  else
    current_worktree_root=""
    repo_label='repo'
  fi
  runtime_log_info worktree "worktree picker resolved current context" "session_name=$session_name" "current_window_id=$current_window_id" "current_worktree_root=$current_worktree_root" "repo_label=$repo_label"

  while IFS=$'\t' read -r worktree_label worktree_path branch_name; do
    local_window_id=""
    [[ -n "$worktree_path" ]] || continue
    local_window_id="$(tmux_worktree_find_window "$session_name" "$worktree_path" || true)"
    append_item "$worktree_label" "$worktree_path" "$branch_name" "$local_window_id"
  done < <(tmux_worktree_list "$list_root" || true)
fi

item_count="${#item_paths[@]}"
if (( item_count == 0 )); then
  printf 'No git worktrees found for %s.\n' "$repo_label"
  printf 'Press any key to close.'
  IFS= read -rsn1 _ || true
  exit 0
fi

selected_index=0
for index in "${!item_paths[@]}"; do
  if [[ "${item_paths[$index]}" == "$current_worktree_root" ]]; then
    selected_index="$index"
    break
  fi
done

cleanup() {
  printf '\033[0m\033[?25h'
}

terminal_size() {
  local rows cols

  rows=24
  cols=80
  if IFS=' ' read -r rows cols < <(stty size 2>/dev/null || printf '24 80'); then
    :
  fi
  printf '%s %s\n' "${rows:-24}" "${cols:-80}"
}

render_picker() {
  local rows cols visible_rows
  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  visible_rows=$((rows - 6))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi
  worktree_picker_emit_frame "$cols" "$visible_rows" "$selected_index" "$item_count" "$current_worktree_root" "$repo_label"
}

read_key() {
  local key extra

  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\033' ]]; then
    # Disambiguate bare Esc from a multi-byte escape sequence without
    # paying a fixed timeout: `read -t 0` returns success only if more
    # bytes are already buffered. Sequences we care about (`\033[A/B`,
    # `\033OA/B`, the forwarded `\033g`) arrive in one PTY write so the
    # follow-up is buffered the moment we get the leading byte. Bare Esc
    # has nothing behind it, so we return immediately — no 10ms wait
    # before the popup tears down on close.
    if read -t 0 2>/dev/null; then
      IFS= read -rsn2 -t 0.001 extra || true
      key+="$extra"
    fi
  fi
  printf '%s' "$key"
}

move_selection() {
  local delta="${1:-0}"
  selected_index=$((selected_index + delta))
  if (( selected_index < 0 )); then
    selected_index=$((item_count - 1))
  elif (( selected_index >= item_count )); then
    selected_index=0
  fi
}

open_selection() {
  local worktree_root="${item_paths[$selected_index]}"
  local window_id="${item_window_ids[$selected_index]}"
  runtime_log_info worktree "worktree picker opening selection" \
    "session_name=$session_name" \
    "current_window_id=$current_window_id" \
    "selected_index=$selected_index" \
    "worktree_root=$worktree_root" \
    "existing_window_id=${window_id:-new}" \
    "cwd=$cwd"
  local open_command="WEZTERM_RUNTIME_TRACE_ID=$(tmux_worktree_shell_quote "$trace_id") bash $(tmux_worktree_shell_quote "$script_dir/tmux-worktree-open.sh") $(tmux_worktree_shell_quote "$session_name") $(tmux_worktree_shell_quote "$worktree_root") $(tmux_worktree_shell_quote "$current_window_id") $(tmux_worktree_shell_quote "$cwd")"
  tmux run-shell -b "$open_command"
}

find_accelerator_index() {
  local key="${1:-}"
  local index

  for index in "${!item_accelerators[@]}"; do
    if [[ "${item_accelerators[$index]}" == "$key" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done

  return 1
}

trap cleanup EXIT

# When menu.sh did NOT pre-render a frame (e.g. fallback path with no
# prefetch, or zero items), paint the first frame here. When it DID, the
# `cat` at the top of the script already produced the same bytes, so a
# second render would be redundant. Either way, subsequent iterations only
# repaint on Up/Down — see the input loop below.
if [[ -z "$prefetched_frame_file" || ! -r "$prefetched_frame_file" ]]; then
  render_picker
fi
runtime_log_info worktree "worktree picker invoked" "session_name=$session_name" "current_window_id=$current_window_id" "repo_label=$repo_label" "item_count=$item_count" "prefetched_file=$prefetched_file"

while true; do
  key=""
  accel_index=""
  needs_render=0

  key="$(read_key)" || exit 0

  case "$key" in
    "")
      open_selection
      runtime_log_info worktree "worktree popup picker completed" "session_name=$session_name" "repo_label=$repo_label" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
      exit 0
      ;;
    $'\033' | $'\003' | $'\033g')
      # `\033g` is the forwarded Alt+g sequence WezTerm sends when the user
      # presses Alt+g a second time while the popup is up. Treating it as an
      # exit key makes Alt+g a true toggle: the popup is the only thing
      # listening to the keyboard while it is up, so the same chord that
      # opened it also closes it (mirrors the Alt+/ attention picker).
      exit 0
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      needs_render=1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      needs_render=1
      ;;
    *)
      accel_index="$(find_accelerator_index "${key,,}" || true)"
      if [[ -n "$accel_index" ]]; then
        selected_index="$accel_index"
        open_selection
        runtime_log_info worktree "worktree popup picker completed" "session_name=$session_name" "repo_label=$repo_label" "duration_ms=$(runtime_log_duration_ms "$start_ms")"
        exit 0
      fi
      ;;
  esac

  if (( needs_render )); then
    render_picker
  fi
done
