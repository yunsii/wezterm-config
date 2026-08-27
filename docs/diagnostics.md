# Diagnostics

Use this doc when you need logs, smoke tests, or troubleshooting paths.

## Logging Defaults

- WezTerm-side diagnostics are configured in `wezterm-x/local/constants.lua` under `diagnostics.wezterm`.
- Runtime shell diagnostics are configured separately in `wezterm-x/local/runtime-logging.sh`, starting from `wezterm-x/local.example/runtime-logging.sh`.
- Both logging systems are enabled by default at the `info` level for control-plane events.

## Conventions for Emitting Logs

Author-facing rules — file placement, render-path discipline, category schema, levels, required fields, and the field-name dictionary — live in [`logging-conventions.md`](./logging-conventions.md). Read that doc before adding a new logger callsite, a new category, or a new log file.

## WezTerm Diagnostics

- When `diagnostics.wezterm.enabled = true`, WezTerm writes structured lines to the configured file and also shows them in the Debug Overlay.
- Current WezTerm-side diagnostics categories include `workspace`, `vscode`, `chrome`, `clipboard`, `command_panel`, `host_helper`, `hotkey`, and `latency`.
- Set `diagnostics.wezterm.debug_key_events = true` only for keybinding investigations.
- WezTerm-side diagnostics rotate with `diagnostics.wezterm.max_bytes` and `diagnostics.wezterm.max_files`.

## Key / status latency

Occasional typing stutter or slow shortcuts usually means the WezTerm UI thread was busy. Ordinary character keys never enter Lua, so this surface measures two proxies and writes them to `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log`:

| Signal | Meaning | Default gate |
|---|---|---|
| `category="latency" message="slow key handler"` | A WezTerm-layer manifest hotkey's `perform_action` (including usage bump) took too long | `duration_ms >= 50` |
| `category="latency" message="slow status tick"` | One `update-status` callback (250 ms cadence) took too long — the closest proxy for "typing felt sticky" | `duration_ms >= 40` |

Shared fields: `duration_ms`, `threshold_ms`, `kind="hotkey|status"`, plus `hotkey_id` / `workspace` / `pane_id` / `domain` / `foreground` when available.

Slow **status** rows also attach a phase breakdown (ms) so a sticky tick can be attributed without turning on `emit_all`:

| Field | Block in `titles.lua` `update-status` |
|---|---|
| `phase_left_ms` | focus marker + left-status workspace label |
| `phase_tabvis_ms` | `tab_visibility.tick` + sample / overflow-collision / hot-reorder |
| `phase_prefetch_ms` | `refresh_all_items_snapshots` + background overflow-base rebuild |
| `phase_attention_ms` | per-tick cache reset, TTL prune, focus-ack |
| `phase_live_snap_ms` | `attention.maybe_refresh_live_snapshot` (1 s throttle) |
| `phase_event_bus_ms` | `event_bus.poll_files` |
| `phase_right_ms` | right-status segments + render log |

These fields are investigation instrumentation; drop them once the sticky-tick owner is fixed and verified.

**2026-08-27 sticky Alt+c/w:** slow ticks were ~every 5s with `phase_prefetch_ms` p50≈810ms — `refresh_all_items_snapshots` matching tabs via repeated `pane:get_current_working_dir()` (O(tabs×items) on hybrid-wsl). Fix: title-first match + at most one cwd resolve per tab, and skip the NTFS rewrite when the snapshot body is unchanged. Re-check with `grep phase_prefetch_ms= …/wezterm.log | tail`.

**Slow rows also attach a guest-pressure snapshot** (only when `duration_ms` crosses the gate — never on the quiet path or on `latency.perf` under-threshold samples):

| Field | Source |
|---|---|
| `mem_level` / `mem_used_pct` / `mem_avail_mib` / `swap_used_pct` | `state/oom-guard/status.json` (same file as the `M·` badge) |
| `loadavg_1` / `loadavg_5` / `loadavg_15` | guest `/proc/loadavg`, published by `wsl-oom-guard.sh` |
| `proc_runnable` / `proc_total` | runnable/total from the same loadavg line |
| `top_comm` / `top_rss_mib` | only when the badge level is not `ok` |

Reads are cached ~2 s (`diagnostics.wezterm.latency.pressure_cache_ms`) so a storm of slow ticks shares one NTFS open. Disable with `pressure_enrich = false`. Freshness follows the oom-record publish cadence (~30 s) — enough to tell "was the guest hot?" after a sticky-typing report, not a profiler.

Config (tracked defaults in `wezterm-x/lua/constants.lua`, override in `wezterm-x/local/constants.lua`):

```lua
diagnostics = {
  wezterm = {
    latency = {
      hotkey_slow_ms = 50,
      status_slow_ms = 40,
      emit_all = false,  -- true → also write every sample under latency.perf
      -- pressure_enrich = false,       -- opt out of mem/loadavg on slow rows
      -- pressure_cache_ms = 2000,
    },
    -- If you use a categories allowlist, keep latency = true or slow
    -- rows are filtered out by the logger.
    categories = { latency = true, --[[ … ]] },
  },
}
```

Operator commands:

```bash
# Daily slow-event counts + p50/p95 from wezterm.log
scripts/dev/latency-report.sh

# Only workspace switches / only status ticks
scripts/dev/latency-report.sh --hotkey-id workspace.switch
scripts/dev/latency-report.sh --kind status

# Live tail while reproducing a stutter (shows mem/loadavg when present)
scripts/dev/latency-report.sh --watch

# One day's slow rows with pressure columns
scripts/dev/latency-report.sh --raw today
```

Limits: this does not measure GPU frame time, WSL/tmux internal lag, or OS IME candidate-window delay. A quiet log during a felt stutter means the blockage is outside these Lua callbacks — use that as a negative signal, not as "nothing happened". Pressure fields are guest-side (WSL); they will not explain a Windows-host-only CPU spike.

## Runtime Diagnostics

- When `WEZTERM_RUNTIME_LOG_ENABLED=1`, the runtime scripts append structured lines to `WEZTERM_RUNTIME_LOG_FILE`.
- `sync-runtime.sh` prints a one-line tmux reload result to the terminal, while the full structured detail still goes to `WEZTERM_RUNTIME_LOG_FILE`.
- `sync-runtime.sh` also prints `[sync] step=...` milestones for the chosen target, helper install, bootstrap refresh, and tmux reload status. Each gated step (`helper-install`, `helper-ensure`, `lua-precheck`, `deps-check`) emits an explicit `status=skipped reason=...` line when its skip-if-current check passed; full reasons + force-bypass envs are tabulated in [`daily-workflow.md#skip-if-current-and-force-overrides`](./daily-workflow.md#skip-if-current-and-force-overrides).
- Runtime logs rotate with `WEZTERM_RUNTIME_LOG_ROTATE_BYTES` and `WEZTERM_RUNTIME_LOG_ROTATE_COUNT`.
- Leave `WEZTERM_RUNTIME_LOG_CATEGORIES` empty to capture all runtime categories, or set a comma-separated list such as `vscode,workspace,worktree`.
- Current runtime categories include `vscode`, `workspace`, `worktree`, `managed_command`, `command_panel`, `task`, `provider`, and `sync`.

### Sync-side state files

Three small artifacts under `$WEZTERM_RUNTIME_STATE_DIR` (i.e. `%LOCALAPPDATA%\wezterm-runtime\` in hybrid-wsl) drive sync's skip-if-current decisions; deleting any of them forces the next sync to run the corresponding gate from scratch:

- `bin/helper-install-state.json` — written by the PowerShell installer at the end of every successful install. Its **mtime** is sync-runtime's "last successful helper install" marker; `find -newer` on `native/host-helper/windows/src/**` and the `release-manifest.json` against this file decides whether `dotnet publish` runs again.
- `state/helper/state.env` — written by the running helper-manager every ~250ms. `ready=1` + filesystem mtime within ~10s of now is sync-runtime's "helper alive" signal that lets `helper-ensure` skip the PowerShell round-trip. CRLF line endings (PowerShell-written) — readers must strip `\r` before string-comparing values.
- `lua-precheck.ok` — empty sentinel touched by `sync-runtime.sh` after each successful Lua precheck. `find -newer` on `~/.wezterm-x/lua/`, `~/.wezterm-x/repo-worktree-task.env`, and the precheck script itself against this file decides whether to re-run the precheck.

`logs/deps-check.log` is a separate artifact: it's both the deps-check output (since the check now runs detached, see daily-workflow.md) AND the daily-rate-limit gate (its mtime date is compared against today's date).

## Traceability

- Runtime and WezTerm log lines include a shared `trace_id` so related subprocesses can be correlated while debugging.
- In `hybrid-wsl`, `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` and `%LOCALAPPDATA%\wezterm-runtime\logs\helper.log` are the main diagnostics files.
- Host-helper reuse diagnostics emit explicit decision fields such as `decision_path`, `registry_hit`, `matched_process_count`, `matched_process_ids`, and `matched_window_found`.
- The helper installer prints and records its chosen source as `install_source=local|release`, and writes the last installed release metadata to `%LOCALAPPDATA%\wezterm-runtime\bin\helper-install-state.json`.
- Release installs also report `release_archive_source`, `release_archive_path`, and `release_download_url` so you can distinguish cache hits, manually preloaded archives, URL overrides, and direct manifest downloads.

## Hotkey Usage Counter

Aggregate press counts — no event log — for every WezTerm keymap entry and the tmux command-chord actions. The counter is meant for "do I press this often enough to deserve a better key" decisions, not forensics.

- Storage: `~/.local/state/wezterm-runtime/state/hotkey-usage.json` (WSL ext4 via `WSL_HOTKEY_USAGE_FILE` in `wsl-runtime-paths-lib.sh`). Pure WSL bash writer + reader — not under `%LOCALAPPDATA%`. Single JSON file, no rotation.
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
- The counter is aggregate-only. For **per-press audit** of WezTerm-layer bindings, look at `category="hotkey"` rows in `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` (filtered via `diagnostics.wezterm.categories` — keep `hotkey = true` when using an allowlist):

  | message | Meaning |
  |---|---|
  | `pressed` | Keymap wrap entered — the binding fired (or at least reached Lua after any UI-thread queue) |
  | `dispatched` | `perform_action` returned — `ok="1"` means no Lua error; `duration_ms` is wrap wall time |

  Shared fields: `hotkey_id`, `workspace`, `pane_id`, `domain`. Nested action logs (for example `category="workspace" message="workspace open completed"`) carry the same `hotkey_id` when the open was driven by a hotkey wrap, so one grep correlates press → business logic:

  ```bash
  grep 'hotkey_id="workspace.switch-work"' \
    /mnt/c/Users/*/AppData/Local/wezterm-runtime/logs/wezterm.log | tail
  ```

  How to read a "key did nothing" report:
  1. **No `pressed`** — binding never reached Lua (IME swallow, wrong layer, focus elsewhere, or UI thread still blocked so the wrap has not run yet).
  2. **`pressed` but no `dispatched`** — handler still running / crashed before return (`ok="0"` on a later dispatched row).
  3. **`dispatched ok=1` but no matching action log** — wrap finished but the action was a no-op or lives outside logged code (built-in WezTerm action with no Lua side effect).
  4. **Both hotkey rows + action log** — logic ran; if the UI still felt stuck, look at preceding `slow status tick` / `phase_*` rows.

  tmux chord bumps do **not** emit these lines (the shell bump path has no pane context); only WezTerm keymap wraps do.

## Smoke Tests

- For a repeatable live smoke test of the Windows runtime host, run [`scripts/dev/check-windows-runtime-host.sh`](../scripts/dev/check-windows-runtime-host.sh) from WSL.
- The Windows host smoke test validates both text and image clipboard IPC, including the tracked [`assets/copy-test.png`](../assets/copy-test.png) path.
- For the repo-local agent clipboard wrapper, run [`scripts/dev/check-agent-clipboard.sh`](../scripts/dev/check-agent-clipboard.sh) from WSL. It writes text through `scripts/runtime/agent-clipboard.sh`, reads it back through `resolve_for_paste`, then repeats the flow for the tracked image asset.
- For dependency drift (wezterm / tmux / go) against upstream latest and the repo's declared floors (tmux 3.7 in `scripts/runtime/tmux-version-lib.sh`, go 1.21 in `native/picker/go.mod`; wezterm has no floor), run [`scripts/dev/check-deps-updates.sh`](../scripts/dev/check-deps-updates.sh) from WSL. Read-only; skips `go` when no `go` binary is on PATH; degrades to `offline?` when GitHub or `go.dev` are unreachable. Exits non-zero on floor violation or "update available". Also runs automatically as the last `sync-runtime.sh` step in advisory mode (`--advisory --no-color --timeout 4 --prefix '[sync] '`); set `WEZTERM_SYNC_SKIP_DEPS_CHECK=1` to skip it during sync.
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

## Guest OOM Hardening

Guest memory exhaustion does not present as "a process died" — it presents as **the whole distro vanishing and then flapping**. Reference incident (2026-07-25): `init.scope` peaked at 41.8G of the 44G `memory=` budget with 10.1G of 11G swap consumed, the OOM killer fired inside `init.scope`, and the distro then powered off and restarted every 32.4s for ~27 minutes before the VM itself rebooted.

**Judging it in 10 seconds:** if `dmesg` timestamps do **not** reset across the restart cycles (paired `systemd-shutdow` SIGTERM + `EXT4-fs … unmounting` → `mounted`), the VM kernel is alive and only the *distro* is restarting. A reset to `[0.000000]` means the VM really rebooted. The restart count is also recoverable from `/var/log/journal/<machine-id>/*.journal~` — journald renames the file on every unclean start, so fragment count ≈ restart count.

Two units, installed together by [`scripts/dev/install-wsl-oom-guard.sh`](../scripts/dev/install-wsl-oom-guard.sh) and both driving [`scripts/runtime/wsl-oom-guard.sh`](../scripts/runtime/wsl-oom-guard.sh):

| Unit | Type | What it does |
|---|---|---|
| `wezterm-oom-protect.service` | oneshot at boot | Writes `-1000` to `oom_score_adj` of WSL's init (comm `init-systemd(Ub…)`, normally PID 2), making it OOM-immune, and `-800` to every tmux server — then **sweeps the inherited copies back to `0`** (see below; without the sweep this unit is worse than useless). Guest OOM still kills the fattest process; it can no longer kill the process WSL uses to decide the distro still has sessions, nor the one holding every pane. `oom_score_adj` resets on every distro start, which is why this is a unit and not a one-off `echo`. |
| `wezterm-oom-record.service` | long-running | Polls `init.scope/memory.events` + `MemAvailable`; dumps a top-N RSS snapshot (with each PID's `oom_score_adj`) on an `oom_kill` increment, on crossing the high-water mark, and at startup when the counter is already non-zero. Also **re-applies the protection set every tick** and **publishes the `M·` badge JSON** — see below. Runs at `OOMScoreAdjust=-900` so the recorder outlives the pressure it records. |

**`oom_score_adj` is inherited across `fork`, and that inversion is the whole trap.** Protecting WSL init does not protect one process — it silently immunizes *every* process spawned under it, because each new WSL session descends from PID 2 and inherits its value. Under tmux the leak compounds: panes inherit the tmux server's `-800`, and so does every agent and dev server started in them. Measured right after a `tmux kill-server` on this host: **119 of `init.scope`'s processes carried a protected value when exactly 2 should have — ~6.7 Gi of the largest consumers (claude, `chrome-devtools-mcp`, node, esbuild) all off the OOM killer's candidate list.** That is strictly worse than installing nothing: the kernel still has to reclaim, but no worthwhile victim is eligible, so it kills small useless processes or fails to reclaim at all.

So `protect` finishes by resetting to `0` any process in the watched cgroup that carries a protected value and is not one of the protected PIDs — and the recorder repeats the sweep every tick, since new sessions keep inheriting (the count climbed 119 → 152 in the minutes between two checks). Two properties make the sweep safe:

- **Scoped to `init.scope`, which separates "inherited by accident" from "set on purpose" without guessing.** `systemd-udevd` (`-1000`) and `sshd` (`-1000`) are legitimate systemd `OOMScoreAdjust=` settings, as is the recorder's own `-900`; all three live in `system.slice`, outside the swept cgroup, and are never touched. Verified by reading `/proc/<pid>/cgroup`.
- **Only the two protected values are reset.** Deliberate *positive* values elsewhere (the OpenClaw gateway sits at `+200`) mean "prefer killing me" and are left alone.

`wsl-oom-guard.sh status` reports this directly:

```
inherited leak: 0 process(es) in the cgroup wrongly carry -1000/-800 (should be 0)
```

A number that stays above zero means the sweep is off or not keeping up. Note a non-root sweep only reaches processes you own — WSL's `SessionLeader` / `Relay(…)` plumbing is root-owned, so ~28 entries persist until the root-run recorder does a tick. `WEZTERM_OOM_DRY_RUN=1` counts what the sweep would change without writing.

Two more non-obvious details in the protection set:

- **tmux cannot be covered by the boot-time oneshot.** A tmux server starts when the user first opens WezTerm, long after `multi-user.target`, and arrives with `oom_score_adj=0`. That is why `wezterm-oom-record` re-applies protection on every poll tick — a new or restarted tmux server converges within `WEZTERM_OOM_WATCH_INTERVAL`. Writes are idempotent and failures are latched per PID, so a steady state logs nothing.
- **tmux servers are unfindable by `pgrep`.** `comm` is `tmux: server` (so `pgrep -x tmux` misses) while `cmdline` is still the original `tmux new-session …` (so `pgrep -f 'tmux: server'` misses too). The guard scans `/proc/*/comm`.
- **tmux gets `-800`, not `-1000`.** A tmux server holds every pane's scrollback and can genuinely grow; `-800` means it is only pickable when it is itself using >80% of memory, so the one case where tmux really is the hog stays actionable instead of becoming a blind spot.

```bash
sudo ./scripts/dev/install-wsl-oom-guard.sh      # install + enable + start
./scripts/dev/install-wsl-oom-guard.sh --check   # no root, no writes
./scripts/dev/install-wsl-oom-guard.sh --print   # dump the generated units
sudo ./scripts/dev/install-wsl-oom-guard.sh --uninstall
scripts/runtime/wsl-oom-guard.sh status          # protection state + headroom
```

- Evidence lands in `journalctl -u wezterm-oom-record` **and** `/var/log/wezterm-oom-guard.log`. The plain file exists because the journal fragments across exactly the restart loop this guard diagnoses.
- Env knobs: `WEZTERM_OOM_GUARD_LOG`, `WEZTERM_OOM_WATCH_INTERVAL` (10s), `WEZTERM_OOM_WATCH_HIGH_PCT` (85), `WEZTERM_OOM_WATCH_TOP_N` (8), `WEZTERM_OOM_SCOPE`, `WEZTERM_OOM_PROTECT_ADJ` (-1000), `WEZTERM_OOM_TMUX_ADJ` (-800), `WEZTERM_OOM_PROTECT_TMUX` (1), `WEZTERM_OOM_RENORMALIZE` (1), `WEZTERM_OOM_DRY_RUN` (0). Badge-side: `WEZTERM_OOM_STATUS_FILE`, `WEZTERM_OOM_PUBLISH_INTERVAL` (30s), `WEZTERM_OOM_WARN_PCT` (85), `WEZTERM_OOM_CRIT_PCT` (93), `WEZTERM_OOM_SWAP_WARN_PCT` (70), `WEZTERM_OOM_SWAP_CRIT_PCT` (90), `WEZTERM_OOM_MEMINFO` (test fixture hook). Fragmentation-axis knobs (`WEZTERM_OOM_FRAG_*`) are listed with [the third failure mode](#the-third-failure-mode-a-high-order-allocation-failure-takes-the-vm-down).
- `wsl-oom-guard.sh status` prints one line per protected process with `(protected)` / `(NOT protected)`. After a distro restart that is the one-command check that the boot path still works.
- **The high-water snapshot is the load-bearing one.** A snapshot taken *after* `oom_kill` increments no longer contains the process that died; the pre-kill snapshot names it.
- **Neither unit reduces memory usage or prevents OOM.** They change *who* dies and guarantee a record. Acting on the pressure is `earlyoom`'s job (below); capping the actual consumers is a separate decision — see "Standing memory consumers".
- Prior art: `earlyoom` and `systemd-oomd` were both considered and deferred at first, on the grounds that this pair is deliberately narrower — exemption plus evidence, no policy, no apt dependency. The 2026-07-26 livelock (below) is exactly the "act before the kernel does" case that was left open, and `earlyoom` is now installed alongside. `systemd-oomd` stays rejected, for a reason specific to this host — see below.
- Kernel OOM lines are **already** captured (journald `ReadKMsg` defaults on in the default namespace; `journalctl -k` works). They are still easy to lose: `misc dxg: dxgkio_query_adapter_info` spam runs ~145 lines/s and wraps the `dmesg` ring buffer within seconds. In the reference incident no kernel OOM line survived anywhere — only the `init.scope` cgroup counter, which the VM kernel carries across distro restarts and which systemd therefore re-reported at every one of the ~50 restarts.

### The second failure mode: reclaim livelock with no OOM kill

Reference incident 2026-07-26. Same root cause family as 2026-07-25 (guest memory exhausted), **opposite presentation**: nothing was killed, there was no restart loop, and the distro simply stopped responding with all cores pinned until `taskkill /f /im wslservice.exe` from an elevated Windows prompt.

**Do not use "no OOM record" to rule out memory.** `journalctl -b -1` contained no `Out of memory: Killed process`, and the cgroup counter read `oom_kill=0` the whole time. What it did contain:

```
15:21:22 zsh: page allocation failure: order:4, mode:0x40c40(GFP_NOFS)
15:21:23 Free swap = 0kB    Total swap = 11534336kB
         free:61954 (≈248MB)  inactive_anon:33.7G  pagetables:740784kB
```

Three things to read from that:

1. **`Free swap = 0kB` with ~250 MB free is the whole diagnosis.** 44 GiB + 11 GiB swap, both gone.
2. **Timestamp spacing in the kernel log is itself evidence.** Consecutive lines of a *single* call trace drifted from sub-second to 10 s, 30 s, then three minutes (`15:24:10` → `15:27:36`). When journald cannot get scheduled to write one line for three minutes, the livelock is established without needing any other measurement.
3. **Why nothing died.** The failing allocations were `order:4` (64 KiB). Above `PAGE_ALLOC_COSTLY_ORDER` (3) the kernel does **not** invoke the OOM killer — it warns and fails. Meanwhile order-0 allocations were still nominally satisfiable through direct reclaim, except swap was full so reclaim freed nothing. Every core spun in reclaim/compaction at 100% with zero forward progress, and no victim was ever selected.

The `order:4` source is 9p: every `/mnt/*` drvfs mount here is `msize=65536`, so each RPC (`p9_fcall_init`) needs a 64 KiB contiguous `kmalloc`. Under fragmentation **`/mnt/c` access is always the first thing to fail** — in this incident a `zsh` `getdents64` and an Xwayland readahead. That is the blast surface, not the cause; do not go debugging drvfs.

The consumers were the usual standing set, from the guard's own high-water snapshot: `next-server` 11.2 Gi + 5.1 Gi, `tsgo` 5.0 Gi, two leaked `chrome-devtools-mcp` at 3.9 Gi each (against the 150 Mi/instance baseline recorded below — a 26x regression worth chasing separately), plus ~3.9 Gi across ten `claude` sessions.

**What the guard got wrong here, and what changed.** The protection set was working correctly — `renormalize` was still sweeping at `15:21:19`, so every fat process was an eligible victim at `oom_score_adj=0`. The killer just never ran. The real gap was visibility: the guard crossed its high-water mark at 09:48, again at 11:25, and then **stayed above it for four hours with no further signal**, because the high-water log line is edge-latched and lives in a file nobody reads. Two additions close that:

#### The `M·` badge

`wezterm-oom-record` now publishes `state/oom-guard/status.json` next to the disk guard's, and [`wezterm-x/lua/mem_status.lua`](../wezterm-x/lua/mem_status.lua) renders it in right-status after `D·`:

```
(absent)   both axes below warn
M·88%      memory used, at/above warn (amber)
S·95%      swap used, when swap is the worse axis
M·94%      at/above crit (red — earlyoom is close to picking a victim)
M·?        the recorder was publishing and went stale
```

Same "nothing while healthy" contract as `D·`: presence is the signal, and never having published renders nothing at all so a machine without the guard keeps a clean bar.

**It reports whichever axis is worse, and that is the point.** Through the whole 2026-07-26 run-up memory read a calm 88% while swap drained from 20% free to zero. A memory-only badge would have been accurate and useless. Thresholds: warn at 85% memory (same number as the high-water mark, so the bar and the log agree) or 70% swap; crit at 93% / 90%.

Publishing is on level change plus a 30 s heartbeat, not every 10 s tick — the status file is on the Windows side of the 9p boundary and belongs nowhere near a hot path (see [`performance.md`](./performance.md)).

**The status-file path is resolved at install time and baked into the unit** as `Environment=WEZTERM_OOM_STATUS_FILE=`. The recorder is a *system* unit running as root, where `$HOME` is `/root` (so the per-user Windows-path cache is invisible) and a systemd unit has no Windows interop — it cannot resolve the path itself at runtime. The installer resolves it as `$SUDO_USER` instead. If resolution fails the guard still protects and logs; only the badge goes missing. `install-wsl-oom-guard.sh --check` prints both the path it *would* bake and the one the installed unit actually carries, because a guard that protects but never publishes looks healthy from every other angle:

```
badge path    : /mnt/c/Users/<you>/AppData/Local/wezterm-runtime/state/oom-guard/status.json
unit carries  : <none>          <- reinstall needed
```

#### earlyoom as the airbag

```bash
sudo ./scripts/dev/install-earlyoom.sh            # install + configure + start
./scripts/dev/install-earlyoom.sh --check         # no root, no writes
./scripts/dev/install-earlyoom.sh --print         # dump the generated drop-in
sudo ./scripts/dev/install-earlyoom.sh --uninstall
journalctl -u earlyoom                            # kills and hourly reports
```

Config is `-m 15,10 -s 12,6`: SIGTERM once available memory is under 15% **and** free swap under 12%, SIGKILL at 10% / 6%.

**Swap is the gate on this host, not memory** — for *this* failure mode. 2026-07-27 later showed a shape where swap stayed at 62% free and the VM died anyway, so read this claim as scoped to the livelock, not as the host's one true axis; see [the third failure mode](#the-third-failure-mode-a-high-order-allocation-failure-takes-the-vm-down). This box legitimately runs at 85-88% memory (12-15% available) for hours, so a memory threshold tight enough to mean anything would fire constantly. Free swap is the axis that separates "busy" from "about to die" — near 100% free in normal work, collapsing only on the way into the livelock. The AND still holds it back from deploying during normal driving. Sized against three measured points:

| Sample | mem avail | swap free | Verdict |
|---|---|---|---|
| 2026-07-26 09:48 | 11.9% | 20.0% | silent — swap healthy |
| 2026-07-26 11:25 | 11.6% | 6.6% | **fires** — early (that state ran four more hours), and the victim is the leaked 11 Gi `next-server`, which is correct |
| 2026-07-27 14:48 | 14.0% | 10.5% | **fires** — the distro died at 14:52 |

Expect it to kill a leaked dev server rather than never fire; that is the intended trade. `WEZTERM_EARLYOOM_SWAP` raises the gate if it proves too eager.

Four things make it compose with the existing guard rather than duplicate it:

- **It picks its victim by `/proc/<pid>/oom_score`, which folds in `oom_score_adj`.** The guard's `-1000` on WSL init and `-800` on tmux already steer earlyoom away from them for free — and the guard's renormalize sweep is precisely what keeps the fat processes eligible. `--avoid ^(init|systemd|sshd|tmux|wezterm|Xwayland|dbus)` is a second layer for units living *outside* `init.scope`, beyond the sweep's reach.
- **Config goes in a systemd drop-in**, `/etc/systemd/system/earlyoom.service.d/wezdeck.conf`, not the packaged `/etc/default/earlyoom` — that file is a dpkg conffile and editing it makes every upgrade prompt. The drop-in also applies the man page's `-p` equivalent (`OOMScoreAdjust=-100`, `Nice=-20`), which cannot work through the packaged unit.
- **The drop-in must override `ExecStart=`, not `EARLYOOM_ARGS`.** The packaged unit's `EnvironmentFile=-/etc/default/earlyoom` **wins over** a drop-in `Environment=`, so an args-by-variable drop-in applies silently and does nothing. Cost of learning this the hard way: earlyoom ran for a day on the package defaults (`-m 10 -s 10`) while every config file on disk said otherwise. An empty `ExecStart=` resets the list before the real one.
- **The `--avoid` regex must contain no spaces and no quotes.** systemd splits a command line without shell quote processing, so the packaged config's own `--avoid '(^|/)(init|X|sshd|firefox)$'` example would arrive as two broken arguments. `^tmux` still matches comm `tmux: server`.

**Verify against the daemon, never against the config.** earlyoom prints its parsed thresholds on startup, and that banner is the only trustworthy source — `systemctl show` reports the unit file, not the live process. `install-earlyoom.sh --check` prints installed / intended / actually-parsed side by side for exactly this reason, and the installer runs `earlyoom --dryrun` (no privilege needed) before writing, so a bad argument string fails at install time instead of during the next incident:

```
installed args: -r 3600 -m 15,10 -s 12,6 --avoid ^(init|systemd|…)
would install : -r 3600 -m 15,10 -s 12,6 --avoid ^(init|systemd|…)
daemon parsed :
  sending SIGTERM when mem <= 15.00% and swap <= 12.00%,
          SIGKILL when mem <= 10.00% and swap <=  6.00%
```

**`enable --now` is not enough on a reinstall.** It is a no-op against an already-running unit, so the old process keeps the old environment while every file on disk shows the new one. On 2026-07-27 the badge path was correctly baked into `wezterm-oom-record.service` and the running recorder never saw it — it logged an empty status path and published nothing, while `systemctl show` cheerfully reported the new value. Both installers now `systemctl restart` explicitly.

**Why not `systemd-oomd`.** Its unit of destruction is a *cgroup*, and on this host 109 processes — tmux, every agent, every dev server — live in the single `/init.scope` cgroup (which is why the OOM guard watches exactly that cgroup). oomd would either not manage `init.scope` at all or take out the whole thing, reproducing the 2026-07-25 poweroff/restart loop. It is also not installed here (`/usr/lib/systemd/systemd-oomd` absent), so there is no "already in the box" advantage, and `/proc/pressure/memory` currently reads `total=0` on this kernel while cpu and io both count — worth pressure-testing before ever relying on memory PSI in WSL. earlyoom kills one process and needs none of that.

### The third failure mode: a high-order allocation failure takes the VM down

Reference incident 2026-07-27, twice in one afternoon (VM up at 14:52, dead at 18:20). Same family again — the guest is short on memory — and a **third** presentation: no process was killed, no restart loop, no livelock long enough to notice, and **swap was healthy**. The distro just stopped, and Windows restarted the whole VM.

**Judging it:** `dmesg` timestamps reset to `[0.000000]`, so per the rule above this is a VM reboot, not a distro restart. Then look for this, and nothing else is needed:

```
18:19:13 kworker/0:1: page allocation failure: order:7, mode:0xdc0(GFP_KERNEL|__GFP_ZERO)
           __alloc_pages_slowpath → vmbus_alloc_ring → vmbus_open → hvs_probe → vmbus_probe
18:19:13 Node 0 Normal: … 0*512kB 0*1024kB 1*2048kB      <- orders 7 and 8 gone
18:19:45 WSL (SessionLeader) ERROR: UtilAcceptVsock:273: accept4 failed 110    <- ETIMEDOUT
18:20:30 WSL (Relay)         ERROR: UtilAcceptVsock:246: Waiting for abnormally long accept(11)
18:20:42 <last log line of the instance>
```

Read it as a chain, not as three separate errors:

1. **A new hyperv-vsock channel needs `order:7` — 512 KiB contiguous — for its ring buffer** (`vmbus_alloc_ring`). Total free memory is not the constraint; *contiguity* is. Both incidents failed with several GB nominally free.
2. **Losing a vsock channel is fatal in a way losing a process is not.** vsock is how the Windows side and the guest talk, so the relay's `accept4` times out (`110`), `wsl.exe` concludes the distro is unreachable, and the VM is torn down. The `UtilAcceptVsock` errors are the blast surface, not the cause — do not go debugging WSL networking.
3. **Nothing in the guest dies, so there is nothing to find afterwards.** `oom_kill` stays 0 and no `Killed process` line is ever written. "No OOM record" rules out even less than it did after 2026-07-26.

The consumers were the standing set again, from the guard's own high-water snapshots: `next-server` at 17.0 Gi before the 14:52 death and 13.4 Gi before the 18:20 one, four `chrome-devtools` at ~2.9-4.0 Gi, `tsgo` ~2.6 Gi.

**Why all three existing layers were silent.** This is the useful part of the incident:

| Layer | Why it did nothing |
|---|---|
| kernel OOM killer | `order:7` is above `PAGE_ALLOC_COSTLY_ORDER` (3). The kernel warns and fails; it never selects a victim. Same mechanism as the 2026-07-26 `order:4`. |
| `M·` badge | Correct and already red — `crit` at 18:19:11 (mem 94%). A number on the bar is not an action, and there were 91 seconds left. |
| earlyoom | **The AND gate never armed.** At 18:20:36 memory was 95% used but swap was only 38% used — 62% free, nowhere near the 12%-free trigger. |

So the previous section's conclusion — *"swap is the gate on this host, not memory"* — is **too strong**, and the table above it dates from before this incident. Free swap predicted the 2026-07-26 livelock well and predicts this shape not at all: high-order contiguity can collapse while both percentages still read survivable. That table's `2026-07-27 14:48` row is also an after-the-fact threshold calculation, not an observation — `journalctl -b -2` contains no earlyoom lines at all, because it was still being installed that afternoon. The only *observed* verdict for earlyoom on this failure mode is the 18:20 one: silent.

#### The fragmentation axis in `wezterm-oom-record`

The guard therefore watches contiguity directly, and handles it **in the system layer** rather than by capping each consumer — one place to reason about, and no per-project memory flags to keep in sync. Two triggers:

- **Confirmed:** a new `page allocation failure: order:>=4` appears in the kernel log. No memory gate — the kernel has already refused an allocation, whatever the percentages say. This is the trigger with real lead time: the first `order:7` failure landed at 14:02 and the VM survived until 14:52.
- **Predictive:** free blocks at `order>=7` hit zero **and** memory is already past the high-water mark. The AND is load-bearing: high-order exhaustion alone is the ordinary steady state of a long-lived Linux box, and acting on it unqualified would mean compacting and eventually killing on a perfectly healthy host.

Then it escalates, stopping at the first step that produces a usable block:

1. `snapshot` — the durable record of who was big, which neither incident left behind.
2. `echo 1 > /proc/sys/vm/compact_memory`, then re-read `/proc/buddyinfo` a beat later. Lossless, and aimed at exactly what failed. If this restores a block, nothing is signalled and the log says so.
3. Only if compaction cannot produce a single block: `SIGTERM` the largest consumer, `SIGKILL` if the same PID survives to the next attempt (a process wedged in reclaim never services `SIGTERM`). Floor of 2048 MiB and earlyoom's own `--avoid` list, so the victim is a cause and never a bystander — an agent CLI at ~400 Mi is not why a 512 KiB allocation failed.

**This is the airbag earlyoom's swap gate withholds**, deliberately placed last. The cost of step 3 is one dev server; the cost of not having it is every pane in the VM. One relief attempt per `WEZTERM_OOM_FRAG_COOLDOWN` (120 s default) keeps a sustained shortage from becoming a killing spree.

```bash
scripts/runtime/wsl-oom-guard.sh status     # fragmentation + alloc-failure lines
journalctl -u wezterm-oom-record | grep frag:
```

```
fragmentation : order>=7 free blocks=4483 (acts below 1, mem gate 85%) action=compact+term
alloc failures: 0 high-order (order>=4) failure(s) in this VM's kernel log
```

A non-zero `alloc failures` count means this VM has *already* been where both reboots started, whether or not the guard was watching at the time — `watch` logs that baseline on startup for the same reason it logs a non-zero `oom_kill`.

Notes:

- **`frag_order`, `frag_free_blocks`, `frag_min_blocks` and `alloc_failures` are published in `status.json`, but the badge level is unchanged** — it still comes from the two percentage axes only, so `mem_status.lua` needs no update. The fields are there for diagnosis and for a future axis on the bar; the incident's badge was already red, so a fourth colour would have added nothing.
- **The buddy column count is derived from the line, not fixed at 11.** `MAX_ORDER` changed meaning in 6.4 and `/proc/buddyinfo`'s width follows the kernel.
- **The kernel-log count is a count, not a watermark** (same shape as `read_oom_kill`): the guard acts only when it grows and re-baselines on any change, so the wrapping `dmesg` ring buffer degrades to "missed one" instead of a stuck alarm. The predictive trigger is the backstop for exactly that.
- Env knobs: `WEZTERM_OOM_FRAG_ORDER` (7), `WEZTERM_OOM_FRAG_MIN_BLOCKS` (1), `WEZTERM_OOM_FRAG_MEM_PCT` (high-water mark), `WEZTERM_OOM_FRAG_ACTION` (`compact+term`; also `compact` to hand the kill back to earlyoom, or `off`), `WEZTERM_OOM_FRAG_COOLDOWN` (120), `WEZTERM_OOM_FRAG_MIN_RSS_MIB` (2048), `WEZTERM_OOM_FRAG_AVOID`, `WEZTERM_OOM_BUDDYINFO`, `WEZTERM_OOM_COMPACT_FILE`, `WEZTERM_OOM_KMSG_FILE` (test hook). `WEZTERM_OOM_DRY_RUN=1` reports and snapshots without compacting or signalling.
- **Compaction and signalling need root**; the recorder is a system unit, so this works there and degrades to a logged warning under an interactive `watch`.
- Regression tests: `tests/hook-units/test_wsl_oom_guard.sh` pins the escalation order, the memory gate, the RSS floor, the avoid list, the cooldown, and `SIGTERM`→`SIGKILL`, driving the real `watch` loop against fixtures (fake `/proc/buddyinfo`, fake kernel log, a FIFO standing in for `compact_memory` so "compaction helped" is deterministic rather than timing-dependent).

**After changing this script, restart the recorder** — the unit runs the file straight out of the repo, so an edit alone changes nothing in the live process:

```bash
sudo systemctl restart wezterm-oom-record
journalctl -u wezterm-oom-record -n 5 | grep 'frag axis'   # must name the new axis
```

### Standing memory consumers

The guard tells you who died; this section records what is *always* resident, so a snapshot can be read against a known baseline. Measured 2026-07-25 via `/proc/<pid>/status` `VmHWM` (per-process peak RSS) — the top-of-`ps` view understates long-lived processes that have since shrunk.

| Family | Peak sum | Processes | Note |
|---|---|---|---|
| `chrome-devtools-mcp` | 5.91 Gi | 44 | one full stack **per agent session**; see below |
| `claude` | 4.60 Gi | 11 | parallel agent sessions |
| `vscode-server` | 1.24 Gi | 10 | one server per distro, shared across windows; each extra window adds an extension host |
| `tsgo` (`--lsp --stdio`) | 4.27 Gi | 2–3 | ⚠️ corrected 2026-08-04 (`VmHWM` 4.19 Gi + 76 Mi; current RSS 3.94 Gi). The 2026-07-25 reading was **17 Mi / 1 process**, with the note "not a memory concern — it is Go, no V8 heap". That was a small-repo measurement and does not generalise: one server per workspace folder, and in a large monorepo a single one is a top-three consumer. See [tsgo and `goMemLimit`](#tsgo-and-gomemlimit) |

Two findings worth keeping:

- **No Chrome runs inside WSL.** The browser is the Windows-side headless debug instance (see [`browser-debug.md`](./browser-debug.md)); every WSL-side `chrome-devtools-mcp` process is Node.js attached over `--browser-url=http://127.0.0.1:9222`. Do not go looking for renderer processes here.
- **It was pure standby cost.** Those processes showed **0 seconds of CPU time** after 43 minutes of uptime, and peak RSS within ~10% of current — they were never exercised. The cost was paid whether or not any browser tool was ever called.

Applied 2026-07-25 — MCP config is user-global (`~/.claude.json`, managed with `claude mcp add/remove -s user`), so this is a record of the decision, not repo-owned config:

1. **Dropped the `npx` wrapper.** `npx chrome-devtools-mcp@latest` leaves npm-cli resident (~85 Mi) for the whole session just to act as a launcher, and re-resolves `@latest` on every start. `npm i -g chrome-devtools-mcp@<version>` plus a bare `command: chrome-devtools-mcp` removes that layer. Both spawners already have the fnm global bin dir on `PATH` — Claude Code's server entry sets `env.PATH` explicitly, and the OpenClaw gateway's `Environment=PATH=` is pinned in its systemd user unit — so no absolute path is needed, and the config stays copy-pasteable across machines.

   **The prerequisite that actually breaks:** `npm config get prefix` is scoped to the *current default* node version (`…/node-versions/v22.23.1/installation` here), and `aliases/default` is a symlink to it. After a `fnm default <other-version>`, the alias retargets and the binary is simply gone from `PATH` — re-run `npm i -g chrome-devtools-mcp@<version>` under the new default and re-verify with `claude mcp get chrome-devtools` / `openclaw mcp probe chrome-devtools`. An absolute path does **not** protect against this; it fails the same way with a less obvious error. Also note the path `command -v` prints right after `npm i -g` is an ephemeral `/run/user/<uid>/fnm_multishells/…` one — never put that in config.
2. **Disabled usage statistics.** `--usageStatistics=false` (or `CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1`) removes a `telemetry/watchdog/main.js` child — a second full Node runtime, ~135 Mi, one per instance. Grepping `process.env.[A-Z_]+` in `build/src` does **not** surface that variable; read `chrome-devtools-mcp --help` instead.

Verified result: **4 processes / ~357 Mi per instance → 1 process / 150 Mi**, zero children, zero watchdog. Across ~12 concurrent sessions that is ~4.3 Gi → ~1.8 Gi.

**There are two independent MCP configs on this host, and they are deliberately no longer symmetric.** `claude mcp … -s user` only touches Claude Code (`~/.claude.json`). The OpenClaw gateway keeps its own at `~/.openclaw/openclaw.json` → `mcp.servers.chrome-devtools`, managed with `openclaw mcp add/configure/probe/reload`, and it runs **outside tmux** — so neither a Claude-side config change nor a `tmux kill-server` reaches it. Both were put on the global-binary + `--usageStatistics=false` form; the OpenClaw side is documented in [`openclaw/README.md`](../openclaw/README.md) "Chrome DevTools MCP" with the operator recipe mirrored in `openclaw/workspace/skills/chrome-devtools/SKILL.md`. After editing, `openclaw mcp reload` disposes cached runtimes so the next turn rebuilds on the new config.

As of 2026-07-29 the Claude Code side is off resident MCP entirely (see below), while **OpenClaw deliberately keeps it**. The asymmetry is intentional, because the numbers and the costs differ on each side:

| | Claude Code | OpenClaw gateway |
|---|---|---|
| instances | one **per session** — 16 observed | gateway-level, but **not always exactly one** — a steady 2 concurrent on 2026-08-04 (141 Mi each). Lazy-spawn/release still holds: both observed PIDs exited within the hour and were replaced by a fresh pair, so read this as "a churning pair", not "a leak" |
| observed peak | 3.4 Gi (5 instances ≥1.7 Gi) | 138 Mi |
| lifetime | resident for the whole session | lazy-spawned, released again (observed at 0 processes with the server still configured) |
| cost of switching to `uxc` | tool schemas leave the prompt, calls go through Bash | every browser step additionally passes the `claw-run` / `exec-risk` shell gate, and code-mode `MCP.chromeDevtools.*` stops working |

So the leak that justified rebuilding the Claude Code path does not reproduce here: there is no 16× standby multiplier, the observed peak is ~25× smaller, and the runtime does get released. Paying a shell-risk gate on every "look at the page" would be a real regression in the path Dex uses daily.

**Revisit that decision if** a gateway-owned `chrome-devtools-mcp` process is seen holding more than ~1 Gi, or surviving across many turns without being released. The cheap fix at that point is not a rewrite — it is `openclaw mcp reload`, which disposes the cached runtime and lets the next turn rebuild it; that can be driven on a threshold rather than switching Dex to a CLI. Check with:

```bash
# gateway MainPID, then MCP children hanging off it
systemctl --user show openclaw-gateway.service -p MainPID --value
pgrep -f chrome-devtools-mcp   # -f is required: comm truncates to "chrome-devtools"
```

Note `openclaw mcp configure` exposes auth/timeout/TLS/tool-filter knobs but **no idle or TTL control**, so there is no config-only way to cap the growth — hence the threshold-plus-`reload` shape above. Also note `openclaw mcp probe` connects from the CLI process, not from the gateway, so it cannot be used to observe gateway runtime lifetime.

Related: a killed instance can **orphan** its `telemetry/watchdog` child (observed while testing), so it lingers holding ~135 Mi. Reap only the orphans — never a bare `pkill -f telemetry/watchdog`, which would also kill live sessions' watchdogs:

```bash
for p in $(pgrep -f "telemetry/watchdog"); do
  pp=$(tr '\0' '\n' </proc/$p/cmdline | grep -oP '(?<=--parent-pid=)\d+')
  [ -n "$pp" ] && [ ! -d "/proc/$pp" ] && kill "$p"
done
``` Other useful flags in the same `--help`: `--slim` (3 tools only, cuts tool-schema context), `--performanceCrux=false` (stops sending trace URLs to the Google CrUX API), `--experimentalPageIdRouting` (page-ID routing for concurrent sessions).

#### The standby figure is a floor, not a ceiling — the heap grows without bound

The `150 Mi per instance` above is the **never-exercised** cost. An instance that actually drives a page grows monotonically and never gives the memory back. Measured 2026-07-29 across 16 concurrent sessions, the split is bimodal:

| Class | Count | Footprint |
|---|---|---|
| never called a browser tool | 11 | ~80 Mi each (RSS 1 Mi + 79 Mi swap — fully paged out) |
| actually drove a page | 5 | **1.7–3.5 Gi each** (13 h → 1.7 Gi, 23.5 h → 3.48 Gi, 37.6 h → 3.35 Gi) |

`smaps_rollup` shows `Rss ≈ Pss ≈ Anonymous ≈ Private_Dirty` (cross-process double-counting only 0.20%), i.e. pure anonymous private heap with nothing reclaimable. Those 5 held **77% of the guest's entire `AnonPages`** (14.91 of 19.32 Gi) and were the reason swap sat at 99% with only 21 MiB free while `MemFree` still showed 21 Gi — physical memory looked fine because the pressure had already been paid into swap and never came back.

**Root cause is in `build/src/PageCollector.js`**, and it is not subtle:

```js
maxNavigationSaved = 3;
storage = [[]];
listeners(value => { …; this.storage[0].push(withId); });          // no size cap
listenerMap['framenavigated'] = frame => { …; this.splitAfterNavigation(); };
splitAfterNavigation() { this.storage.unshift([]); this.storage.splice(3); }
```

Retention is "last 3 navigations", but **a single navigation bucket has no item limit**, and trimming only fires on main-frame `framenavigated`. An SPA routing via `history.pushState` never triggers it; a page left open never triggers it. So `storage[0]` grows forever. What accumulates are puppeteer `HTTPRequest` objects — each holding response/body plus back-references to frame, page, and CDP session — so a single retained entry pins a long chain. **Next.js dev server + HMR + a page left open is the worst case**, and it is exactly what the 5 bloated instances were pointed at.

Two consequences for operators:

- **`--slim` and `--no-category-network` do not help memory.** They gate tool *registration* only (`tools.js` / `ToolHandler.js`); `McpPage.js` constructs `new NetworkCollector` / `new ConsoleCollector` unconditionally in its constructor. They remain useful for cutting tool-schema context — just not for this. The only size cap anywhere in the package is `telemetry/watchdog/ClearcutSender.js`'s `MAX_BUFFER_SIZE = 1000`, which is the one component already disabled above.
- **Upgrading does not help.** 1.6.0 (2026-07-14) is the latest release. Upstream [issue #1192](https://github.com/ChromeDevTools/chrome-devtools-mcp/issues/1192) (`p1`, `confirmed`, closed) reports the same disease from the `--autoConnect` side — ~13 MB/min, 1.66 Gi in 10 h, swap exhaustion triggering a macOS kernel watchdog panic. The v0.20.3 fix (#1200, "release old navigation request in NetworkCollector") only addressed releasing *across* navigations, not the unbounded single bucket.

A cheap habitual mitigation: **reload the page when done debugging**. That fires `framenavigated` and trims to the last 3 navigations.

#### Containment: run it through uxc instead of holding a resident connection

Applied 2026-07-29 (was previously deferred here). Drive the MCP through [`uxc`](https://github.com/holon-run/uxc) so the process is reclaimed when idle instead of living for the session's lifetime.

```bash
A=/home/yuns/.local/share/fnm/aliases/default
uxc link chrome-devtools-mcp-cli \
  "$A/bin/node $A/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js --browser-url=http://127.0.0.1:9222 --usageStatistics=false"
```

**Absolute `node` + absolute `.js` is required**, not the `chrome-devtools-mcp` shim: it is a `#!/usr/bin/env node` symlink and the daemon's child environment has no `node` on `PATH` (`env -i` reproduces the failure). Routing both through `aliases/default` avoids hard-coding the node version, though the `fnm default` caveat above still applies.

The agent-facing side is upstream's own wrapper skill, installed **unmodified** from `holon-run/uxc` → `skills/chrome-devtools-mcp-skill` (MIT) into the shared pool at `~/.agents/skills/`, symlinked into `~/.claude/skills/` like `context7-mcp-skill`. Do not fork it: its `scripts/validate.sh` requires the documentation to quote upstream's own endpoint strings verbatim, so a locally-edited copy cannot pass upstream validation.

That works despite upstream prescribing a host this machine rejects — `npx -y chrome-devtools-mcp@latest --autoConnect --no-usage-statistics`, which would reintroduce the resident npm-cli launcher and cannot work at all here (`--autoConnect` looks for a local Chrome user-data-dir, and there is no Chrome inside WSL). The Link-First flow checks `command -v chrome-devtools-mcp-cli` **before** creating anything, so the pre-seeded absolute-path link above wins and upstream's `uxc link` line never runs. Upstream's naming would call this variant `chrome-devtools-mcp-port`; locally `-cli` *is* the browserUrl form, because it is the only form that works.

⚠️ The failure mode to watch: on a machine where the link is missing, an agent will follow upstream's text and create the `npx` form — functional but with the launcher overhead back. Re-create it with the absolute-path command above instead. Running upstream's `validate.sh` needs `ripgrep`, which is not installed here.

Verified on this host:

- **All 29 operations exposed**, covering 100% of the 18 previously whitelisted ones.
- **Stateful continuity holds across separate CLI invocations.** `take_snapshot` → `uid=3_0` in one process, `click uid=3_0` in the next, `evaluate_script` reading back `CLICKED` in a third — same `child_pid` throughout, `mcp_reuse_hits` incrementing. Sessions key on `stdio:{endpoint}:{auth_fingerprint}`; `cleanup_idle` uses non-blocking `try_lock` specifically so it cannot interrupt an in-flight call.
- **Arguments must be passed `key=value`.** The skill docs' "bare JSON positional payload" form fails against MCP tools (`Invalid value at $.function`), and `--input-json` takes inline JSON only, not a file path. Use backticks inside JS to dodge shell quoting.

⚠️ **uxc's idle reaping is lazy — it needs external traffic to fire.** `MCP_IDLE_TTL_SECS` is 600, but `cleanup_idle` only runs immediately before the daemon handles a request; there is no timer. Measured: a child sat at `idle_for_secs=820`, `expires_in_secs=0`, 701 Mi resident for 750 s untouched, then died instantly when one unrelated endpoint call (`deepwiki-mcp-cli -h`) came in. Any endpoint counts, not just this one — but a quiet stretch leaves expired children resident.

`scripts/runtime/uxc-session-reaper.sh` supplies the missing trigger, on cron every 5 minutes (see `wezterm-x/local.example/crontab`). Confirmed working unattended on 2026-07-29: a session left behind by another agent had grown to ~1.4 Gi, expired, and was reclaimed by the `13:55:01` cron tick — identifiable because its `trace_id` (`20260729T135501-…`) belongs to the cron run rather than to any interactive session. It takes its verdict from uxc's own `expires_in_secs == 0` rather than guessing an RSS threshold, acts only when *every* session is expired so an in-flight workflow is never cut, and calls `uxc daemon stop` rather than signalling `child_pid` behind the daemon's back. Triage entry point:

```bash
uxc daemon sessions   # child_pid, idle_for_secs, expires_in_secs, reuse_eligible
uxc daemon status     # mcp_stdio_sessions, mcp_reuse_hits
scripts/runtime/uxc-session-reaper.sh          # dry-run
```

`UXC_DAEMON_IDLE_TTL=<secs>` overrides the TTL for a daemon (`0` disables reaping entirely — do **not** use it here, that reinstates the unbounded growth); `uxc link --daemon-idle-ttl` pins it per link.

Residual costs, unchanged from the earlier assessment: ~0.5–1 s per call (970 ms cold, 518 ms warm), and the model composes a CLI line instead of seeing tool schemas directly. The side benefit is context, not just memory — a resident MCP injects all 29 tool schemas into every session.

**Permission note:** never grant `Bash(uxc:*)`. `uxc` is a general-purpose invoker (`uxc <any endpoint> <any operation>`, plus `uxc auth` over stored credentials), so a broad prefix rule is a real privilege escalation. Keep grants bound to the linked command name, which has the endpoint baked in.

**Idle does not mean quiescent.** With pages still open, the heap keeps growing even when no tool is called: one session went 778 → 1187 Mi across 40 minutes of `idle_for_secs`, because the CDP connection is still delivering events into the collectors. The earlier 750 s observation that showed RSS *falling* (782 → 700 Mi) was measured with the test page closed, i.e. with nothing arriving — do not generalise from it. So the 600 s TTL is an upper bound on damage, not a plateau; if a session routinely accumulates hundreds of MiB before expiring, shorten it via `uxc link --daemon-idle-ttl`.

⚠️ **The reaper needs `XDG_RUNTIME_DIR` exported, not just derived.** cron does not set it, and uxc then resolves its socket to `/tmp/uxc-unknown/daemon/uxc.sock` instead of `/run/user/<uid>/uxc/uxc.sock`. A first cut of the script derived the path locally without exporting it, so the socket check passed while `uxc daemon sessions` failed to connect — and because the verdict only looked at `.data`, the error envelope degraded into "no sessions" and every cron run silently reaped nothing for 40 minutes. When triaging a reaper that appears to do nothing, check `syslog` for the `CRON … CMD` line first (it will be there), then run it under `env -i` with cron's environment; a healthy run logs `reaped expired uxc daemon sessions` with `child_pids`.

### tsgo and `goMemLimit`

`tsgo` is the TypeScript native language server shipped by the `typescriptteam.native-preview` VS Code extension, enabled here via `typescript.experimental.useTsgo`. It replaces the Node `tsserver`, so `typescript.tsserver.maxTsServerMemory` (which becomes `--max-old-space-size`) has **no effect on it at all** — being Go, the only limit it honours is `GOMEMLIMIT`, which the extension sets from `js/ts.server.goMemLimit`.

**What it is actually serving here.** Read this table with one rule in mind, because it is the trap: **a `handled method` line does not mean the feature is on.** VS Code's clients keep issuing requests on their own schedule regardless of config, and a disabled feature answers empty in microseconds. So capability has to be judged from the config dump (authoritative) with latency as the cross-check — not from request counts. Tabulated from 13 491 `handled method` lines across the three newest logs, against the config tsgo reports receiving:

| state | methods | evidence |
|---|---|---|
| **on — real work** | `semanticTokens/full`, `/range` | the most expensive steady-state call at p50 28 ms — but see the note on latency sums below before calling it "the cost" |
| **on — parse-level, cheap** | `documentSymbol`, `foldingRange` | syntactic, sub-ms by nature |
| **on — navigation** | `definition`, `hover`, `documentHighlight` | `hover:map[maximumLength:500]`; sub-ms |
| **on — basic completion** | (not observed in logs) | `suggest:map[… enabled:true]`, but `autoImports:false`, `includeCompletionsForImportStatements:false`, `completeFunctionCalls:false` |
| **off — answers empty** | `textDocument/diagnostic` | `validate:map[… enabled:false]`; 9 631 calls (71 % of traffic) yet 97.7 % under 5 ms, p50 0.23 ms |
| **off — answers empty** | `textDocument/inlayHint` | every sub-key `false`/`none`; 70 calls, p50 0.18 ms |
| **off — answers empty** | `textDocument/codeLens` | `implementationsCodeLens.enabled:false`, `referencesCodeLens.enabled:false`; 34 calls, p50 0.70 ms |
| **off / near-empty** | `textDocument/codeAction` | `suggestionActions:map[enabled:false]`, and quick fixes derive from diagnostics which are off; p50 0.23 ms |
| infrastructure | `workspace/didChangeWatchedFiles` | 3 546 calls |

So what the tuning block actually leaves is **parse-level features plus navigation** — jump-to-definition, hover, outline, folding — plus semantic highlighting.

⚠️ **Do not rank costs by summing `handled method` durations.** Those are wall-clock latencies, and during a project load every queued request inherits the wait, so the sums point at whatever happened to be in flight at startup. Summed over four older logs they read `diagnostic` 99.6 s / 48 %, `semanticTokens/full` 46.7 s, `documentSymbol` 27.0 s — all misleading. The internal control that proves it: **`inlayHint` is disabled and still accumulated 13.3 s**, which a switched-off feature cannot spend working. Confirmed on the clean post-reload log: of 131 calls, exactly 2 exceeded 500 ms (`initialized` 0.64 s and `didOpen` 4.67 s, both inside the 5-second startup window) and everything after was sub-millisecond.

So the steady-state per-request cost of this configuration is negligible. **The real cost is the ~2.9 Gi standing heap plus the one-off project load** — and neither shrinks by disabling features, because the heap *is* the program and type graph that jump-to-definition itself depends on.

**Do not over-read that table as "only highlighting and navigation survive".** The binary implements a full language service — `strings … | grep -oE 'textDocument/[a-zA-Z]+'` lists `completion`, `references`, `rename`, `prepareRename`, `implementation`, `typeDefinition`, `declaration`, `signatureHelp`, `prepareCallHierarchy`, `prepareTypeHierarchy`, `selectionRange`, `linkedEditingRange`, `documentLink`, `inlineCompletion`, plus `workspace/symbol` — and **this configuration disables none of them**. The methods absent from the log table were simply not invoked during the sampled window; absence there is not evidence of a disabled capability.

Measured against VS Code's *defaults*, the tuning turns off exactly four feature groups: **type diagnostics** (no red squiggles — type errors must come from a separate `tsc --noEmit` run or CI, which is an implicit dependency of this configuration), **auto-import completions** (the rest of completion still works), **formatting** (delegated to prettier) and **automatic type acquisition**.

`inlayHints` and both `codeLens` kinds show as disabled in the config dump but are **not** part of this tuning — VS Code ships them off by default (`inlayHints.*` default `false`/`none`, `implementationsCodeLens.enabled` and `referencesCodeLens.enabled` default `false`). Crediting them to the tuning block overstates what it does.

#### Which keys actually do something

The authoritative check is not the settings schema and not observed behaviour — it is the `config:"…"` struct tags compiled into the `tsgo` binary, which are exactly the keys the server reads (72 of them):

```bash
strings -n 6 ~/.vscode-server/extensions/typescriptteam.native-preview-*/lib/tsgo \
  | grep -oE 'config:"[^"]+"' | sed 's/config:"//;s/"$//' | tr ',' '\n' | sort -u
```

That audit cut `~/.vscode-server/data/Machine/settings.json` from 17 keys to 12. The 12 that remain, all confirmed to be keys something actually reads:

| key | role |
|---|---|
| `js/ts.server.goMemLimit` | Go heap ceiling → `GOMEMLIMIT`. Read by the **extension**, not tsgo; verified in `/proc/<pid>/environ` |
| `typescript.experimental.useTsgo` | master switch; the only key the extension watches for live changes |
| `{typescript,javascript}.validate.enabled` | type diagnostics — latency confirms it stops the checking |
| `{typescript,javascript}.suggest.autoImports` | auto-import completions (effect not fully confirmed — see open question 7) |
| `…suggest.includeCompletionsForImportStatements` | import-statement completions |
| `{typescript,javascript}.format.enabled` | built-in formatter |
| `typescript.disableAutomaticTypeAcquisition` + `typescript.tsserver.automaticTypeAcquisition.enabled` | stop fetching `@types` — **both are required**, see below |

The 5 removed key names (6 entries counting the ts/js pairs) and why each was dead:

| removed | why it did nothing |
|---|---|
| `js/ts.trace.server` | no-op — gated behind the output channel's log level |
| `{typescript,javascript}.validate.enable` | tsgo's tags contain only `validate.enabled`; `.enable` is the built-in extension's key, and `useTsgo` retires that extension |
| `{typescript,javascript}.format.enable` | same — only `format.enabled` exists in the tags |
| `typescript.tsserver.nodePath` | tsgo is a Go binary; no node is involved |

**The deletion is self-verifying, which is the neat part.** After the reload, tsgo's config dump shows `validate:map[enable:true enabled:false]` and `format:map[enable:true enabled:false]` — the `.enable` halves reverted to their schema default `true` because nothing sets them any more, while the `.enabled` halves stayed `false`. Behaviour did not change, which is exactly the proof that those keys were inert. `trace:map[server:verbose]` reverted the same way, harmlessly.

⚠️ **Automatic type acquisition needs both keys set, or it silently stays on.** tsgo's tags contain `disableAutomaticTypeAcquisition` *and* the newer `tsserver.automaticTypeAcquisition.enabled`. With only the first one set, the dump showed them disagreeing — `disableAutomaticTypeAcquisition:true` alongside `automaticTypeAcquisition:map[enabled:true]`, the newer key sitting at its default because nothing set it — and which one wins is undocumented, so ATA may have been running the whole time. Both are now set and the dump agrees: `enabled:false`.

Also worth knowing: **`suggest.enabled` is *not* in tsgo's tag list**, so basic completion cannot be turned off from the server side by that key — only the auto-import parts of completion are configurable here.

**Setting that limit below the live heap converts a memory cost into a much worse CPU cost.** Measured 2026-08-04 with `goMemLimit: "3GiB"` against the `ai-video-collection` monorepo:

| | over-limit server | control |
|---|---|---|
| workspace | `ai-video-collection` | its `dev-web-cmdb` worktree |
| `GOMEMLIMIT` | 3GiB | 3GiB |
| RSS | 3.94 Gi (`VmHWM` 4.19 Gi) | 76 Mi |
| CPU used / uptime | **30 h 42 m / 21 h → 145 % sustained** | **19 s / 21 h** |

Both servers were started within 40 minutes of each other and had the same uptime, so the 5800× difference in CPU is not a warm-up artefact.

Same binary, same setting; the only difference is where the live heap sits relative to the limit. `GOMEMLIMIT` is a *soft* limit — when it cannot be met the runtime simply keeps running GC cycles that free nothing, forever.

**The failure is time-delayed, which is why it went unnoticed for so long.** A freshly restarted server on the same monorepo settles at **2.82–2.92 Gi (two cold measurements) — under the 3 GiB limit — and is quiet at 3 % of one core**. That is only **3–8 % headroom**, so ordinary use drifts the heap past the limit within hours, and once past it the server never recovers: the 3.94 Gi / 145 % state above was the *same* workspace after 21 h. In other words the old setting was borderline from cold start, not merely after growth. Two consequences:

- A limit that looks safe on a cold server can be badly wrong on a warm one. Size it against the *grown* heap, not the freshly-loaded one.
- **You cannot reproduce or refute this right after a reload.** Measured minutes after a restart, everything looks healthy no matter what the limit is. Compare against a server that has been up for hours, or wait.

The diagnostic signature is specific enough to recognise in one pass, and it is **not** the shape you would expect:

- CPU in periodic parallel bursts (~5.5 core-seconds every 4–6 s), not a smooth pin.
- **RSS flat** (3941 → 3936 Mi over 30 s) and **minor faults near zero** (0–63 per 2 s). There is no scavenge/refault sawtooth, because nothing is reclaimable.
- `smaps_rollup` shows ~99.6 % `Private_Dirty` anonymous (file-backed only 9.6 Mi), so the whole figure is Go-runtime-accounted and really is above the limit.
- `read_bytes` +0 over 30 s and the extension host idle at 2–8 %, which rules out project rescans and LSP request storms — the work is self-initiated.

Set the limit with real headroom above the live heap (`6GiB` here — 2.1× the 2.82 Gi cold working set, 1.5× the 3.94 Gi warm one) or leave it unset. Unset is not free either: with the Go default `GOGC=100` the heap grows toward 2× live (≈7.8 Gi), which is what the limit was originally added to prevent — so a limit with headroom beats both.

⚠️ **Changing `goMemLimit` requires `Developer: Reload Window`. Nothing cheaper works.** The env is built once, inside the extension's `start()`. Verified against `native-preview` `0.20260707.2`:

- Killing `tsgo` gets it respawned by the LanguageClient's own crash-restart, which reuses the captured `ServerOptions.env` — done twice here, both times the new process still had `GOMEMLIMIT=3GiB`.
- The extension's own **`TypeScript Native Preview: Restart`** command is no better: `tryRestart()` only falls through to `restartSession()` → `start()` when the resolved tsgo **binary path changed**; an unchanged path takes `client.restart()`, which also reuses the captured env.

Check which value a live server actually got — the env is authoritative, the settings file is not:

```bash
pgrep -f 'lib/tsgo --lsp' | while read p; do
  echo "$p $(tr '\0' '\n' < /proc/$p/environ | grep '^GOMEMLIMIT=') $(readlink /proc/$p/cwd)"
done
grep -h 'Setting GOMEMLIMIT' ~/.vscode-server/data/logs/*/exthost*/*native-preview*/*.log | tail -3
```

A reload that took effect leaves a **new** `Setting GOMEMLIMIT=` line; no new line means no re-read.

Two adjacent findings from the same pass:

- **Claude Code spawns its own `tsgo` from the same extension directory with no `GOMEMLIMIT` — and that is fine. Do not cap it.** It does not read VS Code settings, so nothing sets the env. An initial reading of this as "an uncapped multi-gigabyte heap waiting to happen" was **wrong**; measured 2026-08-04: peak RSS **3.9 Mi** across 30 minutes of sampling, instances rotate every few minutes rather than living for the session, and — decisively — the three `claude` sessions sitting in `ai-video-collection` and its worktrees had **no `tsgo` at all**, while only the session doing active work in this (non-TS) repo had one. It never performs a project-level type load, so there is nothing to cap. Note also that a cap could not break validation even if added: `GOMEMLIMIT` is soft and Go never fails an allocation over it — the risk of capping is the CPU pathology above, not failure.
- **`js/ts.trace.server: "off"` is a no-op.** `refreshTrace()` initialises trace to `Off` and only consults `trace.server` when the output channel's log level is already `Trace`. The `[info] handled method … in Xµs` spam (21 MiB across the log tree, 3.3 MiB in one day's file) is tsgo's own logging, driven by `initializationOptions.logVerbosity` = the output channel's log level and updated via `custom/setLogVerbosity`. Lower it with `Developer: Set Log Level…` on the TypeScript Native Preview channel, not with that setting.

## Host Disk Space

The distro lives on a fixed-size host volume, and the failure mode is the same shape as guest OOM: nothing warns you until everything stops. Reference incident (2026-07-25): `D:` (256 GB) reached **331 MB free**. `ext4.vhdx` was 228.4 GiB while the guest filesystem inside it held only 191 GiB.

**The load-bearing fact: deleting files inside WSL does not return a single byte to the host.** WSL's `ext4.vhdx` is a dynamically expanding VHDX — it grows on demand and *never* shrinks on its own. Every cleanup you have ever run inside the distro is still occupying host blocks. Check the gap with two numbers:

```bash
df -h /                                   # what the guest actually uses
ls -l --si /mnt/d/WSL/<Distro>/ext4.vhdx  # what the host actually gives up
```

### Do not enable sparse VHD

`wsl --manage <distro> --set-sparse=true` looks like the obvious fix — it makes the vhdx an NTFS sparse file so discards punch holes and space returns automatically at `wsl --shutdown`. **Microsoft disabled it by default because it can corrupt data** ([WSL#13075](https://github.com/microsoft/WSL/issues/13075)); enabling it now requires an explicit `--allow-unsafe`, and as of mid-2026 the underlying issue is not resolved ([#12103](https://github.com/microsoft/WSL/issues/12103), [#10609](https://github.com/microsoft/WSL/issues/10609)).

Two second-order traps make it worse than it first looks:

- **Turning it on removes the manual fallback.** `Optimize-VHD` refuses to touch a sparse vhdx ("must not be sparse"), so a disk that fails to auto-shrink can no longer be compacted by hand either — [a documented dead end](https://learn.microsoft.com/en-us/answers/questions/1526083/in-wsl2-with-sparse-vhd-the-storage-usage-does-not).
- **Turning it back off is expensive.** `--set-sparse false` refills every hole, which needs the full uncompacted size free on the host; [#11664](https://github.com/microsoft/WSL/issues/11664) is someone losing 50 GB+ to a failed conversion.

Stay non-sparse and compact periodically instead. That is also where the community converged (Hanselman, Rees-Carter, et al).

### Reclaim procedure

Order matters — compacting before trimming reclaims nothing, and every step after the first requires the distro to be fully stopped.

1. **Delete inside the guest** (see inventory below).
2. **`sudo fstrim -av`** — marks freed blocks as discardable. **This is the step that determines how much compaction reclaims**, not a precaution: the host cannot read the guest's ext4, so the TRIM record is its only evidence of which blocks are dead (see the mode note in step 4). The root mount already carries `discard` so most of it happens continuously, but run it anyway — it is cheap and idempotent. It reports *all* free space on each run, not a delta, so a large number is not evidence that continuous discard was broken.
3. **`wsl --shutdown`** from Windows. This kills every tmux session, every agent pane, and the OpenClaw gateway — an agent working inside the distro cannot perform this step or anything after it.
4. **Compact**, in an elevated PowerShell:

   ```powershell
   Optimize-VHD -Path "D:\WSL\<Distro>\ext4.vhdx" -Mode Full
   ```

   **`-Mode Full` does not actually run as Full here, and that is fine.** [Per the cmdlet docs](https://learn.microsoft.com/en-us/powershell/module/hyper-v/optimize-vhd), `Full` (zero detect + block reclaim) is only permitted when the VHDX is attached read-only; after `wsl --shutdown` it is fully detached, so the call silently degrades to `Prezeroed` (block reclaim only). Nothing is lost — **zero detect is useless against ext4**, which frees blocks by updating metadata and never writes zeros, and Windows cannot enumerate free space inside a non-NTFS guest filesystem the way it can for NTFS. The docs call this case out under `Prezeroed`.

   The consequence is that **block reclaim is the whole operation, and its only input is the TRIM/discard record the guest sent down.** That is what makes step 2 load-bearing rather than optional: skip `fstrim` and compaction just repacks blocks with barely any size change. `-Mode Prezeroed` is the honest spelling of what runs; `Full` is kept above only because it is what every guide prints.

   Falls back to `diskpart` when the Hyper-V module is absent — in-place, needs no scratch space:

   ```
   diskpart
   select vdisk file="D:\WSL\<Distro>\ext4.vhdx"
   attach vdisk readonly
   compact vdisk
   detach vdisk
   exit
   ```

Backing up the vhdx first is the standard advice and is often **not achievable here** — a 228 GiB file has nowhere to go on a host whose largest free volume is 56 GB. Both compaction paths mount read-only, which is the mitigation; note it as accepted risk rather than pretending the step was done.

### What actually accumulates

Measured 2026-07-25 across `~/work` and `~/github`; 96 GiB of the 191 GiB in use was regenerable build output.

| Kind | Size | Note |
|---|---|---|
| `.next` | 52 GiB | one project's `.next/dev` alone was 26 GiB |
| `sourcemaps` | 9.4 GiB | single project, gitignored build output |
| `.next-standalone-optimized` | 8.9 GiB | |
| `.turbo` | 10 GiB | task-result cache, 194 dirs |
| rust `target` | 4 GiB | |
| `~/.npm/_cacache` + `_npx` | 5.9 GiB | |
| `~/.cache/pnpm` | 3.1 GiB | metadata cache, not the store |

Inventory without deleting — the `node_modules` prune is required, or the sweep walks into dependency-internal `.next`/`dist` directories that are part of shipped packages:

```bash
find ~/work \( -type d -name node_modules -prune \) -o \
  \( -type d \( -name '.next' -o -name '.turbo' -o -name 'sourcemaps' \) -print -prune \) \
  | tr '\n' '\0' | du -x -c -s -h --files0-from=- | tail -1
```

Three things that will mislead you while measuring:

- **`du` deduplicates hardlinks within a single invocation, not across them.** pnpm's store is hardlinked into every `node_modules`, so `du ~/.local/share/pnpm` and `du ~/work` each claim the same bytes. Deleting `node_modules` therefore frees far less than its apparent size — it is the worst ratio of disruption to reclaimed space on the list, which is why the cleanup above leaves it alone.
- **Build a delete list as absolute paths.** A list of `./relative/paths` fed to `rm` from a different cwd silently matches nothing and reports success. Verify with `grep -cv '^/expected/prefix/' list.txt` before piping it to `xargs -0 rm -rf`.
- **`sudo` cannot be driven from an agent's shell or from a `!`-prefixed session command** — no tty, no askpass. `fstrim`, `apt clean`, and journal vacuuming have to be run by hand in a real terminal.

### The guard

Because **neither side's `df` can answer "how much more can I write"**. The
guest reports the vhdx's *virtual* capacity — 1 TB by default, on a 256G
partition, which overstated real headroom 5.7× on this host. The host reports
only what the vhdx has not claimed yet, ignoring all the reusable space already
inside it. [`wsl-disk-guard.sh`](../scripts/runtime/wsl-disk-guard.sh) publishes
the number that is actually true:

```
headroom = host avail + gap - reserve
```

`avail` is room for the file to grow; `gap` is room inside the file that the
guest reuses in place, without the host number moving at all. Observed
directly: guest usage climbed 94G → 102G in an hour while `ext4.vhdx` stayed at
exactly 228.4G and host avail never budged.

`reserve` (`WEZTERM_DISK_RESERVE_GB`, default 5) is host space withheld from
WSL. Without it the badge would count the volume's last byte as WSL's to spend,
and hitting zero would mean the host volume is dry — which breaks more than the
distro. With it, headroom reaching zero means "WSL is out of its budget" while
the volume still has room to breathe, so the alert arrives while the situation
is still only a WSL problem. Set it to 0 on a volume nothing else uses.

**`gap` deliberately does not drive the badge or alerting.** When the volume is
a dedicated WSL disk — the usual arrangement, and the case here, where
everything on `D:` other than the vhdx totals 2.9G — reclaimable space is not
waste, it is the distro's own reserve. Flagging it would light a permanent hint
that never needs acting on, which is how a status bar teaches you to ignore it.
Compaction converts gap into avail; it does not create headroom. That makes it
worth doing when something *other than* WSL needs the volume, or when the file
is out of room to grow while sitting on reusable space — `status` prints the
recipe exactly then, and stays quiet otherwise.

| Piece | Where |
|---|---|
| Sampler | `scripts/runtime/wsl-disk-guard.sh sample` / `status` |
| Timer | `wezterm-disk-guard.timer` — user unit, 1 min after start then every 5 min |
| Badge | `wezterm-x/lua/disk_status.lua`, right-status after `◆ SB·N` |
| Escalation popup | `reminder.sh`, the same wrapper cron reminders use |

```bash
./scripts/dev/install-wsl-disk-guard.sh            # install + enable + prime
./scripts/dev/install-wsl-disk-guard.sh --check    # no writes
scripts/runtime/wsl-disk-guard.sh status           # measurement + reclaim recipe
```

**The badge is absent while healthy.** Its presence in the bar *is* the
signal — there is nothing to read in the common case, and no always-on number
to learn to skip. When it does appear it is one number: headroom.

```
(absent)   headroom ≥ 10% of budget
D·22G      below 10% (amber)
D·11G      below 5%  (red — and the guard pops a reminder)
D·?        the sampler was publishing and went stale
```

Thresholds are **percentages of budget**, not absolute sizes: the same 20G is
"plenty" on a 1 TB volume and "about to stop" on a 128G one, and a percentage
does not need re-tuning per machine.

The two `?` cases are deliberately different. A sampler that *was* publishing
and went stale renders `D·?`, because a dead monitor is itself the thing that
needs attention. A machine that never published at all renders nothing, so a
clone without the guard installed shows a clean bar rather than a permanent
question mark.

To see the numbers when the badge is not showing anything, run
`wsl-disk-guard.sh status`.

Alerting fires **on escalation only**, plus a cooldown-gated repeat while still
`crit` (`WEZTERM_DISK_ALERT_COOLDOWN`, default 6h). Improvements never pop: the
badge already shows recovery, and a popup that interrupts to say things got
better is training to dismiss popups unread. Rules are pinned in
[`tests/hook-units/test_wsl_disk_guard.sh`](../tests/hook-units/test_wsl_disk_guard.sh),
including that a large gap must *not* change the level.

#### Configuration

Which volume to watch and how much to withhold are per-machine, so they live
in `wezterm-x/local/shared.env` (template in `local.example/`) rather than in
an env var you have to remember to export:

```sh
WEZTERM_DISK_VOLUME=''        # empty = follow wherever ext4.vhdx lives
WEZTERM_DISK_RESERVE_GB='5'   # host space withheld from WSL
```

Leave `WEZTERM_DISK_VOLUME` empty unless the vhdx and the volume you care
about are genuinely different things — following the vhdx means a relocated
disk does not silently leave the guard watching the wrong drive. When they
*do* differ, the gap stops counting toward headroom: free space inside a vhdx
on some other disk contributes nothing to the watched disk's budget. `status`
says so explicitly rather than quietly dropping it.

Precedence is **explicit env > shared.env > built-in default**. That ordering
needs care in the script, because `runtime_env_load_shell` is `set -a` plus
`source` and would otherwise clobber a caller's exported value — the sampler
captures the explicit env before loading the file and reapplies it after.

Remaining knobs, env-only: `WEZTERM_DISK_WARN_PCT` (10),
`WEZTERM_DISK_CRIT_PCT` (5), `WEZTERM_DISK_ALERT` (1),
`WEZTERM_DISK_ALERT_COOLDOWN` (21600), `WEZTERM_DISK_VHDX`,
`WEZTERM_DISK_STATUS_FILE`, `WEZTERM_DISK_REMINDER_BIN` (test seam).

**A systemd user unit has no Windows interop at all** — no `/mnt/c` on `PATH`,
no `WSL_INTEROP`, no `WSL_DISTRO_NAME`. Verified with `systemd-run --user`. So
the authoritative vhdx lookup (the `Lxss` registry `BasePath`) is impossible
from the timer, and the path cache next to the status file is a *requirement*,
not an optimization. Two consequences are built in:

- **The installer primes the cache from the calling shell before enabling the
  timer.** Enabling first means the timer's first tick beats the cache and
  publishes a `level:"unknown"` sample — observed exactly once during
  development, which is how this was found.
- **A cold cache falls back to globbing the drvfs mounts**, which still works
  without interop. It disambiguates by dropping Docker Desktop's disks,
  dropping candidates smaller than current guest usage (a live distro's vhdx is
  at least its own contents), then taking the most recently written. Note the
  glob must reach `…/AppData/Local/Packages/<pkg>/LocalState/ext4.vhdx` —
  WSL's own default install location is deep enough that shallow patterns miss
  a store-installed distro entirely.

### OEM preinstalls on the same volume

Worth an audit pass when the host volume is tight — on this machine `D:\Program Files\Tencent\Androws` held 22 GiB. Despite the `WeChatAppEx.exe` process it spawns, it is **not** a WeChat component: `HKLM:\SOFTWARE\Tencent\Androws` → `InstallSource` records `"display_name":"腾讯应用宝"`, `"oem_preinstall":1`, `"co_source_id":"microsoft"` — a vendor-bundled Android emulator whose preinstall target is Douyin, carrying its own `WmpfRuntime` mini-program runtime. No WeChat installation exists on this host at all. Read the `InstallSource` JSON before attributing a Tencent directory to whatever app you assume put it there.

Its `Image/` directory keeps **every** version it has ever updated through (8 × ~1.8 GiB here, oldest six months back) while only the newest is live; the stale ones are safe to delete on their own. Full removal goes through `Application\<version>\Uninstall.exe`, then check for `D:\AndrowsData`, the `AndrowsSvr` service, and the `HKLM`/`HKCU` `SOFTWARE\Tencent\Androws` keys.

## Troubleshooting Notes

- If the host volume is full or nearly full, do **not** start by hunting for files on the Windows side — compare `df -h /` against the size of `ext4.vhdx` first. A large gap means the space is trapped in the vhdx and no host-side deletion will touch it; see "Host disk space" above for the trim-then-compact procedure and why `--set-sparse` is the wrong fix.
- If the whole distro disappears — tmux, every agent pane, all at once — and especially if it then keeps coming back and dying on a fixed interval, suspect guest OOM before suspecting WezTerm or tmux. Start from "Guest OOM hardening" above: check `dmesg` timestamp continuity to tell a distro restart from a VM reboot, then read the previous instance's shutdown log for `init.scope: Failed with result 'oom-kill'` and the `memory peak` / `memory swap peak` line (`journalctl --file /var/log/journal/<machine-id>/system@<seq>.journal~ -n 60 --no-pager`).
- For agent-attention "stuck running / done not clearing / right-status not refreshing" reports, **first verify the hook→render latency in the logs before suspecting render or cache layers**. Producer side: `grep "hook emitted agent status" ~/.local/state/wezterm-runtime/logs/runtime.log` — `elapsed_ms` should be ~100–300 ms with `osc_emitted=1`. Renderer side: in the WezTerm log under `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log`, the `category="attention"` lines (`render_status` / `focus ack scheduled` / `jump dispatched`) for the same `session_id` should land in the same frame as the producer's `tick_ms`. If both are normal, the UI is not at fault — pivot upstream: read `attention.json.entries[<id>]` plus `recent[]` and look for whether the producer ever emitted a transition (long stretches of `hook resolved no-op` between a `running` and the next `done` mean the agent really was running, not stuck — Claude Code's protocol only updates status on UserPromptSubmit/Stop, all PreToolUse/PostToolUse runs resolve to no-op).
- If the tmux status line still reflects stale branch or change counts after a local `git` command and only catches up on the next 30s poll, the recommended prompt hook is probably not installed. From an affected tmux pane run `typeset -f __tmux_status_prompt_refresh >/dev/null && echo ok || echo missing`; when it prints `missing`, add the source line documented in [`setup.md`](./setup.md#tmux-status-prompt-hook) to your shell rc and re-source it — existing shells will not pick up the hook until you do.
- If text paste is fast but image-path paste stops working in `hybrid-wsl`, sync the runtime, let WezTerm auto-reload, and inspect the shared `trace_id` across the WezTerm and helper logs.
- In `hybrid-wsl`, WezTerm prewarms the host helper during GUI startup, then still falls back to on-demand ensure when the helper later goes stale or bootstrap state is missing.
- To reproduce the release fallback on a machine that already has Windows `dotnet`, run sync with `WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=release` and inspect `helper-install-state.json` plus the `[helper-install]` terminal lines for `installed_source`, `release_version`, and the installed binary paths.
- If GitHub downloads are too slow, place the zip at `%LOCALAPPDATA%\wezterm-runtime\artifacts\host-helper\<version>\<assetName>` or set `WEZTERM_WINDOWS_HELPER_RELEASE_ARCHIVE`, then rerun sync and confirm `release_archive_source=preload_versioned|preload_flat|explicit_archive`.

## Open questions

Things left unverified or deliberately deferred, with how to close them. Dated so staleness is visible — a claim here older than the code it describes should be re-checked, not trusted.

1. **`agent-cleanup.sh --kill` on a stopped process group is unverified end to end** (2026-07-29). The `SIGCONT`-then-verify path was added after observing the same pgid "terminated" every 30 minutes for 38 hours, but the fix itself was never run against a live stopped group — the local auto-mode classifier blocks `kill`, and the one real specimen was cleaned up manually before the fix landed. Closes when a `lingering=` field or a `signalled … but it is still alive` line shows up in `runtime.log`, or by deliberately `kill -STOP`-ing a throwaway process group and running `--kill --min-age 0` against it. Until then, treat `killed=` in that script's logs as "signalled and confirmed gone" only for non-stopped groups.
2. **`uxc-session-reaper.sh` reports `reclaimed` slightly before it is true** (2026-07-29). `uxc daemon stop` returns once the daemon is down, but the stdio children exit asynchronously — a check immediately afterwards can still see `child_pid` alive, and a check a moment later finds it gone with no orphans. The outcome is correct, only the wording leads. Left alone deliberately: adding a poll loop would trade real complexity for a cosmetic fix. Revisit only if an orphan is ever actually observed.
3. **Next.js dev servers reach ~6 Gi of swap on their own** (2026-07-29). Independent of the MCP work: one `next dev` process was found holding 5.95 Gi of swap with `VmHWM` 6.8 Gi, was cleaned up, and a freshly started one reached 6.1 Gi again within hours. Nothing in this repo manages those processes; restarting them periodically is currently the only mitigation. Worth a decision on whether that belongs in `agent-cleanup.sh`'s scope or stays manual.
4. **Concurrent sessions share one MCP process, so they also share its page-selection state** (2026-07-29). Be precise about what changed, because concurrent interference is **not** new — every MCP instance, resident or uxc-managed, drives the same Chrome on 9222, so anything living in the browser (pages, DOM, login state) was always shared. What moved is the state that lives in the *MCP process*: the selected page and the snapshot `uid` map. The daemon keys sessions on `stdio:{endpoint}:{auth_fingerprint}` with no caller identity, so all agents land on one child and now share those too.

   | scenario | resident MCP | via uxc |
   |---|---|---|
   | two sessions driving the **same** page | already unsafe (browser-level) | unchanged |
   | two sessions driving **different** pages | safe | **can cross wires** |

   So the delta is exactly one case: work on separate pages, previously safe, can now silently mis-target — A selects page 2, B selects page 5, A's next `take_snapshot` returns page 5 without erroring. Wrong data, no failure signal. Do not read this as "uxc introduced concurrency problems"; the browser-level ones predate it and reverting to resident MCP would not fix them.

   The mitigation is `--experimentalPageIdRouting`, which removes the implicit selected-page: measured, it turns `take_snapshot` into `required: ['pageId']`, `click` into `required: ['pageId', 'uid']`, and leaves `list_pages` as the only page-scoped tool needing no id. Its cost is that it **breaks every example in upstream's skill** (`click uid=3_0` starts failing on a missing `pageId`), and upstream documents no such mode. A second option — a distinct endpoint string yields a distinct `session_key` and hence a separate process — isolates fully but gives back the single-instance win.

   `pageId` is safe to hold onto: it is a stable allocated id, not a list position. Verified by opening two scratch pages (6, 7), closing 6, and confirming 7 stayed 7 rather than sliding down — consistent with v1.6.0's `keep page ids unique across browser reconnects` (#2345). Ids do differ between *separate* MCP process instances, which is why two `list_pages` runs against different children can order the same tabs differently; within one child they are stable. So routing is a sound fix, not a partial one.

   Neither is applied yet: the collision needs two agents driving the browser inside the same 10-minute window, plausible here but not routine. Escalate to `--experimentalPageIdRouting` the first time a snapshot is observed returning the wrong page — do not wait for a second occurrence, since the failure is silent.
5. ~~**`goMemLimit: "6GiB"` is applied; the CPU benefit is still unproven**~~ → **closed 2026-08-04 19:31.** The fix is verified, and the diagnosis survived its falsification test. Reloaded at 17:03; 2 h 28 m later the `ai-video-collection` server sat at **RSS 3.55 Gi — past the old 3 GiB cliff — on 14 m 41 s of CPU (10.2 % average, and 4 of 6 instantaneous 10 s samples at 0 %)**. Under the old limit that same RSS meant a permanent 145 %, so this is the decisive comparison: **CPU −93 % at equal-or-higher memory**. `VmHWM` reached 5.21 Gi and RSS then fell back to 3.55 Gi, which the old configuration could never do — it could not get below 3.94 Gi. Swap 0.

   Two notes for whoever reads this later. **The tripwire is live heap, not peak RSS.** The 5.21 Gi peak is GC slack (`GOGC=100` grows the heap toward 2× live before collecting), and a soft limit only turns pathological when *live* heap exceeds it — live is ~2.9–3.6 Gi here, so the 6 GiB ceiling still has ~2× headroom despite the peak looking close. **And per-project cost is not a fixed number**: at the same moment, the `dev-web-cmdb` worktree of the *same* monorepo held 58 Mi on 2 s of CPU, 63× less, purely because no TS file had been opened in that window. tsgo's cost tracks which `tsconfig` projects get loaded by the files you actually open, not repository size — so "one resident cost per project" badly overestimates.
6. **Where the heap goes — and why it grows 2.82 → 3.94 Gi over a day — is unmeasured** (2026-08-04). Raising the limit stops the CPU burn but does not make the heap smaller. Two separate questions: whether ~2.8 Gi is a reasonable cold cost for this monorepo's type information, and whether the +1.1 Gi drift across 21 h of editing is legitimate working set or a leak. The second matters more, because a leak would eventually cross any limit and reinstate the burn. The extension exposes `js/ts.server.pprofDir` plus `dev.saveHeapProfile` / `dev.saveAllocProfile` commands, so a real heap profile is available — it needs a Go toolchain for `go tool pprof`, which is not installed here. Until someone looks, "3.9 Gi is just what this project costs" is an assumption, not a finding.
7. **`validate.enabled: false` looks honoured; the rest of the tuning block is still unverified** (2026-08-04, revised same day). The earlier reading here — "delivered but seemingly ignored, because `textDocument/diagnostic` keeps being handled" — was **too strong**. Latency settles it: 97.7 % of 9 631 diagnostic calls return under 5 ms (p50 0.23 ms), which cannot be real type checking, so the key stops the *checking* while VS Code's pull-diagnostics client keeps issuing *requests* on its own schedule. Part (a) of this is now **closed**: the slow tail was requests blocking behind project load, not checking — proved by the disabled `inlayHint` accumulating 13.3 s it cannot have spent working, and confirmed on a clean post-reload log where only 2 of 131 calls exceeded 500 ms, both inside the 5-second startup window. What remains open: `suggest.autoImports: false` is delivered yet `Built autoimport registry` still appears in the logs, and no latency argument has been made for it. Closes per key by dumping the `config:"…"` struct tags from the `tsgo` binary and matching them against observed behaviour, not against the settings schema.
8. **The tmux status poll fires at ~44s, not the configured 30s** (2026-08-05). Traced while fixing the concurrent-refresh drop described in [`tmux-ui.md`](./tmux-ui.md): two independent draw-path invocations decided to poll at `age=44` and `age=45` against `@tmux_status_poll_interval 30`. The poll is lazy — it only evaluates when tmux re-runs the `status-format[0]` `#()` job, so the real cadence is `status-interval` **plus** whatever the job scheduler adds under load, not the option value. It stopped being load-bearing now that a forced refresh waits for the lock instead of being dropped, but any future reasoning that treats 30s as the worst-case staleness bound is wrong by ~50%. Closes by timestamping consecutive `reason=poll` decisions for one session over a quiet hour and comparing against `status-interval`, or by moving the fallback poll off the draw path entirely.
9. **One option write repaints every attached client, so a single refresh forks ~3×N job processes** (2026-08-05). Same trace: each `tmux set-option -t <session> @tmux_status_line_*` made all 11 attached clients redraw their status, and each redraw ran all three `status-format` `#()` scripts — 33 short-lived bash processes per refresh, for a change that concerns exactly one session. With 11 sessions each polling on its own timer this is a standing background cost, and it is the most likely reason the poll cadence above degrades under load. Not fixed here: the change would be structural (collapse the three lines into one job, or stop having the draw path read options tmux itself just wrote). Closes by measuring `fork`s per refresh (`perf stat -e` or a wrapper counter) before and after collapsing the three `status-format` jobs into one.
10. **Reconnect cost is unmeasured, and it is the real argument against a short TTL** (2026-07-29). A freshly spawned session reached 1411 Mi within 6 minutes of being created against three open tabs (one of them a Grafana explore view) — the collectors appear to absorb the current pages' history on attach, not just events arriving afterwards. Against the old resident numbers (3.3 Gi over 37 h) that is a far steeper curve, so shortening the TTL trades accumulation for repeated re-absorption. Nothing here is wrong — the peak is reclaimed rather than kept — but if the TTL is ever tuned, measure how much a reconnect costs before assuming shorter is better.
11. **The VS Code Z-order LRU fix ships only to `install_source=local` installs** (2026-08-08). It was verified by hand-dropping a locally built `helper-manager.dll` into `%LOCALAPPDATA%\wezterm-runtime\bin\`, previous binary kept beside it as `helper-manager.dll.bak-preZorderLru`. Two loose ends, and they point in opposite directions. **This machine is fine**: `helper-install-state.json` says `source: local`, so `install-windows-runtime-helper-manager.ps1` rebuilds from the working tree and a reinstall carries the fix — but the bytes currently running came from a manual `cp`, not from that script, so `bin/` is not in a state the installer produced and the `.bak-` file is litter until someone reinstalls. **`install_source=release` installs are not fine**: `native/host-helper/windows/release-manifest.json` still pins the pre-fix build, so they keep the old behaviour — the reused window locks onto whichever one the helper recorded first — with no visible signal that the two disagree. Closes by cutting a host-helper release per [`host-helper-release.md`](./host-helper-release.md), updating the manifest, and deleting the `.bak-preZorderLru` file. Until then, `decision_path="max_windows_reuse_zorder_lru_window"` in this machine's `helper.log` says nothing about what a release install does.

    Same commit also added the title-based already-open check (`max_windows_focus_window_showing_folder`) after the Z-order change alone produced a worse failure: it displaced a window for a folder VS Code then de-duped elsewhere, and wrote a registry key pointing at a window that never received the folder — `Alt+v` on that folder afterwards opened an unrelated project, permanently, since every later request hit the same bad key. Two known-fragile spots in the new check, neither yet observed failing: a custom `window.title` template stops the match (degrades to displacing, not to anything worse), and two folders with the same leaf name under the same distro would match each other. Closes by either accepting the heuristic or giving the helper a real folder→window source; revisit if `decision_path="max_windows_focus_window_showing_folder"` ever focuses a visibly wrong project.
12. **What actually empties the overflow pane's in-memory session edge is inferred, not observed** (2026-08-19). The recycled-pane-id fix (see [`tab-visibility.md`](./tab-visibility.md), *Recycled pane ids*) is grounded in measured state: pane 6 (`…`, work) and pane 4 (`coco-forge`) both resolved to `wezterm_work_coco-forge_060820bd21` in `live-panes.json` while `tmux list-clients` had the placeholder on `wezterm_work_overflow`, and `pane-session/6.txt` was two weeks older than the pane. What is *not* observed is why the in-memory tier — seeded with the browse session by `spawn_overflow_tab` at 08-17 19:10 — was empty by the time the file was read; a config reload dropping the Lua state's `_G` is the plausible candidate, a spawn-time `set_pane_session` failure the other. It does not change the fix (the file tier is wrong for that pane either way), but it does decide whether the placeholder's post-reload badge amnesia is a real, frequent trade-off or a non-event. Closes by logging one line in `spawn_overflow_tab` after the seed and one in `window-config-reloaded` reporting `_G.__WEZTERM_PANE_TMUX_SESSION` size, then reading the ordering after the next sync-driven reload.
13. **Grok FocusGained full-clear flash — waiting on upstream gate narrow** (2026-08-20; macOS timing + WSL size A/B closed same day). Primary cause and local fix: [`tmux-ui.md#grok-build-in-tmux`](./tmux-ui.md#grok-build-in-tmux). Stable **1.0.5** / alpha **1.0.7** still emit `\e[2J` on CSI FocusIn under any detected multiplexer; `/feedback` filed 2026-08-20 (GH Issues disabled). **Local mitigation verified** after `grok-with-focus-filter.sh --install` (`~/.grok/bin/grok` → wrapper, ELF at `grok.real`) with resume tree `python3 → grok.real` and no interactive flash. **Why macOS can look fine:** same heal fires; dingbo’s native WezTerm+tmux client redraw burst is typically **1–6 ms** (inside one 60 Hz / ~16.7 ms frame), so the cleared intermediate is not painted as its own frame — not an OS exemption. **WSL size A/B closed:** unfiltered `grok.real` in isolated WezTerm + `groknofilter`, Grok pane ~**31×15** in a ~**60×18** client, still whole-content flashes on `Alt+o` — shrinking is not an escape hatch on this hybrid stack (tmux/Grok in WSL, WezTerm on Windows); leading suspect remains **WSL interop fragmenting/delaying** the client burst. Close the upstream item when stock Grok stops clearing on FocusGained under plain tmux (`repro-grok-focus-flash.sh inject-real` → `no-clear`), then remove the wrapper. Until then keep `--install` after every `grok update`; cream `bg_base` patching is secondary only.
