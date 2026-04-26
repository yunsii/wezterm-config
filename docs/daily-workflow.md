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

Run those commands from the repo root, or set `WEZDECK_REPO=/absolute/path/to/repo` (legacy `WEZTERM_CONFIG_REPO` still accepted) before invoking the script from elsewhere.

The sync step publishes the runtime, updates the stable top-level bootstrap last, and installs the Windows helper on Windows targets. The installer now prefers a local Windows `dotnet` build from `%USERPROFILE%\.wezterm-native\host-helper\windows\src\...`; if `dotnet` is unavailable, it can fall back to a version-pinned GitHub release package declared in `native/host-helper/windows/release-manifest.json`. `.sync-target` is repo-local and gitignored.
It also refreshes `~/.wezterm-x/agent-tools.env` in the target home so external agent platforms can discover repo-local wrappers from one stable marker file.

Sync also mirrors `config/worktree-task.env` into the runtime dir as `repo-worktree-task.env` so the Windows-side wezterm.exe can read it; edits to `config/worktree-task.env` only take effect after the next sync. Why this matters for `<base>_resume` profile registration: see [`workspaces.md#behavior`](./workspaces.md#behavior).

Between `publish-runtime` and the Windows helper install, sync runs a `lua-precheck` that dofile-loads `wezterm-x/lua/constants.lua` under a mocked `wezterm` and asserts managed-launcher resolution still works (`default_resume_profile ≠ default_profile`, resume command literally contains `--continue` or `resume`). On failure, sync aborts with a profile-list snapshot. Requires `lua5.4` (or `lua5.3`/`lua`) on the WSL/Linux side; see [`setup.md`](./setup.md#prerequisites). When no lua is installed, the precheck is skipped with a warning rather than failing.

## Host Helper Release

Cutting a Windows host-helper release, updating `release-manifest.json`, forcing the release-install branch locally, or side-loading a pre-fetched zip is maintainer flow — see [`host-helper-release.md`](./host-helper-release.md).

## Reload Rules

- Current WezTerm versions watch the loaded config file and `require`-loaded Lua files automatically. Use `Ctrl+Shift+R` only to force a reload when needed.
- `sync-runtime.sh` opportunistically reloads tmux when an accessible tmux server is already running.
- After `step=completed`, `sync-runtime.sh` runs [`scripts/dev/check-deps-updates.sh`](../scripts/dev/check-deps-updates.sh) in advisory mode (10s timeout, prefixed with `[sync]`) and prints a comparison table for `wezterm` / `tmux` / `go` (installed vs upstream latest vs repo floor). The wezterm row tracks the **nightly** release (matches `setup.md`'s hybrid-wsl assumption), falls back to `wezterm.exe` via WSL interop, and uses **SHA-based** comparison (installed calver suffix vs `target_commitish[:8]` from the nightly release tag) — not a calver-vs-calver date comparison, because the nightly release's `updated_at` bumps on any asset re-upload even when the bundled binary is unchanged (false-positive "update available" right after a fresh install). The status reads `up-to-date` on SHA match, `tracking nightly` (informational, dim, does not trigger the reminder line or non-zero exit) on mismatch. The go row mirrors `native/picker/build.sh`'s discovery chain (PATH → `~/.local/go/bin/go` → `/usr/local/go/bin/go`) so a manual install under `~/.local/go` is recognized even when the sync shell didn't inherit the PATH addition. It never fails the sync; offline upstreams degrade to `offline?`. Set `WEZTERM_SYNC_SKIP_DEPS_CHECK=1` to suppress the step (e.g. on flaky networks or in CI).
- When the table reports `update available`, the script prints a per-tool "what's new" block beneath the reminder. It prefers the project's own changelog — wezterm `docs/changelog.md` (Continuous/Nightly section, starting at the first `#### ` subsection so intro prose is skipped) and tmux `CHANGES` (the `CHANGES FROM <installed> TO ...` section). When the changelog is unreachable or its section is missing, it falls back to the upstream branch's recent commit titles via the GitHub commits API, filtering out routine entries (docs/ci/chore/dep-bumps/merges) so what surfaces is the recent feat/fix/perf signal. The go row stays as URL-only because release notes are too large to summarize meaningfully inline.
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
