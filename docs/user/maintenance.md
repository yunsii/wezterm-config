# Maintenance

Use this doc when you need to apply or verify changes.

## Daily Workflow

1. Edit files in this repo.
2. Sync runtime files with the `wezterm-runtime-sync` skill.

Private machine/project config should live in `wezterm-x/local/`, starting from the tracked templates in `wezterm-x/local.example/`.
Keep simple cross-language values in `wezterm-x/local/shared.env`, and keep Lua-only structured settings in `wezterm-x/local/constants.lua`.
Use `wezterm-x/local.example/shared.env` as the tracked starting point for shared scalar values such as `WAKATIME_API_KEY`.

The skill's implementation lives under `skills/wezterm-runtime-sync/scripts/`. If repo-root `.sync-target` already points at a valid home, you can sync directly:

```bash
skills/wezterm-runtime-sync/scripts/sync-runtime.sh
```

If you need to choose or change the target home, use the explicit two-step flow:

```bash
skills/wezterm-runtime-sync/scripts/sync-runtime.sh --list-targets
skills/wezterm-runtime-sync/scripts/sync-runtime.sh --target-home /mnt/c/Users/your-user
```

Run those commands from the repo root, or set `WEZTERM_CONFIG_REPO=/absolute/path/to/repo` before invoking the script from elsewhere.

3. Reload WezTerm with `Ctrl+Shift+R`.
4. If tmux styling or startup behavior changed, reload tmux config:

```bash
scripts/dev/reload-tmux.sh
```

Recreate affected sessions only if a simple reload is not enough.
For WakaTime key changes in `wezterm-x/local/shared.env`, a tmux reload is sufficient; that path no longer depends on WezTerm injecting environment variables into WSL.
6. If runtime shell rc files changed, reload the interactive shell in affected tmux panes or recreate those sessions.

## Worktree Task Skill

Use the `worktree-task` skill when you want a fresh Codex implementation session in a linked worktree instead of continuing in the current worktree.

- Run it from the existing managed tmux/Codex window for the target repository when possible so the new task window can reuse the current repo-family tmux session directly.
- The skill creates linked worktrees under the primary worktree root's `.worktrees/` directory and stores the cleaned-up task prompt under `.worktrees/.codex-prompts/`.
- This repository ignores `.worktrees/`, so prompt archives and linked worktree folders do not pollute `git status`.

Example:

```bash
printf '%s' "$TASK_PROMPT" | skills/worktree-task/scripts/launch-worktree-task.sh --title "short task title"
```

Useful options:

- `--base-ref <ref>` to branch from something other than the primary worktree `HEAD`
- `--branch <name>` to force a branch name
- `--session-name <name>` to target an already running tmux session for that repo family when launching from outside tmux
- `--variant light|dark|auto` to choose the Codex UI variant for the new window
- `--no-attach` to prepare the worktree and tmux window without switching the current client, including the first time that task window is created

Reclaim a finished task:

```bash
skills/worktree-task/scripts/reclaim-worktree-task.sh
```

Useful reclaim options:

- `--task-slug <slug>` to reclaim `.worktrees/<slug>` from the current repo family
- `--worktree-root <path>` to reclaim a specific linked task worktree
- `--force` to discard local changes and pass `-f` to `git worktree remove`
- `--keep-branch` to keep the task branch even when it is already merged
- `--keep-prompt` to keep the archived prompt file

Reclaim only removes skill-managed linked worktrees under `.worktrees/`. By default it refuses to remove a dirty worktree, deletes the archived prompt file, closes tmux windows for that worktree, and deletes the task branch only when that branch is already merged into the primary worktree `HEAD`.

## Diagnostics

- WezTerm-side diagnostics are configured in `wezterm-x/local/constants.lua` under `diagnostics.wezterm`.
- Runtime shell diagnostics are configured separately in `wezterm-x/local/runtime-logging.sh`, starting from `wezterm-x/local.example/runtime-logging.sh`.
- Keep both logging systems disabled by default; enable them only while investigating a problem.
- When `diagnostics.wezterm.enabled = true`, WezTerm writes structured lines to the configured `file` and also shows them in the Debug Overlay.
- Current WezTerm-side diagnostics categories include `workspace`, `alt_o`, `chrome`, and `clipboard`.
- Set `diagnostics.wezterm.debug_key_events = true` only for keybinding investigations; it is intentionally noisy.
- When `WEZTERM_RUNTIME_LOG_ENABLED=1`, the runtime scripts append structured lines to `WEZTERM_RUNTIME_LOG_FILE`.
- Leave `WEZTERM_RUNTIME_LOG_CATEGORIES` empty to capture all runtime categories, or set a comma-separated list such as `alt_o,workspace,worktree`.
- Current runtime categories include `alt_o`, `workspace`, `worktree`, and `managed_command`.

## Shell Integration

- WezTerm cwd tracking inside tmux depends on `OSC 7` shell integration in `~/.zshrc` and `~/.bashrc`.
- In `hybrid-wsl`, those files are typically inside the WSL home directory.
- In `posix-local`, those files live in the local Linux or macOS home directory.
- If those rc files are reset, merged, or replaced, restore the WezTerm integration before relying on tmux cwd-aware UI or WezTerm-side cwd actions; `Alt+o` falls back to the pane's own handling when WezTerm only sees the WSL host path.

### `~/.zshrc`

```sh
# WezTerm shell integration: publish cwd via OSC 7, with tmux passthrough.
__wezterm_osc7_host="${HOSTNAME:-$(hostname)}"
__wezterm_emit_cwd() {
  if [ -n "${TMUX-}" ]; then
    printf '\033Ptmux;\033\033]7;file://%s%s\007\033\\' "$__wezterm_osc7_host" "$PWD"
  else
    printf '\033]7;file://%s%s\007' "$__wezterm_osc7_host" "$PWD"
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd __wezterm_emit_cwd
```

### `~/.bashrc`

```sh
# WezTerm shell integration: publish cwd via OSC 7, with tmux passthrough.
__wezterm_osc7_host="${HOSTNAME:-$(hostname)}"
__wezterm_emit_cwd() {
  if [ -n "${TMUX-}" ]; then
    printf '\033Ptmux;\033\033]7;file://%s%s\007\033\\' "$__wezterm_osc7_host" "$PWD"
  else
    printf '\033]7;file://%s%s\007' "$__wezterm_osc7_host" "$PWD"
  fi
}
case ";${PROMPT_COMMAND:-};" in
  *";__wezterm_emit_cwd;"*) ;;
  *) PROMPT_COMMAND="__wezterm_emit_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
```

### After Editing RC Files

- Reload the shell in affected tmux panes with `source ~/.zshrc` or `source ~/.bashrc`.
- Press Enter once to redraw the prompt so the updated shell emits a fresh `OSC 7` cwd update.

## Validation

- Verify workspace shortcuts still match [`keybindings.md`](./keybindings.md).
- If workspace behavior changed, verify it still matches [`workspaces.md`](./workspaces.md).
- If tmux styling or status changed, verify it still matches [`tmux-and-status.md`](./tmux-and-status.md).

The `open-project-session.sh` helper now warns when it detects tmux older than 3.3; those versions cannot enable `allow-passthrough` so the tmux theme/status may fall back to the distro defaults. Upgrade tmux (build from source or use a newer Ubuntu package) before relying on the managed theme.

### Sync helper

- Use the `wezterm-runtime-sync` skill for runtime sync work. Its scripts live under `skills/wezterm-runtime-sync/scripts/`.  
- Files under `wezterm-x/local/` are gitignored, but they are still copied because the sync skill works from the repository working tree.  
- Run `skills/wezterm-runtime-sync/scripts/sync-runtime.sh --list-targets` to print candidate user homes without syncing anything. The script skips common Windows system profiles such as `Default` and `Public`.  
- Run `skills/wezterm-runtime-sync/scripts/sync-runtime.sh --target-home /absolute/path` after the user confirms a target. This syncs immediately and updates `.sync-target`.  
- The sync step writes `repo-root.txt` into the target `.wezterm-x` folder so managed runtime code can still locate the source repo.  
- `.sync-target` is repo-local and gitignored. If you need to change the target home later, delete it and rerun the script to re-prompt.

## Commit Workflow

When you want a commit message that includes AI collaboration metadata, use:

```bash
scripts/dev/commit-with-ai-context.sh --help
```

The helper script:

- builds a conventional commit title and optional body
- appends an `AI Collaboration:` block when you provide AI metadata
- previews the full message before commit
- requires explicit confirmation before it runs `git commit`

Count only meaningful human adjustments in `human-adjustments`. Exclude approval-only or escalation-only interactions.
