# Logging Conventions

Hard rules for code that emits log lines.

For the **operator** surface — env knobs, where files live, how to read them, smoke tests, troubleshooting — read [`diagnostics.md`](./diagnostics.md). This doc is for **authors** adding or modifying logger callsites.

## Where logs go

Four log files, segmented by **which process writes**. The file lives on the writer's native filesystem so the writer never pays the cross-FS penalty; cross-FS readers (rare) absorb the cost in their own paths.

| File | Writer | Why this side |
|---|---|---|
| `~/.local/state/wezterm-runtime/logs/runtime.log` (WSL ext4) | every bash script in `scripts/runtime/`, every `picker` invocation, the Claude/Codex agent hooks | WSL-native; ~150× faster than `/mnt/c` per the cross-FS routing rule in [`performance.md`](./performance.md) |
| `%LOCALAPPDATA%\wezterm-runtime\logs\wezterm.log` (Windows NTFS) | WezTerm Lua via `wezterm.log_*` + `append_file` in `wezterm-x/lua/logger.lua` | wezterm.exe is a Windows process |
| `%LOCALAPPDATA%\wezterm-runtime\logs\helper.log` (Windows NTFS) | `helper-manager.exe` (.NET host helper) | helper is a Windows process |
| `/var/log/wezterm-oom-guard.log` (WSL ext4, root-owned) | `scripts/runtime/wsl-oom-guard.sh` under the `wezterm-oom-*` systemd units | root-owned system service, not a user session — see the exception below |

Never hard-code paths. Bash sources `scripts/runtime/wsl-runtime-paths-lib.sh` for `WSL_RUNTIME_LOG_FILE`; Lua reads `diagnostics.wezterm.file` from `wezterm-x/local/constants.lua`; the Go picker honors `WEZTERM_RUNTIME_LOG_FILE` else derives the same XDG default.

**The one sanctioned exception is the OOM guard.** It stays out of the XDG tree and out of `wsl-runtime-paths-lib.sh` for three reasons, all load-bearing — do not "fix" it by folding it into `runtime.log`:

1. It runs as **root** under systemd, so `$HOME` is `/root` and any `XDG_STATE_HOME`-derived constant would resolve to the wrong tree. Hard-coding the user's home into a root unit is worse than a `/var/log` path.
2. Root-owned lines interleaved into a user-owned `runtime.log` create permission and rotation hazards for every other writer of that file.
3. It writes to **both** stdout (the journal) and a plain append-only file *on purpose*. The journal fragments across exactly the distro restart loop this guard exists to diagnose — see [`diagnostics.md`](./diagnostics.md) "Guest OOM Hardening". The duplication is the durability guarantee, not an oversight.

The path is overridable via `WEZTERM_OOM_GUARD_LOG`, which is how the sandboxed tests keep out of the live file.

When adding a new log writer, ask: **does this writer ever run on the other side of the WSL boundary?** Yes → file belongs on the writer's native FS, not the reader's. The cross-FS penalty is asymmetric and the writer is always the hot side.

## Render-path discipline

Code that paints a UI frame **must not call the logger inline**. Surfaces in scope:

- popup picker render functions (Go `cmd_*.go` `render()`, bash `render_picker()`)
- WezTerm `format-tab-title`, `update-status`, `user-var-changed` callbacks
- tmux right-status renderers (`scripts/runtime/tmux-status-*.sh`)

Reasons:

- A render path that fires once per keystroke produces rows nobody reads. The historical "log every paint" pattern in the pickers wrote one row per Up/Down keypress, but every consumer (`perf-trend.sh`, `bench-attention-popup.sh`) explicitly filters to `paint_kind="first"`.
- Even category-gated logging adds env lookups + string formatting to a loop where the p50 budget is single-digit ms.
- The frame painter is the wrong layer to judge "is this transition interesting enough to log?" — that is a state-transition concern.

Acceptable patterns:

1. **State-transition gate.** Log only when a tracked signature changes. `wezterm-x/lua/titles.lua` does this with `badge_last_status[tab_id] ~= current` and `last_rendered_status ~= signature` — copy that template.
2. **Once-per-popup perf event.** Emit one row at first paint, *after the first frame's bytes hit stdout*, from the **calling site** (the loop that drives `render()`), never from inside `render()` itself. Subsequent repaints emit nothing.
3. **Out-of-band timing flush.** When a render path needs to record latency, accumulate it into a struct field and flush from a non-render entry point (popup teardown, dispatch, exit).

If you genuinely need ad-hoc render-path debugging, gate it behind an explicit env var (`WEZTERM_DEBUG_RENDER=1`) and remove the call before commit.

## Categories

Add a new category only when an existing one would dilute its meaning. Currently registered:

- **bash** (`scripts/runtime/`): `attention`, `agent_cleanup`, `clipboard`, `command_panel`, `managed_command`, `overflow`, `popup`, `primary_pane`, `provider`, `sync`, `task`, `vscode`, `workspace`, `worktree`
- **Lua** (`wezterm-x/lua/`): `attention`, `chrome`, `clipboard`, `command_panel`, `host_helper`, `hotkey`, `ime`, `latency`, `tab_visibility`, `vscode`, `workspace`
- **C# helper** (`helper-manager.exe`): owned in `native/host-helper/`, treat as read-only from the WSL/Lua side

Rules:

1. **Lower-snake_case.** No spaces, no PascalCase, no dots inside the base name.
2. **`<base>.perf` is reserved for perf events** that follow the schema in [`performance.md`](./performance.md) "Perf-only logging". One `.perf` subcategory per UI surface (`attention.perf`, `command.perf`, `worktree.perf`, `links.perf`, `latency.perf`). Never reuse `<base>.perf` for non-perf events.
3. **Lifecycle / dispatch events live in the base category**, not in `.perf`. Base categories default-on; `.perf` is opt-in via `WEZTERM_RUNTIME_LOG_CATEGORIES` (bash) or an explicit flag / allowlist (Lua `latency.perf` — see below).
4. **One category per subsystem, not per file.** `attention-jump.sh`, `attention-state-lib.sh`, and `tmux-attention-picker.sh` all log under `attention`.
5. **Cross-language alignment.** When bash and Lua cooperate on one flow, use the same base name on both sides (`attention` on both, not `attention` vs `att`).

## Levels

| Level | Use for |
|---|---|
| `error` | unrecoverable failure for this invocation; the user-visible action did not happen |
| `warn` | recovered or fell back, but the user might want to know (manifest entry skipped, alternate path taken) |
| `info` | control-plane events: started X, finished X with `duration_ms`, decision Y reached |
| `debug` | verbose state dumps for active investigation; default-off at `WEZTERM_RUNTIME_LOG_LEVEL=info` |

Default level is `info`. Do not log at info level inside any loop that runs more than once per user action.

## Required fields

Every line gets `ts`, `level`, `source`, `category`, `message`, `trace_id` from the lib — do not add them manually.

Beyond those, the schema below is enforced by convention (no lint yet — break it deliberately or not at all):

- **Lifecycle "X started":** identifying fields the operation works on (`session_name`, `cwd`, `worktree_root`, …).
- **Lifecycle "X completed":** the same identifiers plus `duration_ms` — use `runtime_log_duration_ms "$start_ms"` in bash; the Lua side computes it inline.
- **`*.perf` rows:** `paint_kind="first"`, `picker_kind="go|bash"`, `panel="<name>"`, `total_ms`, `lua_ms`, `menu_ms`, `picker_ms`, `item_count`, `selected_index`. Do NOT emit `paint_kind="repaint"` — no consumer reads it and the noise hides real signal.

## Field names

Pick the name from the dictionary when one exists; coin a new field only when no existing one captures the meaning.

| Concept | Field |
|---|---|
| tmux session | `session_name` (not `session`, not `tmux_session`) |
| tmux window | `current_window_id` for the user's window, `window_id` for any other |
| pane id (tmux) | `pane_id` |
| pane id (WezTerm) | `wezterm_pane` |
| filesystem path | `cwd`, `worktree_root`, `repo_root`, `manifest_path` — full word, no abbreviations |
| count | `<noun>_count` (`item_count`, `pane_count`, `matched_process_count`) |
| duration | `duration_ms` — always ms, always integer |
| timestamp captured by writer | explicit unit suffix (`tick_ms`, `heartbeat_at_ms`) |
| picker variant | `picker_kind="go"` or `"bash"` |
| boolean | spell out: `osc_emitted="1"` not `emit="true"` — every value is a lib-quoted string |
| manifest hotkey id | `hotkey_id` (not `id`, not `key`) |
| latency kind | `kind="hotkey"` or `kind="status"` |
| configured slow threshold | `threshold_ms` |
| guest mem used % (slow latency only) | `mem_used_pct` |
| guest mem available MiB | `mem_avail_mib` |
| guest mem badge level | `mem_level` (`ok` / `warn` / `crit`) |
| guest swap used % | `swap_used_pct` |
| guest load average | `loadavg_1` / `loadavg_5` / `loadavg_15` |
| guest runnable / total procs | `proc_runnable` / `proc_total` |
| largest RSS consumer (when badge ≠ ok) | `top_comm` / `top_rss_mib` |

The dictionary is small on purpose. Before inventing a field, grep existing log lines for an analogous one.

## Key / status latency (Lua)

Cross-cutting input-feel observability lives in `wezterm-x/lua/latency.lua`:

| Event | Category | When it fires |
|---|---|---|
| Slow WezTerm-layer hotkey | `latency` · `message="slow key handler"` | handler `duration_ms >= hotkey_slow_ms` (default 50) |
| Slow `update-status` tick | `latency` · `message="slow status tick"` | tick `duration_ms >= status_slow_ms` (default 40) |
| Every sample | `latency.perf` | only when `diagnostics.wezterm.latency.emit_all = true` (or an explicit categories allowlist that includes `latency.perf`) |

Slow rows (and only slow rows) also attach guest pressure fields from `mem_guard.status_file` (`mem_used_pct`, `loadavg_*`, …) — see the field dictionary. Do **not** open that file on the under-threshold / `latency.perf` path.

Empty `diagnostics.wezterm.categories` still means "all **base** categories" for the logger, but `latency.lua` deliberately does **not** treat that as permission to flood `latency.perf` at 4 Hz — full sampling needs the explicit flag / allowlist entry above.

Threshold-gated `latency` rows are control-plane events (default-on). Do not log every status tick at info. Operator surface: [`diagnostics.md`](./diagnostics.md) "Key / status latency"; report script: `scripts/dev/latency-report.sh`.
