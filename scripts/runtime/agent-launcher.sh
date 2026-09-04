#!/usr/bin/env bash
# agent-launcher.sh — entry point for managed agent panes spawned by tmux.
#
# Bash-only: the sourced runtime-env-lib.sh uses `[[`, `${var:0:1}` substring
# expansion, and `shopt -s nullglob`. Don't switch this shebang back to `sh`
# without also rewriting the lib in pure POSIX.
#
# Why this script exists:
#   Several launch paths fork the agent via `tmux new-window <cmd>` / tmux
#   respawn-pane, where tmux runs `<cmd>` through a plain `sh -c` direct
#   from the server process. That `sh` traverses no shell rc files, so
#   secrets exported by the user's ~/.zshrc (files under
#   ~/.config/shell-env.d/*.env, etc.) never reach the agent or its child
#   scripts — leading to e.g. `npm view @coco/x-server` returning 401
#   inside the agent's Bash tool while the same command works in the
#   user's shell.
#
#   This script is the one place we explicitly load runtime env files
#   before exec'ing into the resume-or-fresh agent command. All managed
#   profiles in config/worktree-task.env reference it via
#   ${WEZTERM_REPO}/scripts/runtime/agent-launcher.sh <agent>, so every
#   path (Alt+g on-demand, refresh-current-window, tab-overflow,
#   workspace first-open) shares the same env view.
#
# Usage:
#   agent-launcher.sh <claude|claude-sub2api|codex|grok>
#
# Claude auth profiles:
#   claude            OAuth / subscription (team or individual). Gateway
#                     env vars are cleared so a leaked ANTHROPIC_* from
#                     the parent shell cannot silently override OAuth.
#   claude-sub2api    API gateway via ANTHROPIC_BASE_URL + token from a
#                     dedicated env file (default
#                     ~/.config/claude-profiles/sub2api.env). Do NOT put
#                     those keys in shell-env.d — that would override
#                     every claude pane.
#
# Phone sync via Happy was removed (2026-07): remote work goes through
# OpenClaw (Feishu / ACP / temporary tmux control). See
# docs/presentations/ai-dev-environment-evolution.md (v6) and
# docs/mobile-access.md.

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$script_dir/runtime-env-lib.sh"
runtime_env_load_managed

agent="${1:-}"
if [[ -n "${2:-}" ]]; then
  printf 'agent-launcher: unexpected argument %s (Happy wrap removed)\n' "$2" >&2
  printf 'usage: agent-launcher.sh <claude|claude-sub2api|codex|grok>\n' >&2
  exit 1
fi

# Normalize underscore form from managed_cli profile names.
case "$agent" in
  claude_sub2api) agent='claude-sub2api' ;;
esac

# Visible boot cue. Until the agent CLI paints its first frame, the pane
# is blank — that's the shell-chain forks (~150ms, mainly `zsh -ilc`
# inheriting interactive PATH) plus the agent's own session-resume load
# (0.5-3s for `claude --continue`, similar for `codex resume --last`).
# Printing one dim line turns "blank pane for several seconds" into
# "pane shows what it's doing"; the agent's first paint typically clears
# the screen, so the banner is only visible while it's actually useful.
# This script is the universal terminus for every managed-agent launch
# path (workspace first-open, refresh-current-window, Alt+g on-demand,
# tab-overflow cold-spawn, worktree-task), so the cue lands once
# regardless of which entry point the user took. Disable with
# WEZTERM_NO_LOADING_BANNER=1 if it ever interferes.
print_loading_banner() {
  [[ -t 1 ]] || return 0
  [[ "${WEZTERM_NO_LOADING_BANNER:-}" == "1" ]] && return 0

  local label="$1"
  [[ -n "$label" ]] || label="agent"

  # \033[2J\033[H = clear + home so the banner anchors at top-left even
  # if the parent shell painted a prompt bit before this. Two newlines
  # of leading padding so the banner sits a couple rows down instead of
  # hugging the very top edge.
  printf '\033[2J\033[H\n\n  \033[2;36mLoading %s ...\033[0m\n' "$label"
}

# shellcheck disable=SC1091
. "$script_dir/agent-claude-sub2api-lib.sh"

print_loading_banner "$agent"

# Fallback re-paint: when `--continue` (or `resume --last`) finds no
# session, the CLI prints "No conversation found to continue" to the
# primary screen and exits non-zero. The fresh `<agent>`'s welcome card
# also renders on the primary screen (alt-screen is only entered once
# the user starts chatting), so without a re-clear the loading banner
# + error line stay visible above the welcome box. Re-clear and re-draw
# the banner inside the `||` branch so the fallback path looks the same
# as the resume-success path.
case "$agent" in
  claude)
    clear_anthropic_gateway_env
    exec sh -c 'claude --continue || { printf "\033[2J\033[H\n\n  \033[2;36mLoading claude ...\033[0m\n"; exec claude; }'
    ;;
  claude-sub2api)
    load_claude_sub2api_env
    # Env is inherited by the inner sh -c / claude process. Banner label
    # keeps the identity visible during the multi-second resume window.
    exec sh -c 'claude --continue || { printf "\033[2J\033[H\n\n  \033[2;36mLoading claude-sub2api ...\033[0m\n"; exec claude; }'
    ;;
  codex)
    exec sh -c 'codex resume --last || { printf "\033[2J\033[H\n\n  \033[2;36mLoading codex ...\033[0m\n"; exec codex; }'
    ;;
  grok)
    # Grok Build: `--continue` resumes the most recent session for cwd
    # (same role as `claude --continue` / `codex resume --last`).
    # Always prefer the focus-filter wrapper by absolute path so managed
    # panes do not depend on whether ~/.zshrc put ~/.grok/bin (often a
    # post-update bare ELF) ahead of ~/.local/bin. Direct interactive
    # `grok` still needs `grok-with-focus-filter.sh --install` — see
    # docs/tmux-ui.md#grok-build-in-tmux.
    grok_bin="$script_dir/grok-with-focus-filter.sh"
    if [[ ! -x "$grok_bin" ]]; then
      grok_bin="$(command -v grok || true)"
    fi
    if [[ -z "$grok_bin" ]]; then
      printf 'agent-launcher: grok not found (expected %s or PATH)\n' \
        "$script_dir/grok-with-focus-filter.sh" >&2
      exit 127
    fi
    exec sh -c '"$0" --continue || { printf "\033[2J\033[H\n\n  \033[2;36mLoading grok ...\033[0m\n"; exec "$0"; }' \
      "$grok_bin"
    ;;
  *)
    printf 'agent-launcher: unknown agent %s\n' "$agent" >&2
    printf 'usage: agent-launcher.sh <claude|claude-sub2api|codex|grok>\n' >&2
    exit 1
    ;;
esac
