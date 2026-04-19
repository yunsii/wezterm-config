# Daily Workflow

Use this doc when you need to apply or verify changes.

## Default Flow

1. Edit files in this repo.
2. If runtime files changed, sync with the `wezterm-runtime-sync` skill.
3. Let WezTerm auto-reload by default.
4. Reload tmux only when the sync step could not do it for you or when a simple reload is still needed.
5. Reload affected interactive shells if shell rc files changed.

## Runtime Sync

If repo-root `.sync-target` already points at a valid home, you can sync directly:

```bash
skills/wezterm-runtime-sync/scripts/sync-runtime.sh
```

If you need to choose or change the target home, use the explicit two-step flow:

```bash
skills/wezterm-runtime-sync/scripts/sync-runtime.sh --list-targets
skills/wezterm-runtime-sync/scripts/sync-runtime.sh --target-home /mnt/c/Users/your-user
```

Run those commands from the repo root, or set `WEZTERM_CONFIG_REPO=/absolute/path/to/repo` before invoking the script from elsewhere.

The sync step publishes the runtime, updates the stable top-level bootstrap last, and installs the Windows helper on Windows targets. The installer now prefers a local Windows `dotnet` build from `%USERPROFILE%\.wezterm-native\host-helper\windows\src\...`; if `dotnet` is unavailable, it can fall back to a version-pinned GitHub release package declared in `native/host-helper/windows/release-manifest.json`. `.sync-target` is repo-local and gitignored.

## Reload Rules

- Current WezTerm versions watch the loaded config file and `require`-loaded Lua files automatically. Use `Ctrl+Shift+R` only to force a reload when needed.
- `sync-runtime.sh` opportunistically reloads tmux when an accessible tmux server is already running.
- If you changed tmux styling or startup behavior and auto-reload was unavailable or not sufficient, run:

```bash
scripts/dev/reload-tmux.sh
```

- Recreate affected sessions only if a simple reload is not enough.
- For WakaTime key changes in `wezterm-x/local/shared.env`, a tmux reload is sufficient.

## Verification

- If only documentation changed, runtime sync and reload are not required.
- Verify workspace shortcuts still match [`keybindings.md`](./keybindings.md).
- If workspace behavior changed, verify it still matches [`workspaces.md`](./workspaces.md).
- If tmux styling or status changed, verify it still matches [`tmux-ui.md`](./tmux-ui.md).
- When task-worktree launch behavior changes, verify a new linked task worktree opens as another tmux window in the same repo-family session and later windows still fall back to the session default launcher.

For tmux reset regressions, prefer the isolated repo test suite before touching your live tmux workspace:

```bash
bash tests/tmux-reset/run.sh
```

That suite uses a dedicated temporary `tmux -L ...` socket, a temporary `HOME`, and an internal shim so it does not touch the live default tmux server.

## Common Maintenance Paths

- If text paste is fast but image-path paste stops working in `hybrid-wsl`, sync the runtime, let WezTerm auto-reload, and inspect the shared `trace_id` across `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` and `%LOCALAPPDATA%\wezterm-runtime\logs\helper.log`.
- The `open-project-session.sh` helper warns when tmux is older than 3.3. Upgrade tmux before relying on the managed theme if passthrough support is missing.

## Commit Workflow

- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
- For commit format, split guidance, and AI metadata, read [`commit-guidelines.md`](./commit-guidelines.md).
