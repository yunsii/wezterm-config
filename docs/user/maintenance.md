# Maintenance

Use this doc when you need to apply or verify changes.

## Daily Workflow

1. Edit files in this repo.
2. Sync runtime files with the `wezterm-runtime-sync` skill.

Private machine/project config should live in `wezterm-x/local/`, starting from the tracked templates in `wezterm-x/local.example/`.
Keep simple cross-language values in `wezterm-x/local/shared.env`, and keep Lua-only structured settings in `wezterm-x/local/constants.lua`.
Optional machine-local `Ctrl+k` quick actions belong in `wezterm-x/local/command-panel.sh`.
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

3. Let WezTerm auto-reload the synced config changes.
   In current WezTerm versions, `automatically_reload_config` defaults to `true`: the loaded config file is watched, `require`-loaded Lua files are also watched, and the majority of options take effect automatically. Use `Ctrl+Shift+R` only to force a reload when needed.
4. If tmux styling or startup behavior changed, reload tmux config:

```bash
scripts/dev/reload-tmux.sh
```

Recreate affected sessions only if a simple reload is not enough.
For WakaTime key changes in `wezterm-x/local/shared.env`, a tmux reload is sufficient; that path no longer depends on WezTerm injecting environment variables into WSL.
5. If runtime shell rc files changed, reload the interactive shell in affected tmux panes or recreate those sessions.

## Renderer Backend

- The tracked config currently sets `front_end = 'WebGpu'` in `wezterm-x/lua/ui.lua`.
- `WebGpu` and `OpenGL` use the same terminal/parser/shaping pipeline; the practical difference is the final GUI renderer and its driver stack.
- `WebGpu` usually maps to the platform-native modern graphics API through `wgpu` and may offer better throughput, but it is also more sensitive to driver- and compositor-specific bugs.
- `OpenGL` is the compatibility fallback. If you see stale frames, missing redraws, or a window that only visibly refreshes after focus returns, test `OpenGL` before assuming the bug is elsewhere.
- If `OpenGL` refreshes correctly even while the window is unfocused, treat that as a backend/driver compatibility clue rather than a workspace or tmux problem.
- After changing `front_end`, prefer a full WezTerm restart over relying on auto reload or `Ctrl+Shift+R`; most config edits hot-reload, but renderer changes should be verified in a new GUI process.

## Worktree Task Skill

Use the `worktree-task` skill when you want a fresh agent CLI implementation session in a linked worktree instead of continuing in the current worktree.

- Run it from the existing managed tmux agent window for the target repository when possible so the new task window can reuse the current repo-family tmux session directly from live git context.
- The skill creates linked worktrees under the repository parent's `.worktrees/<repo>/` directory.
- `WEZTERM_CONFIG_REPO` is required. In an agent workflow, every `worktree-task` run should first check whether it is configured; if it is missing, the agent should ask which tracked `wezterm-config` repo or derived repo you want, then run `skills/worktree-task/scripts/worktree-task configure --repo /absolute/path` to save the result into `~/.config/worktree-task/config.env`.
- This repository's tracked worktree-task profile lives at `.worktree-task/config.env`. It enables the built-in `tmux-agent` provider, configures the default agent CLI commands, and points `WEZTERM_CONFIG_REPO=.` back at this repo so shared task-launch conventions are collected explicitly instead of guessed from the target repo.
- Config collection order is: configured `wezterm-config` repo profile, then `~/.config/worktree-task/config.env`, then the target repo's own `.worktree-task/config.env`.
- Relative repo-managed paths such as `WT_PROVIDER_TMUX_CONFIG_FILE=tmux.conf` resolve against the configured `wezterm-config` repo or derived repo, not against the task repo where you launch the command.
- Use `configure --repo` as the stable recovery path whenever `WEZTERM_CONFIG_REPO` is missing; `launch` often consumes stdin for the task prompt, so configuration should not depend on waiting for input on that same stream.
- The built-in `tmux-agent` provider derives session reuse, existing task-window discovery, and reclaim cleanup from live git context instead of stored tmux worktree metadata.
- Switch the launched agent CLI by editing `WT_PROVIDER_AGENT_COMMAND`, `WT_PROVIDER_AGENT_COMMAND_LIGHT`, `WT_PROVIDER_AGENT_COMMAND_DARK`, and optional `WT_PROVIDER_AGENT_PROMPT_FLAG` in `.worktree-task/config.env` or the user override config.
- Runtime launch uses a temporary prompt file only long enough for the new pane to start; the repository does not keep a prompt archive.
- Linked worktree folders live outside the repository working tree, so they do not pollute `git status`.

If you installed the skill globally and want other repositories to reuse this repo's conventions, point your user config at a `wezterm-config` repo or one of its derived repos:

```bash
mkdir -p ~/.config/worktree-task
cat > ~/.config/worktree-task/config.env <<'EOF'
WEZTERM_CONFIG_REPO=/absolute/path/to/wezterm-config
EOF
```

For a repo that is itself a `wezterm-config` repo or a derived repo carrying the same conventions, keep `WEZTERM_CONFIG_REPO=.` in that repo's tracked `.worktree-task/config.env`.

If you run `launch` or `reclaim` before configuring `WEZTERM_CONFIG_REPO`, the command now stops with an explicit error telling you to run `skills/worktree-task/scripts/worktree-task configure --repo /absolute/path/to/wezterm-config` first.

Config example:

```bash
skills/worktree-task/scripts/worktree-task configure --repo /absolute/path/to/wezterm-config
```

Example:

```bash
printf '%s' "$TASK_PROMPT" | skills/worktree-task/scripts/worktree-task launch --title "short task title"
```

Useful options:

- `--base-ref <ref>` to branch from something other than the primary worktree `HEAD`
- `--branch <name>` to force a branch name
- `--provider <name|custom:name|/absolute/path>` to override the selected runtime provider
- `--provider-mode <off|auto|required>` to disable runtime launch, allow fallback, or require provider success
- `--session-name <name>` to target an already running tmux session for that repo family when launching from outside tmux
- `--variant light|dark|auto` to choose the agent CLI UI variant for the new window
- `--no-attach` to prepare the worktree and tmux window without switching the current client, including the first time that task window is created

Reclaim a finished task:

```bash
skills/worktree-task/scripts/worktree-task reclaim
```

Useful reclaim options:

- `--task-slug <slug>` to reclaim `.worktrees/<repo>/<slug>` from the current repo family
- `--worktree-root <path>` to reclaim a specific linked task worktree
- `--provider <name|custom:name|/absolute/path>` to override the provider used for cleanup
- `--provider-mode <off|auto|required>` to disable runtime cleanup, allow fallback, or require provider success
- `--force` to discard local changes and pass `-f` to `git worktree remove`
- `--keep-branch` to keep the task branch even when it is already merged

Reclaim only removes skill-managed linked worktrees under the repository parent's `.worktrees/<repo>/`. By default it refuses to remove a dirty worktree, closes tmux windows whose live pane layout still resolves to that worktree, and deletes the task branch only when that branch is already merged into the primary worktree `HEAD`.

## Diagnostics

- WezTerm-side diagnostics are configured in `wezterm-x/local/constants.lua` under `diagnostics.wezterm`.
- Runtime shell diagnostics are configured separately in `wezterm-x/local/runtime-logging.sh`, starting from `wezterm-x/local.example/runtime-logging.sh`.
- Keep both logging systems disabled by default; enable them only while investigating a problem.
- When `diagnostics.wezterm.enabled = true`, WezTerm writes structured lines to the configured `file` and also shows them in the Debug Overlay.
- Current WezTerm-side diagnostics categories include `workspace`, `alt_o`, `chrome`, `clipboard`, and `command_panel`.
- Set `diagnostics.wezterm.debug_key_events = true` only for keybinding investigations; it is intentionally noisy.
- When `WEZTERM_RUNTIME_LOG_ENABLED=1`, the runtime scripts append structured lines to `WEZTERM_RUNTIME_LOG_FILE`.
- Leave `WEZTERM_RUNTIME_LOG_CATEGORIES` empty to capture all runtime categories, or set a comma-separated list such as `alt_o,workspace,worktree`.
- Current runtime categories include `alt_o`, `workspace`, `worktree`, `managed_command`, and `command_panel`.

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
