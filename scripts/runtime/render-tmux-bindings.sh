#!/usr/bin/env bash
# render-tmux-bindings.sh
#
# Regenerate the tmux chord binding config from the single source of truth
# (wezterm-x/commands/manifest.json), applying any user overrides declared
# in wezterm-x/local/keybindings.lua. The output replaces what used to live
# as inline bind-key lines inside tmux.conf.
#
# Output: wezterm-x/tmux/chord-bindings.generated.conf (gitignored). tmux.conf
# loads it via `source-file -q`, so running wezterm-runtime-sync between
# manifest / override edits is what makes changes visible to tmux.
#
# Scope in this file:
#   * chord root trigger (Ctrl+k → command-chord table)
#   * chord leaves (command-chord v/h/x, worktree-chord d/t/h/r)
#   * sub-chord trigger (command-chord g → worktree-chord)
#   * cancellation fallbacks (Escape / C-k / Any) for both tables
#
# Out of scope (stays inline in tmux.conf): root Alt+* and User0/1/2 bindings
# that carry WezTerm-forwarded keystrokes into tmux. Those are transport
# infrastructure; customizing them at the user level would break forwarding.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/wezterm-x/commands/manifest.json"
OVERRIDES="$REPO_ROOT/wezterm-x/local/keybindings.lua"
OUT_DIR="$REPO_ROOT/wezterm-x/tmux"
OUT="$OUT_DIR/chord-bindings.generated.conf"

if ! command -v jq >/dev/null 2>&1; then
  printf 'render-tmux-bindings.sh: jq is required but not on PATH\n' >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  printf 'render-tmux-bindings.sh: manifest missing at %s\n' "$MANIFEST" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# ── Parse wezterm-x/local/keybindings.lua for per-id overrides ───────────
#
# Only string and `false` values are meaningful at the chord layer. Users
# wanting to override a multi-hotkey id with the table form are dealing
# with wezterm-layer ids (like tab.select-by-index) that never reach here.
declare -A OVERRIDE_KEY=()
declare -A OVERRIDE_DISABLED=()
if [[ -f "$OVERRIDES" ]]; then
  string_re="^[[:space:]]*\[[\'\"]([A-Za-z0-9._-]+)[\'\"]\][[:space:]]*=[[:space:]]*[\'\"]([^\'\"]+)[\'\"]"
  false_re="^[[:space:]]*\[[\'\"]([A-Za-z0-9._-]+)[\'\"]\][[:space:]]*=[[:space:]]*false"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*-- ]] && continue
    if [[ "$line" =~ $string_re ]]; then
      OVERRIDE_KEY["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ $false_re ]]; then
      OVERRIDE_DISABLED["${BASH_REMATCH[1]}"]=1
    fi
  done < "$OVERRIDES"
fi

RT='#{@wezterm_runtime_root}'
SESS='#{q:session_name}'

# Print the "run chord-hint start <message>" tmux command snippet. Message
# arrives already single-quoted so it survives through two layers of tmux
# parsing.
chord_hint_start() {
  local message="$1"
  printf 'run-shell "bash %s/scripts/runtime/tmux-chord-hint.sh start %s %s"' \
    "$RT" "$message" "$SESS"
}

chord_hint_clear() {
  printf 'run-shell "bash %s/scripts/runtime/tmux-chord-hint.sh clear %s"' \
    "$RT" "$SESS"
}

usage_bump() {
  local id="$1"
  printf 'run-shell -b "bash %s/scripts/runtime/hotkey-usage-bump.sh %s"' \
    "$RT" "$id"
}

# Wrap a leaf's manifest-declared exec body with the shared prelude
# (chord-hint clear, usage bump) and a switch back to the root key table.
# `switch_first` controls whether the switch runs before or after exec:
# modal actions (tmux command-prompt) need the key table released first
# so typing in the prompt doesn't ricochet off chord-table fallbacks;
# synchronous actions (split-window, kill-pane) switch after.
wrap_leaf() {
  local id="$1" exec="$2" switch_first="$3"
  if [[ "$switch_first" == "true" ]]; then
    printf '%s \\; %s \\; switch-client -T root \\; %s' \
      "$(chord_hint_clear)" "$(usage_bump "$id")" "$exec"
  else
    printf '%s \\; %s \\; %s \\; switch-client -T root' \
      "$(chord_hint_clear)" "$(usage_bump "$id")" "$exec"
  fi
}

# Given an override key string like "Ctrl+k v" or "Ctrl+k g d", strip the
# chord prefix and return only the final segment — that's the leaf tmux
# actually binds inside its chord table. Space is the segment separator.
last_key_segment() {
  awk '{print $NF}' <<<"$1"
}

# Normalize a chord-leaf segment to a tmux bind-key key, mirroring the
# lua-side parse_key_string semantics in wezterm-x/lua/ui/keybinding_overrides.lua:
#   * single ASCII letter is case-insensitive without explicit Shift —
#     `v` and `V` both bind tmux key `v` (no shift);
#   * `Shift+v` and `Shift+V` both bind tmux key `V` (which IS shift+v
#     in tmux's native key syntax — tmux encodes Shift on letters by
#     uppercasing rather than via a separate modifier);
#   * everything else (multi-char names like Enter / F1 / BSpace,
#     tmux-prefixed forms like C-v / M-v, digits, punctuation) passes
#     through unchanged.
# Keeps manifest declarations and user overrides consistent across the
# wezterm and tmux halves of the keymap pipeline.
normalize_leaf() {
  local raw="$1"
  if [[ "$raw" =~ ^[Ss][Hh][Ii][Ff][Tt]\+(.+)$ ]]; then
    local rest="${BASH_REMATCH[1]}"
    if [[ "$rest" =~ ^[A-Za-z]$ ]]; then
      printf '%s' "${rest^^}"
      return
    fi
    printf '%s' "$raw"
    return
  fi
  if [[ "$raw" =~ ^[A-Za-z]$ ]]; then
    printf '%s' "${raw,,}"
    return
  fi
  printf '%s' "$raw"
}

{
  printf '# Generated by scripts/runtime/render-tmux-bindings.sh.\n'
  printf '# Source of truth: wezterm-x/commands/manifest.json (+ optional\n'
  printf '# overrides in wezterm-x/local/keybindings.lua).\n'
  printf '# Do not edit by hand — rerun wezterm-runtime-sync to regenerate.\n\n'

  # Clear whatever may already be bound. We do this here (not in tmux.conf)
  # so a chord reload is self-contained.
  printf 'unbind -n C-k\n'
  printf 'if-shell "tmux list-keys -T command-chord >/dev/null 2>&1" "unbind -T command-chord -a"\n'
  printf 'if-shell "tmux list-keys -T worktree-chord >/dev/null 2>&1" "unbind -T worktree-chord -a"\n\n'

  # Root trigger — enter command-chord. Customizing this in user overrides
  # would require also rewriting the WezTerm-side transport (`\x0b`), so we
  # keep the tmux-internal key pinned to C-k and let users rebind the
  # WezTerm-side command-palette.chord-prefix instead.
  printf 'bind-key -n C-k %s \\; switch-client -T command-chord\n\n' \
    "$(chord_hint_start "'(Ctrl+K) was pressed. Waiting for second key of chord...'")"

  # Sub-chord trigger: command-chord g → worktree-chord
  printf 'bind-key -T command-chord g %s \\; switch-client -T worktree-chord\n\n' \
    "$(chord_hint_start "'(Ctrl+K g) Worktree chord. Pick: d=dev t=task h=hotfix r=reclaim'")"

  # Per-leaf bindings from manifest. Fields are joined with ASCII Unit
  # Separator (\x1f) because the exec body contains backslash sequences that
  # jq's @tsv would escape — @tsv is designed to be lossily parseable, we
  # need byte-exact delivery to preserve tmux escape syntax like \"%1\".
  while IFS=$'\x1f' read -r id table keys exec switch_first; do
    [[ -n "$id" ]] || continue
    if [[ -n "${OVERRIDE_DISABLED[$id]:-}" ]]; then
      printf '# %s disabled by user override\n' "$id"
      continue
    fi
    if [[ -n "${OVERRIDE_KEY[$id]:-}" ]]; then
      keys="${OVERRIDE_KEY[$id]}"
    fi
    leaf="$(last_key_segment "$keys")"
    if [[ -z "$leaf" ]]; then
      printf '# %s: could not determine leaf key from %q, skipping\n' "$id" "$keys"
      continue
    fi
    leaf="$(normalize_leaf "$leaf")"
    printf 'bind-key -T %s %s %s\n' "$table" "$leaf" "$(wrap_leaf "$id" "$exec" "$switch_first")"
  done < <(jq -r '
    .[]
    | select(.binding? and .binding.kind == "tmux-chord-leaf")
    | [
        .id,
        .binding.table,
        (.hotkeys[0].keys // ""),
        .binding.exec,
        ((.binding.switch_first // false) | tostring)
      ]
    | join("")
  ' "$MANIFEST")

  # Cancellation fallbacks — unchanged from the original inline block.
  printf '\n# Cancellation fallbacks\n'
  for table in command-chord worktree-chord; do
    for key in Escape C-k Any; do
      printf 'bind-key -T %s %s %s \\; switch-client -T root\n' \
        "$table" "$key" "$(chord_hint_clear)"
    done
  done
} > "$OUT.tmp.$$"

# Only replace OUT (and bump its mtime) when content actually changed —
# saves a redundant rsync write each sync and keeps the file's mtime
# meaningful as a "last real binding change" marker for skip-if-current
# checks downstream (lua-precheck, helper-ensure).
if [[ -f "$OUT" ]] && cmp -s "$OUT.tmp.$$" "$OUT"; then
  rm -f "$OUT.tmp.$$"
  printf 'render-tmux-bindings: up-to-date %s\n' "$OUT"
else
  mv -f "$OUT.tmp.$$" "$OUT"
  printf 'render-tmux-bindings: wrote %s\n' "$OUT"
fi
