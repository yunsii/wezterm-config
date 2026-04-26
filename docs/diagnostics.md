# Diagnostics

Use this doc when you need logs, smoke tests, or troubleshooting paths.

## Logging Defaults

- WezTerm-side diagnostics are configured in `wezterm-x/local/constants.lua` under `diagnostics.wezterm`.
- Runtime shell diagnostics are configured separately in `wezterm-x/local/runtime-logging.sh`, starting from `wezterm-x/local.example/runtime-logging.sh`.
- Both logging systems are enabled by default at the `info` level for control-plane events.

## WezTerm Diagnostics

- When `diagnostics.wezterm.enabled = true`, WezTerm writes structured lines to the configured file and also shows them in the Debug Overlay.
- Current WezTerm-side diagnostics categories include `workspace`, `vscode`, `chrome`, `clipboard`, `command_panel`, `host_helper`, and `hotkey`.
- Set `diagnostics.wezterm.debug_key_events = true` only for keybinding investigations.
- WezTerm-side diagnostics rotate with `diagnostics.wezterm.max_bytes` and `diagnostics.wezterm.max_files`.

## Runtime Diagnostics

- When `WEZTERM_RUNTIME_LOG_ENABLED=1`, the runtime scripts append structured lines to `WEZTERM_RUNTIME_LOG_FILE`.
- `sync-runtime.sh` prints a one-line tmux reload result to the terminal, while the full structured detail still goes to `WEZTERM_RUNTIME_LOG_FILE`.
- `sync-runtime.sh` also prints `[sync] step=...` milestones for the chosen target, helper install, bootstrap refresh, and tmux reload status.
- Runtime logs rotate with `WEZTERM_RUNTIME_LOG_ROTATE_BYTES` and `WEZTERM_RUNTIME_LOG_ROTATE_COUNT`.
- Leave `WEZTERM_RUNTIME_LOG_CATEGORIES` empty to capture all runtime categories, or set a comma-separated list such as `vscode,workspace,worktree`.
- Current runtime categories include `vscode`, `workspace`, `worktree`, `managed_command`, `command_panel`, `task`, `provider`, and `sync`.

## Traceability

- Runtime and WezTerm log lines include a shared `trace_id` so related subprocesses can be correlated while debugging.
- In `hybrid-wsl`, `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` and `%LOCALAPPDATA%\wezterm-runtime\logs\helper.log` are the main diagnostics files.
- Host-helper reuse diagnostics emit explicit decision fields such as `decision_path`, `registry_hit`, `matched_process_count`, `matched_process_ids`, and `matched_window_found`.
- The helper installer prints and records its chosen source as `install_source=local|release`, and writes the last installed release metadata to `%LOCALAPPDATA%\wezterm-runtime\bin\helper-install-state.json`.
- Release installs also report `release_archive_source`, `release_archive_path`, and `release_download_url` so you can distinguish cache hits, manually preloaded archives, URL overrides, and direct manifest downloads.

## Hotkey Usage Counter

Aggregate press counts — no event log — for every WezTerm keymap entry and the tmux command-chord actions. The counter is meant for "do I press this often enough to deserve a better key" decisions, not forensics.

- Storage: `$WEZTERM_RUNTIME_STATE_DIR/hotkey-usage.json` (under `%LOCALAPPDATA%\wezterm-runtime\` in hybrid-wsl). Single JSON file, no rotation.
- File layout (versioned):

```json
{
  "schema_version": 1,
  "updated_at": "<ISO8601 UTC>",
  "hotkeys": {
    "<manifest.id>": {
      "count": <int>,
      "first_seen": "<ISO8601 UTC>",
      "last_seen":  "<ISO8601 UTC>"
    }
  }
}
```

- Writers (both take the same `<hotkey_id>` argument and share a file lock):
  - WezTerm side: [`wezterm-x/lua/usage.lua`](../wezterm-x/lua/usage.lua) spawns [`scripts/runtime/hotkey-usage-bump.sh`](../scripts/runtime/hotkey-usage-bump.sh) via `background_child_process` (fire-and-forget; no blocking on the keypress path).
  - tmux chord side: each `command-chord` binding in `tmux.conf` prefixes the action with `run-shell -b "bash .../hotkey-usage-bump.sh <id>"`.
- Ids are the manifest entry ids from [`wezterm-x/commands/manifest.json`](../wezterm-x/commands/manifest.json). Every hotkey should be registered there (enforced by the rule in [`AGENTS.md`](../AGENTS.md)); ad-hoc ids that ever slip through render with label `(unregistered)` in the report, which is the signal to add the missing manifest entry.
- Run [`scripts/dev/hotkey-usage-report.sh`](../scripts/dev/hotkey-usage-report.sh) for a sorted table (count, keys, id, label, first-seen, last-seen ages). `--json` dumps the raw counter, `--path` prints the resolved file path.
- Deleting the counter file is safe and resets all counts; the bump script recreates it on the next press.
- The counter is aggregate-only. For per-press audit (which pane, which foreground program, which WezTerm domain saw the key), look at `category="hotkey" message="bump"` lines in the WezTerm runtime log — same file as the other WezTerm categories, filtered via `diagnostics.wezterm.categories`. Use this to investigate suspicious rows such as "this hotkey rose to N but I never pressed it" — the log will tell you whether the source was a tmux TUI, a Windows IME translation, a keyboard remap, etc. tmux chord bumps do not emit this line (the shell bump path has no pane context); only WezTerm keymap bumps do.

## Smoke Tests

- For a repeatable live smoke test of the Windows runtime host, run [`scripts/dev/check-windows-runtime-host.sh`](../scripts/dev/check-windows-runtime-host.sh) from WSL.
- The Windows host smoke test validates both text and image clipboard IPC, including the tracked [`assets/copy-test.png`](../assets/copy-test.png) path.
- For the repo-local agent clipboard wrapper, run [`scripts/dev/check-agent-clipboard.sh`](../scripts/dev/check-agent-clipboard.sh) from WSL. It writes text through `scripts/runtime/agent-clipboard.sh`, reads it back through `resolve_for_paste`, then repeats the flow for the tracked image asset.
- For dependency drift (wezterm / tmux / go) against upstream latest and the repo's declared floors (tmux 3.6 in `scripts/runtime/tmux-version-lib.sh`, go 1.21 in `native/picker/go.mod`; wezterm has no floor), run [`scripts/dev/check-deps-updates.sh`](../scripts/dev/check-deps-updates.sh) from WSL. Read-only; skips `go` when no `go` binary is on PATH; degrades to `offline?` when GitHub or `go.dev` are unreachable. Exits non-zero on floor violation or "update available". Also runs automatically as the last `sync-runtime.sh` step in advisory mode (`--advisory --no-color --timeout 4 --prefix '[sync] '`); set `WEZTERM_SYNC_SKIP_DEPS_CHECK=1` to skip it during sync.
- For tmux reset regressions, prefer the isolated repo test suite:

```bash
bash tests/tmux-reset/run.sh
```

- For the agent-attention pipeline, run [`scripts/dev/test-agent-attention.sh`](../scripts/dev/test-agent-attention.sh) from inside a WezTerm pane. The default subcommand drives the real hook, asserts the shared state file reflects each transition, and polls `wezterm.log` for a `category="attention" message="tick received"` line per emission. State keys on `pane:<WEZTERM_PANE>` so the entry is scoped to the current WezTerm pane and the run ends with it removed.
- Subcommands: `cycle-visual` for a slower human-in-the-loop demo with 3-second pauses; `running` / `waiting` / `done` / `cleared` / `resolved` to exercise a single state transition (caller cleans up); `show` to dump the current state file via `jq`; `clear-all` to truncate the state file and nudge WezTerm to redraw — useful after manual experimentation leaves stale entries. `resolved` mirrors the `PostToolUse` hook and is a conditional transition: `waiting` or `done` flips to `running` in place (preserving the entry so the counter reflects mid-turn work — including a Monitor subscription that woke the agent after a prior `Stop`), a missing entry is upserted as `running`, and `running` is a no-op that skips the OSC tick so diagnostics stay quiet on auto-allowed tool calls.

## Hybrid WSL Startup Measurement

- Use [`scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh`](../scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh) from WSL when you want a Windows-side PowerShell test script for the currently configured managed agent CLI across the full hybrid `WSL + login shell + agent CLI` launch path.
- The generated PowerShell wrapper invokes [`scripts/dev/measure-hybrid-wsl-agent-startup.ps1`](../scripts/dev/measure-hybrid-wsl-agent-startup.ps1) with the resolved agent command baked in.
- Run the generator from the target repo root or pass `--cwd /path/to/repo` to resolve a different project context.

Example:

```bash
scripts/dev/install-hybrid-wsl-agent-startup-desktop-script.sh
```

After the wrapper is placed on the Desktop, run it from Windows PowerShell with execution policy bypass:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\your-user\Desktop\measure-hybrid-wsl-agent-startup-your-repo.ps1 -Pause
```

## Troubleshooting Notes

- If the tmux status line still reflects stale branch or change counts after a local `git` command and only catches up on the next 30s poll, the recommended prompt hook is probably not installed. From an affected tmux pane run `typeset -f __tmux_status_prompt_refresh >/dev/null && echo ok || echo missing`; when it prints `missing`, add the source line documented in [`setup.md`](./setup.md#tmux-status-prompt-hook) to your shell rc and re-source it — existing shells will not pick up the hook until you do.
- If text paste is fast but image-path paste stops working in `hybrid-wsl`, sync the runtime, let WezTerm auto-reload, and inspect the shared `trace_id` across the WezTerm and helper logs.
- In `hybrid-wsl`, WezTerm prewarms the host helper during GUI startup, then still falls back to on-demand ensure when the helper later goes stale or bootstrap state is missing.
- To reproduce the release fallback on a machine that already has Windows `dotnet`, run sync with `WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=release` and inspect `helper-install-state.json` plus the `[helper-install]` terminal lines for `installed_source`, `release_version`, and the installed binary paths.
- If GitHub downloads are too slow, place the zip at `%LOCALAPPDATA%\wezterm-runtime\artifacts\host-helper\<version>\<assetName>` or set `WEZTERM_WINDOWS_HELPER_RELEASE_ARCHIVE`, then rerun sync and confirm `release_archive_source=preload_versioned|preload_flat|explicit_archive`.
