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
| `attention.tick` | `scripts/claude-hooks/emit-agent-status.sh` (Claude hooks) | `titles.lua` (refresh right-status counter) | OSC (hook runs in regular pane) | sub-frame |
| `attention.jump` | `native/picker/cmd_attention.go` + `scripts/runtime/tmux-attention-picker.sh` (Alt+/ picker selection) | `titles.lua` (mux activate + spawn `attention-jump.sh --direct`) | file (forced via `WEZTERM_EVENT_FORCE_FILE=1`) | 0–250 ms |

## Diagnostics

- Producer side logs to `runtime.log`:
  - bash hook: `attention "hook emitted agent status" event_transport=...`
  - go picker: `attention "event-bus dispatched" transport=osc|file`
  - bash picker: `attention "event-bus dispatched" transport=...`
- Consumer side logs to `wezterm.log`:
  - `attention "tick received" transport=osc latency_ms=...`
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
