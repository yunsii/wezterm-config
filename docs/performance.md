# Performance

Use this doc when the task is to investigate, validate, or change anything
on the Alt+/ attention-popup hot path, or when you need the cross-
filesystem routing rule for placing a new state file. It captures the
data that drove every decision in commits `1d099c8` and `789cbcf`, so
future "can we make this faster?" instincts have ground truth instead
of intuition.

## Why this surface matters

Alt+/ is the most-used chord in this configuration: a single day's work
typically fires it 50-100+ times because it is the eyes-on entry point
for the multi-agent attention pipeline (every "is anything waiting?"
glance routes through it). 100ms vs 50ms is the difference between
"feels snappy" and "feels sluggish" at that frequency, and the chord
sits on the critical path for several derived flows (`Alt+,` and `Alt+.`
share most of the same dispatch infrastructure; the worktree picker
re-uses the popup pattern).

The optimization arc documented here took p50 menu-prep time from
**545ms to 49ms** (11x) and produced a permanent measurement harness so
future regressions surface immediately.

## File catalogue

### Hot-path production code

The path a single Alt+/ press traverses, in order, with each owner's
performance contract.

| File | Role | Perf-relevant property |
|---|---|---|
| `wezterm-x/lua/ui/action_registry.lua` (`attention.overlay`) | WezTerm key handler. Walks mux → writes `live-panes.json` → forwards `\x1b/` to tmux | In-process, ~5ms |
| `wezterm-x/lua/attention.lua` (`write_live_snapshot`) | Atomically writes the pane snapshot before forwarding | `os.remove` + `os.rename` retry to work around Windows rename semantics |
| `tmux.conf` (`bind-key -n M-/`) | Forwards to the menu wrapper | tmux dispatch, ~5-15ms |
| `scripts/runtime/tmux-attention-menu.sh` | Reads state + builds row tuples + opens popup. Bench-instrumented via `WEZTERM_BENCH_NO_POPUP=1` | p50 49ms (was 545ms) |
| `scripts/runtime/windows-runtime-paths-lib.sh` | Resolves Windows `%LOCALAPPDATA%` etc. once + caches to disk | 24h TTL cache at `~/.cache/wezterm-runtime/windows-paths.env`; bypass with `WEZTERM_NO_PATH_CACHE=1` |
| `scripts/runtime/attention-state-lib.sh` | Reads attention state. Sources paths-lib once at lib-load, memoizes resolved path | All callers share one `__ATTENTION_STATE_PATH_CACHED` |
| `scripts/runtime/picker/main.go` | Static Go binary that runs inside the tmux popup pty | ~2-5ms cold (vs ~30-80ms bash fallback) |
| `scripts/runtime/picker/bin/picker` | Compiled binary, gitignored | Built by sync; missing → bash fallback kicks in |
| `scripts/runtime/tmux-attention-picker.sh` | Bash fallback picker (used when Go binary is missing) | Sources 3 libs cold |
| `scripts/runtime/tmux-attention/render.sh` | Shared bash frame renderer (used by menu pre-paint + bash picker live re-render) | Single ANSI-positioned string, single `printf` flush |

### Build / sync infrastructure

| File | Role |
|---|---|
| `scripts/runtime/picker/build.sh` | Builds the Go binary. Auto-discovers `go` from PATH / `~/.local/go/bin` / `/usr/local/go/bin`. Skips silently when Go is missing |
| `scripts/runtime/picker/{go.mod, go.sum}` | Go module pinning `golang.org/x/term` |
| `skills/wezterm-runtime-sync/scripts/sync-runtime.sh` | Added `step=build-picker` between `render-tmux-bindings` and `copy-source` |
| `.gitignore` | Excludes `scripts/runtime/picker/bin/` (build artifact) |

### Diagnostic UI (temporary, slated for removal)

These exist while the Go picker and bash fallback run side-by-side.
Drop both once the bash fallback is removed.

| Surface | Purpose |
|---|---|
| `powered by go` (green, palette 108) / `powered by bash` (orange, 208) footer badge | Make the active code path legible at a glance during the parallel-implementation phase |
| `47ms = 8+22+17 (lua+menu+picker)` footer | End-to-end key→paint latency split into three buckets so any future regression is attributed to the right layer |

### Permanent measurement harness

The most valuable artifact — these are the tools you reach for the
next time anyone asks "can Alt+/ be faster?".

| File | Use when |
|---|---|
| `scripts/dev/bench-menu-prep.sh` | Microbenchmarking menu.sh's prep work in isolation. Sets `WEZTERM_BENCH_NO_POPUP=1` so the popup never opens — **does not disrupt your tmux**. Runs N iterations (default 30 + 5 warmup), reports min / p50 / p95 / max / mean per stage with deltas. Use for tight optimization loops. |
| `scripts/dev/bench-attention-popup.sh` | End-to-end validation via `tmux send-keys M-/`. **Will flash your popup N times** — for final acceptance, not iteration. Reads `category="attention.perf"` log entries the picker emits. |
| `scripts/dev/bench-wezterm-side-fs.ps1` | PowerShell harness measuring wezterm.exe-side file read latency: `%LOCALAPPDATA%` (Windows local NTFS) vs `\\wsl$\<distro>\…` (cross-boundary 9P). Definitively settles "should we move this state file to WSL ext4?" questions. Invoke from WSL via `windows_run_powershell_script_utf8`. |

### Perf-only logging

Both picker code paths emit `category="attention.perf"`,
`message="popup paint timing"` on every render with structured fields:

```
paint_kind     "first" | "repaint"
picker_kind    "go" | "bash"
total_ms       end-to-end key → render
lua_ms         menu_start - keypress  (Lua handler + tmux dispatch + bash boot)
menu_ms        menu_done  - menu_start (jq + popup spawn prep)
picker_ms      render     - menu_done  (popup pty + picker init + first frame)
item_count     rows in the picker
selected_index 0-indexed cursor position at render time
```

Opt-in: `export WEZTERM_RUNTIME_LOG_CATEGORIES=attention.perf` in
`wezterm-x/local/runtime-logging.sh` to keep the noise out of the
default-on `attention` category. The bench harness reads these rows to
compute its stats.

## Decisions and the data behind them

Every decision in this round was measurement-driven. Future readers
should not re-litigate any of these without re-running the relevant
bench.

| Decision | Measured data | Choice | Where |
|---|---|---|---|
| Bash vs Go picker on the popup-pty side | Bash startup + 3 lib sources cold = 30-80ms; Go static binary = 2-5ms (~15-25x) | Go on the hot path, bash as fallback when binary is missing | `scripts/runtime/picker/`, `tmux-attention-menu.sh` dispatch |
| Cache the Windows env detection (`%LOCALAPPDATA%` / `%USERPROFILE%`) | Each Windows shell spawn from WSL ~100-200ms; menu.sh triggered detection 6+ times per Alt+/ → up to 600ms pure interop overhead | 24h disk cache at `~/.cache/wezterm-runtime/windows-paths.env`. Most savings of any single change | `windows-runtime-paths-lib.sh` |
| Hoist `windows-runtime-paths-lib` source from per-call to lib-load | Per-call source parsed ~150 lines × 3 calls per menu.sh run | Source once at `attention-state-lib.sh` load; in-process memo for `attention_state_path` | `attention-state-lib.sh` |
| Replace `date +%s%3N` with `EPOCHREALTIME` arithmetic | Each `date` fork = ~5ms; multiple stamps per menu.sh run | bash 5 builtins (`EPOCHREALTIME`, `EPOCHSECONDS`, `RANDOM`) for `start_ms` and `trace_id` | `tmux-attention-menu.sh` |
| Drop `attention_state_init` from menu hot path | Init does mkdir + a /mnt/c stat for 5-10ms of pure cross-FS overhead with no value to a read-only caller | `attention_state_read` already returns empty JSON when the file is missing — init is for writers (hooks) only | `tmux-attention-menu.sh` |
| Drop the `jq -r '.entries | length'` count check | ~5ms cold jq spawn for redundant info — main pipeline already produces 0 rows on empty input, item_count short-circuit downstream catches it | Removed | `tmux-attention-menu.sh` |
| Merge `live_map`'s two jq calls (ts + panes) into one | Saves one cold jq spawn (~5ms) + one /mnt/c page-cache miss | Single jq emits both fields, U+0001 (SOH) delimiter, bash parameter expansion split | `tmux-attention-menu.sh` |
| Move `hotkey-usage.json` to WSL ext4 | Pure WSL bash writer + reader; /mnt/c was paying cross-FS penalty for nothing | Default path is now `${XDG_STATE_HOME:-$HOME/.local/state}/wezterm-runtime/hotkey-usage.json`; one-time legacy migration in the bump script | `hotkey-usage-lib.sh` |
| **Do NOT** move `attention.json` to WSL ext4 | wezterm.exe reads `/mnt/c/…` at p50 0.02ms; reading `\\wsl$\…` at p50 3.12ms (~150x slower). Lua tick = 4 Hz × ~3ms × N files = tens to hundreds of ms/sec wezterm CPU | Stay on /mnt/c. The bash menu.sh paying ~5ms per Alt+/ is much cheaper than the continuous tick cost | `bench-wezterm-side-fs.ps1` |
| **Do NOT** move `live-panes.json` to WSL ext4 | Per-Alt+/ tradeoff: Lua write +10ms vs bash read -5ms = net loss | Stay | Same |
| **Do NOT** move `tmux-focus/*.txt` to WSL ext4 | Same as `attention.json` — Lua reads on every tick × N tmux sessions | Stay | Same |

## The cross-FS routing rule

The catalogue and the wezterm-side bench together produce one rule
that should govern every future state-file placement decision:

> **A file belongs on WSL ext4 if and only if every reader and every
> writer is a WSL process AND the access frequency from WSL warrants
> the move.**
>
> If any consumer is a Windows process (wezterm.exe, helper.exe), the
> file lives on Windows NTFS so the Windows side reads/writes locally;
> WSL bash pays the ~5ms cross-FS penalty as the minority case.
>
> Even when both sides are WSL, do not move if the access pattern
> already hits the page cache nearly free (e.g. files read once per
> minute) — the migration code is also a cost.

Concrete classification of the current files (re-derive when adding
new state):

- WSL ext4 (pure-WSL, frequently accessed):
  `~/.local/state/wezterm-runtime/wezterm-runtime.log` (bash logs),
  `~/.local/state/wezterm-runtime/hotkey-usage.json`,
  `~/.cache/wezterm-runtime/windows-paths.env`
- /mnt/c (writer or reader is a Windows process):
  `state/agent-attention/{attention.json, live-panes.json, tmux-focus/*}` (lua tick reads),
  `state/clipboard/exports/*.png` (Windows helper reads),
  `state/helper/*` (Windows helper IPC),
  `cache/helper/*` (Windows helper writes),
  `bin/helperctl.exe` (Windows binary),
  `logs/{wezterm.log, helper.log}` (lua/helper write locally; humans grep occasionally)

## Optimization techniques (replicable patterns)

These are the cross-cutting techniques the bench data validated. Reach
for them when optimizing any other shell hot path in this repo.

1. **Persistent disk cache for stable values.** Anything that requires
   spawning a Windows shell to read an env var should be cached with a
   long TTL. ~600ms savings per menu.sh.
2. **In-process memoization.** When the same expensive computation
   happens multiple times in one script invocation, cache to a global
   var on first call. ~10-20ms per duplicate.
3. **Source libs once at load time, not per-call.** Sourcing parses the
   whole file. Hoist `source` out of functions when the function is
   called more than once.
4. **bash 5 EPOCHREALTIME / EPOCHSECONDS builtins** instead of `date`
   subshells. Saves ~5ms per timestamp captured.
5. **Combine subprocess invocations.** One jq pass that emits multiple
   fields (delimited by SOH) beats N small jq calls. Same for tmux
   format strings: `'#{client_width}\t#{client_height}'` beats two calls.
6. **Drop hot-path work that early-exit paths don't need.** The
   `attention_state_init` and the redundant count-check `jq` were both
   speculative — the downstream path already handles their concerns.
7. **Use bash builtins instead of forking** for parsing: parameter
   expansion `${var%%delim*}` / `${var#*delim}` instead of `cut`/`sed`/
   `awk` for known-shape strings.
8. **Static binary in the popup pty.** When the consumer process is
   short-lived AND inside a popup (where pty creation already costs
   ~10ms), bash startup + lib sourcing dwarfs the actual work. A static
   Go binary cuts process startup from 30-80ms to 2-5ms.
9. **Pre-render the first frame upstream + slurp it with bash builtin
   `$(<file)`.** Eliminates fork+exec of `cat` on the first-paint path.
10. **`tmux run-shell -b` for fire-and-forget dispatch** so the popup
    closes BEFORE the slow downstream work runs — the user perceives
    the action as instantaneous even when it takes 50ms+ to complete.

## What we explicitly did NOT do (and why)

These options were considered, costed, and rejected. Capturing them so
they don't get re-proposed without new evidence.

- **Move data prep entirely to Lua (lua-上移)** — would save ~30ms per
  Alt+/ by eliminating menu.sh's bash + jq cost, but requires keeping a
  Lua row-builder + Lua frame renderer in sync with the Go renderer
  (~150 lines of dual-implementation maintenance). At 49ms p50, total
  is below human-perception threshold (~50ms); the maintenance cost
  outweighs the perceptual benefit.
- **Long-lived picker daemon + IPC** — saves ~5-10ms more by skipping
  the binary exec on every press, but requires process lifecycle
  management, restart-on-crash, IPC protocol design. Diminishing
  returns.
- **Replace tmux popup with a wezterm overlay** — would skip popup pty
  spawn (~5-20ms), but wezterm's InputSelector hard-codes its cancel
  keys in `wezterm-gui/src/overlay/selector.rs` (no way to bind Alt+/
  as a toggle), which is the original reason we left InputSelector for
  tmux popup. Can't go back.
- **Migrate `attention.json` / `live-panes.json` / `tmux-focus/*` to
  WSL ext4** — see the cross-FS measurement above. Net loss because
  the Lua side reads on every tick.
- **Replace `jq` with pure bash JSON parsing** — fragile against
  arbitrary `reason` strings (user-controlled content from the agent),
  and the merged-jq optimization already cut jq cost to ~5ms total
  (under 10% of remaining latency). Not worth the correctness risk.

## Long-term observability

Every Alt+/ press already writes a structured `attention.perf` row to
`~/.local/state/wezterm-runtime/logs/runtime.log` — no extra setup
required. The data is enough to answer "did anything regress?" weeks
later without re-running benches.

### Schema

```
ts="2026-04-25 14:57:28.170" level="info" source="<script>"
  category="attention.perf" trace_id="..."
  message="popup paint timing"
  paint_kind="first|repaint" picker_kind="go|bash"
  total_ms="N" lua_ms="N" menu_ms="N" picker_ms="N"
  item_count="N" selected_index="N"
```

`ts` is millisecond-precision (see runtime-log-lib's EPOCHREALTIME
path) so events within the same Alt+/ press are ordered correctly.
`paint_kind="first"` is the per-press measurement; `repaint` rows are
Up/Down navigation and should be filtered out for first-frame stats.

### Trace ID propagation

The WezTerm `attention.overlay` Lua handler stamps a `trace_id` into
`live-panes.json` on every Alt+/ press. menu.sh reads it from the
snapshot, adopts it as `WEZTERM_RUNTIME_TRACE_ID`, and exports it so
the picker process inherits the same id. Result: a single id flows
lua → menu → picker → attention-jump.sh, and a single grep assembles
the full per-press timeline from both `runtime.log` (bash logs) and
`wezterm.log` (Lua logs):

```bash
trace='attention-20260425T145728-3835014-7695'
grep "trace_id=\"$trace\"" \
  ~/.local/state/wezterm-runtime/logs/runtime.log \
  /mnt/c/Users/Yuns/AppData/Local/wezterm-runtime/logs/wezterm.log
```

### Trend reporting

`scripts/dev/perf-trend.sh` reads the historical `attention.perf` rows
and reports trend / diff / live-tail views. Useful for "did this
change make things slower over the last week?" without re-driving the
bench harness.

```bash
# Daily p50/p95/mean for the last 7 days
scripts/dev/perf-trend.sh

# Side-by-side stage breakdown for two days
scripts/dev/perf-trend.sh --diff today yesterday
scripts/dev/perf-trend.sh --diff 2026-04-25 2026-04-18

# Per-event dump (for spotting outliers)
scripts/dev/perf-trend.sh --raw today | head -20

# Live tail — useful right after a code change to watch new presses land
scripts/dev/perf-trend.sh --watch

# Filter by code path (Go binary vs bash fallback)
scripts/dev/perf-trend.sh --picker-kind go
```

When investigating a regression, the typical flow is:

1. `--days 14` to spot when the p50 / p95 climbed
2. `--diff <good-day> <bad-day>` to see which stage (lua / menu /
   picker) drove it
3. `--raw <bad-day>` to see whether the regression is everything
   slowing down or a long tail of cold-start outliers
4. Re-run `bench-menu-prep.sh` to bisect the change

## Where to start a new optimization round

1. Run `scripts/dev/bench-menu-prep.sh --runs 30 --warmup 5 --label baseline`
   to get current p50 before touching anything.
2. Make one change. Re-run with `--label after-X`. If p50 didn't move
   by ≥ 5ms, revert — tighter thresholds are noise on this harness.
3. For end-to-end validation, run `scripts/dev/bench-attention-popup.sh`
   (will flash your popup, run when you're not actively using the
   terminal).
4. For cross-FS questions, run `scripts/dev/bench-wezterm-side-fs.ps1`
   via the windows-shell-lib UTF-8 wrapper.

## Floor reached

Remaining ~49ms p50 is dominated by physical limits:

- ~6ms cat of `attention.json` from `/mnt/c` (page-cache warm)
- ~12ms read + jq of `live-panes.json` from `/mnt/c`
- ~5ms main jq pipeline (already a single invocation)
- ~5ms tmux geometry probe + frame pre-render

Going below ~30ms requires either moving the high-tick state files
(net loss per measurements) or eliminating the bash menu layer entirely
(maintenance loss). Both rejected with data above.
