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
4. The sync script also tries to reload tmux automatically when a tmux server is already running and reachable from the current shell. If you changed tmux styling or startup behavior and that automatic reload was unavailable or not sufficient, reload tmux config manually:

```bash
scripts/dev/reload-tmux.sh
```

Recreate affected sessions only if a simple reload is not enough.
For WakaTime key changes in `wezterm-x/local/shared.env`, a tmux reload is sufficient; that path no longer depends on WezTerm injecting environment variables into WSL.
5. If runtime shell rc files changed, reload the interactive shell in affected tmux panes or recreate those sessions.

In `hybrid-wsl`, `Ctrl+v` smart image paste now depends on a background Windows clipboard listener that refreshes `%LOCALAPPDATA%\wezterm-clipboard-cache\state.env`. The same listener appends startup and clipboard-event traces to `%LOCALAPPDATA%\wezterm-clipboard-cache\listener.log`. If text paste is fast but image-path paste stops working, sync the runtime, let WezTerm auto-reload, inspect those two files, and restart WezTerm if needed so the listener is launched again.

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
- This repository's tracked worktree-task profile lives at `.worktree-task/config.env`. It enables the built-in `tmux-agent` provider, points `WEZTERM_CONFIG_REPO=.` back at this repo, and declares reusable agent launcher profiles such as `claude` and `codex`.
- Machine-local agent selection belongs in `wezterm-x/local/shared.env` as `MANAGED_AGENT_PROFILE=claude|codex|...`.
- Config collection order is: configured `wezterm-config` repo profile, then `~/.config/worktree-task/config.env`, then the target repo's own `.worktree-task/config.env`, then the selected `wezterm-config` repo's `wezterm-x/local/shared.env`.
- Relative repo-managed paths such as `WT_PROVIDER_TMUX_CONFIG_FILE=tmux.conf` resolve against the configured `wezterm-config` repo or derived repo, not against the task repo where you launch the command.
- Use `configure --repo` as the stable recovery path whenever `WEZTERM_CONFIG_REPO` is missing; `launch` often consumes stdin for the task prompt, so configuration should not depend on waiting for input on that same stream.
- The built-in `tmux-agent` provider derives session reuse, existing task-window discovery, and reclaim cleanup from live git context instead of stored tmux worktree metadata.
- Managed workspace launchers and the built-in `tmux-agent` provider now execute the actual agent CLI inside the resolved login shell so PATH and shell startup files come from one stable source.
- Switch both managed WezTerm workspaces and the built-in `tmux-agent` provider by setting `MANAGED_AGENT_PROFILE=claude` or `MANAGED_AGENT_PROFILE=codex` in `wezterm-x/local/shared.env`.
- The tracked `codex` profile keeps bare `codex` for dark mode and uses `codex -c 'tui.theme="github"'` for the light variant, matching the previously validated repo behavior.
- Add a third-party agent CLI by defining `WT_PROVIDER_AGENT_PROFILE_<NAME>_COMMAND`, optional `_COMMAND_LIGHT`, optional `_COMMAND_DARK`, and optional `_PROMPT_FLAG`, then point `WT_PROVIDER_AGENT_PROFILE` at that profile name.
- The legacy direct overrides `WT_PROVIDER_AGENT_COMMAND`, `WT_PROVIDER_AGENT_COMMAND_LIGHT`, `WT_PROVIDER_AGENT_COMMAND_DARK`, and `WT_PROVIDER_AGENT_PROMPT_FLAG` still work, but profile-based switching is the preferred path because one selection now drives both launch surfaces.
- Runtime launch uses a temporary prompt file only long enough for the new pane to start; the repository does not keep a prompt archive.
- Linked worktree folders live outside the repository working tree, so they do not pollute `git status`.

Example machine-local override:

```bash
MANAGED_AGENT_PROFILE=codex
WAKATIME_API_KEY='your-key'
```

Example tracked or user-level profile extension:

```bash
WT_PROVIDER_AGENT_PROFILE=codex

WT_PROVIDER_AGENT_PROFILE_CODEX_COMMAND='codex'
WT_PROVIDER_AGENT_PROFILE_CODEX_COMMAND_LIGHT='codex -c ''tui.theme="github"'''

WT_PROVIDER_AGENT_PROFILE_GEMINI_COMMAND='gemini --interactive'
WT_PROVIDER_AGENT_PROFILE_GEMINI_PROMPT_FLAG='--prompt'
```

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
- Both logging systems are enabled by default at the `info` level for control-plane events so normal workspace, tmux, worktree-task, and sync flows leave an audit trail.
- When `diagnostics.wezterm.enabled = true`, WezTerm writes structured lines to the configured `file` and also shows them in the Debug Overlay.
- Current WezTerm-side diagnostics categories include `workspace`, `alt_o`, `chrome`, `clipboard`, and `command_panel`.
- Set `diagnostics.wezterm.debug_key_events = true` only for keybinding investigations; it is intentionally noisy.
- When `WEZTERM_RUNTIME_LOG_ENABLED=1`, the runtime scripts append structured lines to `WEZTERM_RUNTIME_LOG_FILE`.
- `sync-runtime.sh` also prints a one-line tmux reload result to the terminal, while the full structured detail still goes to `WEZTERM_RUNTIME_LOG_FILE`.
- Runtime and WezTerm log lines now include a shared `trace_id` so related subprocesses can be correlated while debugging.
- Runtime logs rotate with `WEZTERM_RUNTIME_LOG_ROTATE_BYTES` and `WEZTERM_RUNTIME_LOG_ROTATE_COUNT`; WezTerm-side diagnostics rotate with `diagnostics.wezterm.max_bytes` and `diagnostics.wezterm.max_files`.
- Leave `WEZTERM_RUNTIME_LOG_CATEGORIES` empty to capture all runtime categories, or set a comma-separated list such as `alt_o,workspace,worktree`.
- Current runtime categories include `alt_o`, `workspace`, `worktree`, `managed_command`, `command_panel`, `task`, `provider`, and `sync`.
- In `hybrid-wsl`, the Windows-side `Alt+o` launcher now writes structured `alt_o` lines into the same WezTerm diagnostics file, reusing the same `trace_id` and rotation settings as the Lua-side diagnostics path; those lines include millisecond timestamps plus per-phase and total `duration_ms` fields for launch-path profiling.
- In `hybrid-wsl`, the Windows runtime helper keeps a heartbeat file at `%LOCALAPPDATA%\wezterm-runtime-helper\state.env` and consumes queued request files from `%LOCALAPPDATA%\wezterm-runtime-helper\requests\`; when `Alt+o` is expected to use the helper path, check that heartbeat file first to confirm the helper is alive before reading the shared diagnostics log.
- For a repeatable live smoke test of the Windows runtime host, run [`scripts/dev/check-windows-runtime-host.sh`](../../scripts/dev/check-windows-runtime-host.sh) from WSL; it verifies helper health plus the current `Alt+o`, `Alt+b`, and clipboard-listener control paths against the synced Windows runtime.

## Hybrid WSL Agent Startup Measurement

- Use [`scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh`](../../scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh) from WSL when you want a Windows-side PowerShell test script for the currently configured managed agent CLI across the full hybrid `WSL + login shell + agent CLI` launch path.
- The generator resolves the current project agent CLI through the same `worktree-task` config chain used by the built-in `tmux-agent` provider, including `.worktree-task/config.env`, `~/.config/worktree-task/config.env`, and `wezterm-x/local/shared.env`.
- By default it writes `measure-hybrid-wsl-agent-startup-<repo>.ps1` to the Windows Desktop and targets the current WSL distro.
- The generated PowerShell wrapper invokes the generic [`scripts/dev/measure-hybrid-wsl-agent-startup.ps1`](../../scripts/dev/measure-hybrid-wsl-agent-startup.ps1) template with the resolved agent command baked in, so the wrapper tracks the current project selection instead of hard-coding a specific CLI.
- Run the generator from the target repo root or pass `--cwd /path/to/repo` to resolve a different project context.
- Use `--variant light` or `--variant dark` when you want the generated wrapper to measure that specific configured command variant instead of the default/base command.

Example:

```bash
scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh
```

After the wrapper is placed on the Desktop, run it from Windows PowerShell with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\your-user\Desktop\measure-hybrid-wsl-agent-startup-your-repo.ps1 -Pause
```

## Shell Integration

- Managed tmux flows no longer require shell rc `OSC 7` integration. tmux status and tmux-owned shortcuts resolve cwd from tmux's own `pane_current_path`.
- In `hybrid-wsl`, `default` workspace `Alt+o` still falls back to the pane when WezTerm only sees a WSL host path such as `/C:/Users/...`.
- Optional shell rc `OSC 7` integration can still improve WezTerm-side cwd inference for unmanaged tabs, fallback tab-title inference, and `default` workspace `Alt+o` behavior inside tmux.
- No shell rc edits are required for the managed tmux workflow described in this repository.

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
