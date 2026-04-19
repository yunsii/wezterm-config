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
It also refreshes `~/.wezterm-x/agent-tools.env` in the target home so external agent platforms can discover repo-local wrappers from one stable marker file.

## Host Helper Release Rollout

When you need the Windows helper to install on machines without a local Windows `dotnet` SDK:

1. Run the GitHub Actions workflow [`.github/workflows/host-helper-release.yml`](/home/yuns/github/wezterm-config/.github/workflows/host-helper-release.yml) with a new `host-helper-v...` tag, or push that tag to trigger the workflow automatically.
2. Copy the release tag and SHA-256 from the workflow summary.
3. Update the pinned fallback manifest from a repo checkout:

```bash
scripts/dev/update-host-helper-release-manifest.sh --tag host-helper-v2026.04.19.1 --sha256 <sha256>
```

4. Sync the runtime as usual so the updated manifest is copied to Windows targets.

To force the release path even on a machine that already has Windows `dotnet`, set:

```bash
WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=release skills/wezterm-runtime-sync/scripts/sync-runtime.sh
```

Use `WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=local` when you want to verify the local-build path explicitly. Leave it unset for normal `auto` behavior.

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
- When changing repo-local helper wrappers under `scripts/runtime/`, add or update a narrow command-level check before relying on broader host smoke tests.
- When task-worktree launch behavior changes, verify a new linked task worktree opens as another tmux window in the same repo-family session and later windows still fall back to the session default launcher.

## Agent Windows Checks

- When an agent needs to verify Windows helper behavior from WSL, run the repo entrypoints such as `scripts/dev/check-windows-runtime-host.sh` or `scripts/dev/check-agent-clipboard.sh` instead of direct `cmd.exe` probes.
- When an agent needs to inspect `%LOCALAPPDATA%\wezterm-runtime\...`, source `scripts/runtime/windows-runtime-paths-lib.sh`, call `windows_runtime_detect_paths`, and then use `ls`, `cat`, or `rg` on the resolved `*_WSL` paths.
- If an agent needs to execute inline PowerShell from shell code, source `scripts/runtime/windows-shell-lib.sh` and use `windows_run_powershell_script_utf8` or `windows_run_powershell_command_utf8` so UTF-8 output stays stable and shell interpolation does not corrupt the command body.

Example runtime-state inspection from WSL:

```bash
source scripts/runtime/windows-runtime-paths-lib.sh
windows_runtime_detect_paths
ls "$WINDOWS_RUNTIME_STATE_WSL/cache/downloads"
cat "$WINDOWS_RUNTIME_STATE_WSL/bin/helper-install-state.json"
```

For tmux reset regressions, prefer the isolated repo test suite before touching your live tmux workspace:

```bash
bash tests/tmux-reset/run.sh
```

That suite uses a dedicated temporary `tmux -L ...` socket, a temporary `HOME`, and an internal shim so it does not touch the live default tmux server.

## Common Maintenance Paths

- If text paste is fast but image-path paste stops working in `hybrid-wsl`, sync the runtime, let WezTerm auto-reload, and inspect the shared `trace_id` across `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` and `%LOCALAPPDATA%\wezterm-runtime\logs\helper.log`.
- If `scripts/runtime/agent-clipboard.sh` fails, first rerun [`scripts/dev/check-agent-clipboard.sh`](../scripts/dev/check-agent-clipboard.sh) to distinguish a wrapper bug from a lower-level helper or clipboard issue.
- If an external agent platform cannot find the clipboard wrapper, verify that the latest sync wrote `~/.wezterm-x/agent-tools.env` and that its `agent_clipboard` path still exists.
- The `open-project-session.sh` helper warns when tmux is older than 3.3. Upgrade tmux before relying on the managed theme if passthrough support is missing.

## Commit Workflow

- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
- For commit format, split guidance, and AI metadata, read [`commit-guidelines.md`](./commit-guidelines.md).
