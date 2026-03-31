#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/runtime-log-lib.sh"
# shellcheck disable=SC1091
source "$script_dir/tmux-worktree-lib.sh"

session_name="${1:-}"
current_window_id="${2:-}"
list_root="${3:-$PWD}"
cwd="${4:-$PWD}"
context=""
current_worktree_root=""
repo_label=""

if [[ -z "$session_name" ]]; then
  printf 'Worktree picker failed: missing tmux session.\n'
  exit 1
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  printf 'Worktree picker failed: missing session %s.\n' "$session_name"
  exit 1
fi

context="$(tmux_worktree_context_for_context "$current_window_id" "$cwd" || true)"
if [[ -n "$context" ]]; then
  IFS=$'\t' read -r current_worktree_root _ _ repo_label <<< "$context"
else
  current_worktree_root=""
  repo_label='repo'
fi

accelerators=(1 2 3 4 5 6 7 8 9 0 a b c d e f g h i j k l m n o p q r s t u v w x y z)
item_labels=()
item_paths=()
item_branches=()
item_window_ids=()
item_accelerators=()

while IFS=$'\t' read -r worktree_label worktree_path branch_name; do
  local_window_id=""

  [[ -n "$worktree_path" ]] || continue

  local_window_id="$(tmux_worktree_find_window "$session_name" "$worktree_path" || true)"
  item_labels+=("$worktree_label")
  item_paths+=("$worktree_path")
  item_branches+=("$branch_name")
  item_window_ids+=("$local_window_id")
  if (( ${#item_labels[@]} <= ${#accelerators[@]} )); then
    item_accelerators+=("${accelerators[$((${#item_labels[@]} - 1))]}")
  else
    item_accelerators+=("")
  fi
done < <(tmux_worktree_list "$list_root" || true)

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

runtime_log_info worktree "running worktree popup picker" "session_name=$session_name" "repo_label=$repo_label" "item_count=$item_count"

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
  local rows cols visible_rows start_index end_index marker line accelerator line_branch
  local line_suffix top_index

  IFS=' ' read -r rows cols <<< "$(terminal_size)"
  visible_rows=$((rows - 6))
  if (( visible_rows < 1 )); then
    visible_rows=1
  fi

  start_index=0
  if (( selected_index >= visible_rows )); then
    start_index=$((selected_index - visible_rows + 1))
  fi
  end_index=$((start_index + visible_rows - 1))
  if (( end_index >= item_count )); then
    end_index=$((item_count - 1))
    start_index=$((end_index - visible_rows + 1))
    if (( start_index < 0 )); then
      start_index=0
    fi
  fi

  printf '\033[H\033[2J'
  printf '%-*.*s\n' "$cols" "$cols" "Worktrees: $repo_label"
  printf '%-*.*s\n' "$cols" "$cols" "Showing $((start_index + 1))-$((end_index + 1)) of $item_count"
  printf '\n'

  for (( top_index = start_index; top_index <= end_index; top_index += 1 )); do
    marker=' '
    if [[ "${item_paths[$top_index]}" == "$current_worktree_root" ]]; then
      marker='*'
    fi

    accelerator="${item_accelerators[$top_index]}"
    if [[ -n "$accelerator" ]]; then
      accelerator="[$accelerator]"
    else
      accelerator="   "
    fi

    line_branch=""
    if [[ -n "${item_branches[$top_index]}" ]]; then
      line_branch=" [${item_branches[$top_index]}]"
    fi

    line_suffix=""
    if [[ -z "${item_window_ids[$top_index]}" ]]; then
      line_suffix=" (new)"
    fi

    line="$accelerator $marker ${item_labels[$top_index]}$line_branch$line_suffix"
    if (( top_index == selected_index )); then
      printf '\033[7m%-*.*s\033[0m\n' "$cols" "$cols" "$line"
    else
      printf '%-*.*s\n' "$cols" "$cols" "$line"
    fi
  done

  printf '\n'
  printf '%-*.*s' "$cols" "$cols" "Enter open | Up/Down move | 1-9,0,a-z open | Esc close"
}

read_key() {
  local key extra

  IFS= read -rsn1 key || return 1
  if [[ "$key" == $'\033' ]]; then
    if IFS= read -rsn2 -t 0.01 extra; then
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
  bash "$script_dir/tmux-worktree-open.sh" "$session_name" "$worktree_root" "$current_window_id" "$cwd"
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
printf '\033[?25l'

while true; do
  key=""
  accel_index=""

  render_picker
  key="$(read_key)" || exit 0

  case "$key" in
    "")
      open_selection
      exit 0
      ;;
    $'\033' | $'\003')
      exit 0
      ;;
    $'\033[B' | $'\033OB')
      move_selection 1
      ;;
    $'\033[A' | $'\033OA')
      move_selection -1
      ;;
    *)
      accel_index="$(find_accelerator_index "${key,,}" || true)"
      if [[ -n "$accel_index" ]]; then
        selected_index="$accel_index"
        open_selection
        exit 0
      fi
      ;;
  esac
done
