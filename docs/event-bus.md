# WezTerm Event Bus

Use this doc when you need to send a signal from somewhere (a hook, the
picker, a future helper) into the WezTerm Lua process — or when you
need to add a new event type to the unified bus.

## What problem the bus solves

WezTerm-bound signals come from several different runtime contexts:

- Claude Code hook scripts running in a regular tmux pane.
- The picker running inside `tmux display-popup -E` sub-pty.
- Future producers (browser-debug status push, agent-CLI watcher,
  external IPC helpers, …) running in arbitrary contexts.

Each context has different IPC capabilities. OSC 1337 SetUserVar is
the lowest-latency channel WezTerm accepts (sub-frame), but it only
works from contexts whose `/dev/tty` reaches WezTerm via tmux's DCS
pass-through. tmux popup sub-pty doesn't qualify (popup output is
treated as overlay screen data, not pane-output, and DCS-passthrough
isn't forwarded). `wezterm.exe cli` would seem like a fallback, but
[wezterm/wezterm#4456](https://github.com/wezterm/wezterm/issues/4456)
/ [#4439](https://github.com/wezterm/wezterm/issues/4439) /
[#4417](https://github.com/wezterm/wezterm/issues/4417) make
gui-sock-* discovery unreliable on WSL/Windows + tmux.

The bus hides this transport choice behind a single `send` API. Each
producer just calls `wezterm_event_send "<name>" "<payload>"` (or the
Go / Lua equivalent). Internally the bus picks OSC for contexts that
can reach the parent pty, file otherwise. WezTerm-side consumers
register handlers by name and never see the difference.

## Why event-driven, not polling

Transport routing is the obvious surface benefit, but it isn't the
main reason the bus exists. The deeper shift is **how WezTerm decides
when to reload state**.

Pre-bus, every state change in `attention.json` (and every other state
file) was discovered the same way: `update-status` ran every 250 ms,
re-read the file, and re-rendered if anything looked different. That's
a polling model — wezterm doesn't know whether anything has actually
changed, so the only way to be correct is to re-do the work on a fixed
cadence. The historical workaround was a single OSC user-var
(`attention_tick`) that hooks emitted to *prompt* an immediate reload.
Useful, but bespoke: every new state source needed its own ad-hoc
"please reload" channel, or accepted polling latency.

Post-bus, producers say *what* changed. Consumers register *what they
care about*. Routing happens by name, not by inventing a new channel
per concern. Two things follow:

- **Idle-time work disappears.** A consumer that subscribes to
  `chrome.debug.status` doesn't need to re-stat its state file every
  tick to see whether anything moved — the absence of an event is the
  signal that nothing did. Update-status's per-tick cost drops from
  "stat + read + parse + render" to "list event dir, find empty,
  return". Multiplied across all subscribed consumers, the savings
  compound.
- **Sub-frame paths become available.** When the producer happens to
  have a writable `/dev/tty` (any hook firing inside a regular tmux
  pane), the bus delivers the event via OSC and the consumer's
  handler runs in the same wezterm event-loop tick — not on the next
  250 ms `update-status`. For the same producer in a popup pty (no
  tty), the bus falls back to file and the latency floor goes back to
  ≤250 ms. The producer didn't change.

The 250 ms bound on file transport isn't going away — it's the
`status_update_interval` we already pay for, and dropping below it
would mean adding a dedicated wezterm-side timer per consumer. The win
is that **producers no longer have to design a custom IPC; they reuse
the same primitive every other event uses**. Adding a new event is
"register a handler + call send". Future events can be hot-pathed
(OSC) for free wherever the producer has tty.

## API

### Producer (bash)

```bash
. "$repo_root/scripts/runtime/wezterm-event-lib.sh"
wezterm_event_send "attention.tick" "$tick_ms"
wezterm_event_send "attention.jump" "v1|jump|<sid>|..."
```

### Producer (Go)

```go
transport, err := wezbusSend("attention.jump", payload)
// transport is "osc" or "file"; err is the underlying transport error
```

The `wezbus*` helpers live in `native/picker/wezbus.go` and have no
external dependencies — drop them into any Go binary that wants to
publish a wezterm event.

### Consumer (Lua)

```lua
local event_bus = load_module 'event_bus'
event_bus.configure { event_dir = constants.wezterm_event_bus.event_dir }

event_bus.on('attention.tick', function(payload, meta)
  -- meta = { transport = "osc" | "file", window, pane, ts?, raw_var?, path? }
  ...
end)
```

Multiple handlers per event name are supported — each fires in
registration order, errors caught by `pcall`.

`titles.lua` is currently the only consumer:
- a single `wezterm.on('user-var-changed', …)` delegates to
  `event_bus.dispatch_user_var(name, value, window, pane)`;
- `wezterm.on('update-status', …)` calls `event_bus.poll_files(window, pane)`
  every tick (250 ms cadence).

## Transport selection

Producer-side, in priority order:

1. `$WEZTERM_EVENT_TRANSPORT=osc|file` — explicit override. Used for
   manual diagnostics ("force file to test the slow path") and as the
   future migration switch when tmux/wezterm fix the popup OSC drop.
2. `$WEZTERM_EVENT_FORCE_FILE=1` — context flag. The picker wrapper
   (`tmux-attention-menu.sh`) injects this into the popup env, so the
   picker (Go or bash) doesn't have to second-guess transport.
3. `/dev/tty` writable — the cheapest reliable signal that the caller
   has a controlling terminal whose output stream tmux will pass
   through. Hooks fired from regular panes pass; `tmux run-shell -b`
   detached children and popup subprocesses fail, dropping to file.

The Lua consumer doesn't choose; it accepts both transports and
dispatches identically.

## Wire format

### OSC

WezTerm decodes `OSC 1337 SetUserVar=KEY=VALUE` where VALUE is base64.
The bus mangles event names to single-token user-var names: `.` → `_`,
prefixed with `we_`:

| event name | OSC user-var name |
|---|---|
| `attention.tick` | `we_attention_tick` |
| `attention.jump` | `we_attention_jump` |
| `chrome.debug.status` | `we_chrome_debug_status` |

Under tmux the OSC sequence is wrapped in `\x1bPtmux;<doubled-esc>\x1b\\`
so DCS pass-through delivers it to the parent wezterm pane (only when
the producer's `/dev/tty` is a regular pane — see Transport selection).

### File

Producers write `<state_dir>/state/wezterm-events/<event_name>.json`
via tmp + atomic rename. One file per event slot; multiple events
coexist in the directory.

Envelope schema:

```json
{
  "version": 1,
  "name":    "attention.jump",
  "payload": "v1|jump|<sid>|<wp>|<sock>|<win>|<pane>",
  "ts":      1777291876123
}
```

`payload` is an arbitrary string; nesting / structure is the event's
own concern (typically a versioned pipe-delimited tuple — see
`attention.jump`'s `v1|...` schema).

`ts` is epoch ms at write time. Consumers can use it to detect stale
events left over from a prior wezterm session.

WezTerm-side `event_bus.poll_files` runs on every `update-status`
tick (~250 ms). It enumerates the directory, reads + atomic-removes
every file, dispatches by basename. Files whose basename has no
registered handler are still removed so a stale schema doesn't
accumulate forever.

## Adding a new event

1. Pick a hierarchical name `<area>.<verb>[.<qualifier>]`
   (`[a-zA-Z0-9_.]` only; the OSC mangle replaces `.` with `_` so
   collisions there matter — `foo.bar_baz` and `foo_bar.baz` would
   collide on the wire, so don't mix `_` and `.` confusingly).
2. Define the payload schema. Lead with `v1|` so it can evolve. Pipe
   delimiters keep `=` and tmux socket paths intact.
3. On the producer side, call `wezterm_event_send` /
   `wezbusSend` from the relevant context. Don't pick a transport
   manually unless you have a specific reason.
4. On the wezterm side, register `event_bus.on('<name>', handler)` in
   `titles.lua` (or any module that wires up via `M.register(opts)`).
5. Update this doc's table below.

### Registered events

| name | producer | consumer | typical transport | latency |
|---|---|---|---|---|
| `attention.tick` | `scripts/runtime/agent-attention/emit.sh` (agent hooks) | `titles.lua` (refresh right-status counter) | OSC (hook runs in regular pane) | sub-frame |
| `attention.tick.echo` | `scripts/runtime/agent-attention/emit.sh` (sidecar to every OSC `attention.tick`) | `titles.lua` (log + fallback `reload_state` when the paired OSC tick is missing) | file (forced unconditionally) | 0–250 ms |
| `attention.jump` | `native/picker/cmd_attention.go` + `scripts/runtime/tmux-attention-picker.sh` (Alt+/ picker selection) | `titles.lua` (mux activate + spawn `attention-jump.sh --direct`) | file (forced via `WEZTERM_EVENT_FORCE_FILE=1`) | 0–250 ms |
| `link.quick_select` | `scripts/runtime/link-quick-select.sh` (`Ctrl+Shift+P` → Link: Open URL from viewport) | `titles.lua` (`window:perform_action(QuickSelectArgs…)` on the focused pane) | file (forced) | 0–250 ms |
| `tab.activate_visible` | `scripts/runtime/tab-overflow-dispatch.sh` (Alt+t pick of a live visible session) | `titles.lua` (foreground workspace + activate WezTerm tab) | file (forced) | 0–250 ms |
| `tab.activate_overflow` | `scripts/runtime/tab-overflow-attach.sh` / `tab-overflow-cold-spawn.sh` (after switch-client into overflow) | `titles.lua` (refresh overflow pane→session map + activate overflow tab) | file (forced) | 0–250 ms |
| `tab.spawn_overflow` | overflow cold-spawn fallback path when attach cannot complete the activation alone | `titles.lua` (spawn/ensure overflow tab then activate) | file (forced) | 0–250 ms |

`attention.tick.echo` is the **OSC-drop fallback + drop detector**. The
hook emits it via `wezterm_event_send_file` whenever the primary
`attention.tick` picked OSC, carrying the same `tick_ms` payload. The
Lua handler always logs receipt, and additionally calls `reload_state`
+ `refresh_right_status` when the corresponding OSC `tick_ms` was *not*
seen within the last ~30s — without this fallback, dropped OSC ticks
left the badge stuck on `running` until some unrelated session's next
tick happened to land.

Stop hooks in particular drop their OSC ticks reliably (claude-cli's
end-of-turn redraw appears to swallow the DCS sequence), so the echo
is the only signal that actually reaches Lua for most `done`
transitions.

Diagnostic signal: pair `tick received transport=osc value=$ms` against
`tick echo received transport=file value=$ms` in `wezterm.log` (both
keyed by the same `tick_ms`) to spot a lost OSC tick. Hook log present
+ echo received + tick missing means the loss is on the OSC pipeline
(hook tty write → tmux DCS pass-through → wezterm user-var dispatch);
the echo log line carries `osc_dropped=1 fallback_reload=1` on every
drop so the signal survives the new always-reload behavior. Once the
underlying root cause is fixed, the echo can be retired by removing
both the `wezterm_event_send_file "attention.tick.echo"` call in
`emit-agent-status.sh` and the `event_bus.on('attention.tick.echo',
...)` registration in `titles.lua`.

### Migration candidates

These signals already exist in the codebase but still drive themselves
through bespoke IPC or pure polling. Each is a candidate for moving
onto the bus when the area gets touched anyway — the bus doesn't make
them urgent, but it makes the eventual move cheap.

- **`chrome.debug.status`** — the right-status `CDP·…` segment is
  decided by `chrome_debug_status.lua` re-reading
  `state/chrome-debug/state.json` on every `update-status` tick. State
  changes arrive on a 0–250 ms random-phase delay, and the file is
  stat+read every tick whether or not anything moved. A bus migration
  has the host-helper publish `chrome.debug.status` after each state
  transition; Lua subscribes once. Idle-time stat goes away; sub-frame
  hot path opens when the producer has tty (it currently does not —
  host-helper is a Windows binary writing to a state file — but the
  bus contract works for it via the file transport without further
  changes). Producer-side touch lives in
  `native/host-helper/windows/src/HelperManager/`.
- **`vscode.helper.heartbeat`** — same pattern: helper writes
  `state.env`, Lua stats it for liveness on each tick. Migrating to
  `vscode.helper.heartbeat` events lets liveness become "did we get a
  heartbeat in the last N ms" (timer, no I/O) instead of "is the file
  mtime fresh enough" (per-tick stat). Same producer area.
- **`command-panel.refresh`** — currently no signal exists at all:
  the command palette rebuilds its contents on popup open, so manifest
  edits / worktree switches don't reflect in an already-open palette
  and only land on the next open. With the bus, any script that
  changes the command set (`wezterm-runtime-sync`, `worktree-task`
  switch, etc.) sends one event, the palette invalidates its in-memory
  cache. Pure new capability — there is no current equivalent to keep
  parity with.

The point of listing these here is to lock in design intent: when
someone next touches host-helper or the command palette, the
preferred move is "use the bus", not "invent another ad-hoc IPC". If
that's no longer the right call (e.g. the bus's worst-case 250 ms
becomes a problem for chrome.debug.status's 30 Hz updates), this
section is the place to record the decision and pick a different
mechanism explicitly.

## Diagnostics

- Producer side logs to `runtime.log`:
  - bash hook: `attention "hook emitted agent status" event_transport=...
    osc_emitted=... echo_emitted=... tick_ms=...` (`echo_emitted=1`
    when the OSC-drop sidecar was written).
  - go picker: `attention "event-bus dispatched" transport=osc|file`
  - bash picker: `attention "event-bus dispatched" transport=...`
- Consumer side logs to `wezterm.log`:
  - `attention "tick received" transport=osc latency_ms=... value=$ms`
  - `attention "tick echo received" transport=file latency_ms=... value=$ms osc_dropped=0|1 fallback_reload=0|1`
    (sidecar; pair with `tick received` by matching `value=`.
    `osc_dropped=1` flags a missing primary OSC tick — that path also
    triggered a fallback reload so the badge stays current).
  - `attention "jump dispatched" transport=file activated=...`
  - `event_bus "event with no handler" name=... transport=...` when an
    event arrives that no module subscribed to.
  - `event_bus "envelope unparseable" path=...` when a file event has
    a malformed `{"version":...,"payload":"..."}` body.

Pair runtime.log + wezterm.log via `trace_id` (set in
`WEZTERM_RUNTIME_TRACE_ID`) to walk a single press end-to-end.

## When upstream fixes the popup OSC drop

If a future tmux release forwards DCS pass-through from `display-popup`
sub-pty to the parent client tty, switching the picker back to OSC is a
one-liner: drop the `WEZTERM_EVENT_FORCE_FILE=1` injection from
`tmux-attention-menu.sh`'s `picker_command` env. Layer ③ then picks
OSC because the popup pty is writable, all callers transparently
upgrade, no schema or handler changes needed.

If `wezterm.exe cli` ever becomes reliable across WSL/Windows + tmux
on every `gui-sock-*` permutation, that opens a third transport option
(`cli` for callers without a tty at all). It would slot in as another
branch in `wezterm_event_pick_transport`.
