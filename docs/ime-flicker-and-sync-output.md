# IME Candidate-Window Flicker and Synchronized Output

This doc captures the investigation that led to two of this repository's
load-bearing decisions:

- `tmux.conf` declares `terminal-features ',xterm*:sync,wezterm*:sync'`.
- `scripts/runtime/tmux-version-lib.sh` enforces a tmux 3.6+ floor.

It explains the symptom, the layers involved, every hypothesis tried,
which ones were rejected, and how to verify the fix on a fresh
machine. Read this when:

- A new contributor asks why this repo requires tmux 3.6+.
- A future agent CLI shows the same flicker — to see which knobs to
  re-validate.
- The terminal stack changes (wezterm, tmux, Claude Code) and someone
  wonders whether parts of this can be relaxed.

## Symptom

While typing Chinese (or any IME-driven language) in Claude Code, or
similar agent CLIs running inside tmux + wezterm, the IME candidate
window occasionally jumps to a different on-screen position for a
single frame and snaps back. Frequency: roughly one jump every few
hundred frames during streaming output. Static UIs do not trigger it.

The jump target is **not** random — it lands on the row where the
renderer happened to leave the terminal cursor the moment wezterm took
its repaint snapshot.

## The systems involved

```
Claude Code (Anthropic differential renderer, post-Ink)
   │  emits BSU/ESU around frames if em() probe says outer term supports Sync
   ↓
tmux  (passes mode 2026 to outer terminal when 'sync' feature declared)
   │  3.6+ adds a 1-second ESU flush timeout
   ↓
wezterm (terminal emulator, batches paint during sync window)
   │  set_text_cursor_position fires per repaint frame
   ↓
Windows IMM
   • ImmSetCandidateWindow positions the candidate popup at the
     pixel coordinate wezterm hands it
   • The popup follows whatever cursor position wezterm's last
     paint frame happened to capture
```

Five bullets that are easy to get wrong:

1. **Claude Code dropped Ink in v2.0.10 (October 2025).** The current
   renderer is Anthropic-owned. References to Ink behavior (full
   `eraseLines` redraw, hide-cursor markers around frames) describe
   pre-v2.0.10 builds and most other Ink-based CLIs (Codex CLI, Gemini
   CLI, etc.).
2. **The differential renderer's writes are not byte-fragmented.** A
   single frame is one or a handful of compact writes. PTY-level
   coalescing (`mux_output_parser_coalesce_delay_ms`) has nothing to
   merge.
3. **wezterm reports IME position per GUI repaint frame, not per
   byte-stream cursor move.** `wezterm-gui/src/termwindow/mod.rs:2112`
   (`update_text_cursor`) is the single GUI-side call site. It reads
   the cursor position once per paint and pushes it into the platform
   IME path.
4. **wezterm's IME path does not gate on synchronized-output state.**
   `set_text_cursor_position` (and its platform implementations:
   `ImmSetCandidateWindow` on Windows, `set_cursor_rectangle` on
   Wayland, `invalidateCharacterCoordinates` on macOS,
   `update_ime_position` on X11) fires whenever a paint cycle runs,
   independent of whether the terminal state is mid-sync. With
   atomic frame batching at the GUI level, the per-paint IME update
   naturally observes only the final cursor position — but only if
   the surrounding paint is actually atomic.
5. **Claude Code's `skipSyncMarkers()` gates BSU/ESU emission on the
   outer terminal advertising Sync.** Inside the binary:
   ```js
   skipSyncMarkers() {
     if (!this.options.stdout.isTTY) return true;
     if (!em()) return true;            // probes outer term Sync capability
     if (!this.unsubscribeTTYHandlers) return true;
     return false;
   }
   ```
   `em()` queries terminfo / XTGETTCAP. If the chain (tmux → wezterm)
   fails to declare Sync, Claude silently strips its BSU/ESU markers.

## Investigation timeline

Order matters because each step's failure pointed at the next layer.

### Step 1 — first hypothesis: Ink's full-redraw walks the cursor

Ink (the React-for-terminal library Claude Code originally used)
re-renders by emitting `CSI 1A` + `CSI 2K` for every line of the UI
and rewriting the buffer. During that walk the cursor passes through
every row. If a wezterm GUI paint frame catches the cursor mid-walk,
IME jumps.

**Status:** correct for old Ink-based CLIs. Not the cause for
post-v2.0.10 Claude Code, which uses targeted-cell writes instead of
walking the whole UI height.

### Step 2 — workaround attempt: widen wezterm's PTY coalesce window

`mux_output_parser_coalesce_delay_ms` (default 3 ms) defers
processing a partial PTY read in the hope more bytes arrive within
the window. Bumping it to 8 ms was supposed to make a full diff
update collapse into one paint cycle.

**Result:** no measurable improvement.

**Why it failed:** the Anthropic renderer doesn't fragment writes
byte-by-byte. A frame is one or two `write(2)` calls. Coalescing has
nothing to merge.

### Step 3 — root-cause discovery: synchronized output is the right protocol

Reading the Claude Code binary turned up `\x1B[?2026h` and
`\x1B[?2026l` literals plus the `skipSyncMarkers()` gate quoted
above. Reading wezterm's source via DeepWiki confirmed:

- wezterm parses DEC mode 2026 (`SynchronizedOutput`) in
  `term/src/terminalstate/mod.rs` and batches GUI paints in the mux
  layer.
- IME position update path (`update_text_cursor` →
  `set_text_cursor_position` → platform IME call) runs per paint
  frame, so atomic paint batching naturally produces atomic IME
  updates.

So the missing piece is **getting BSU/ESU through the chain** from
Claude → tmux → wezterm.

### Step 4 — first attempt at the proper fix (on tmux 3.4)

```tmux
set -as terminal-features ',xterm*:sync,wezterm*:sync'
```

Goal: tmux declares Sync to inner apps, Claude's `em()` returns true,
Claude emits BSU/ESU, the chain batches paint atomically.

**Result:** worse regression — UI froze between keystrokes,
refreshing only on input events.

### Step 5 — why tmux 3.4 broke even though it shouldn't have

The empirical fact is unambiguous: identical `terminal-features` line
freezes the UI on tmux 3.4 and works cleanly on tmux 3.6. The
underlying mechanism, verified against tmux source via DeepWiki:

| | tmux 3.4 | tmux 3.6 |
|---|---|---|
| Recognizes DEC mode 2026 in inner app output | No | Yes |
| Buffers between BSU and ESU on its own | No | Yes (1s flush timeout) |
| Forwards BSU/ESU markers to outer terminal when `sync` feature is set | Yes (as unknown CSI passthrough) | Yes (as part of its own paint) |

So the practical difference is: **on 3.4 nothing in the path knows
how to terminate a stalled sync window.** wezterm receives
`?2026h`, enters sync, batches paint, and waits for `?2026l` to
arrive. If anything in the chain — the inner app's render scheduling,
tmux's parser-roundtrip output, a write split across syscalls —
delays or perturbs the pairing, wezterm sits forever. Idle React
commits don't fire a fresh frame to push the missing ESU. The screen
stalls until a key event triggers a render and naturally re-pairs.

**On 3.6 tmux itself becomes the sync barrier.** Inner-app
BSU/ESU is parsed and used to drive tmux's internal output
batching; tmux emits its own BSU/ESU to the outer terminal around
each batched flush. Crucially, tmux's batch flushes either when ESU
is observed *or after 1 second of unflushed buffering*, so a stuck
inner-app sync state cannot freeze the outer pipeline. Excerpt from
`tmux 3.6` release notes:

> When an application enables synchronized output (ESC[?2026h), tmux
> now defers flushing pane output until the application disables it
> (ESC[?2026l) **or a 1 second timeout expires**.

That 1-second timeout is the safety net. Without it, the same
configuration that works on 3.6 deadlocks on 3.4.

Ubuntu 24.04 LTS still ships tmux 3.4 (`apt-cache policy tmux` →
`3.4-1ubuntu0.1`). LTS won't backport 3.6, so production setups need
an out-of-band install.

### Step 6 — the fix that stuck

1. Build tmux 3.6a from source, install to `/usr/local/bin/tmux`
   (shadowing apt's 3.4).
2. `tmux kill-server` and start fresh so the running server is the
   3.6a binary.
3. Re-add `set -as terminal-features ',xterm*:sync,wezterm*:sync'`
   in tmux.conf.
4. Confirm via `tmux info | grep Sync` — should show
   `\033[?2026%?...`, not `[missing]`.
5. Start a new Claude Code process so its `em()` probe runs against
   the now-Sync-aware tmux. Resume an existing session via
   `claude --resume` if you want to keep transcript context — resume
   is a fresh Node process, em() re-probes.

Verified: no IME flicker, no idle freeze, mouse wheel still works.

## Failure modes considered (and why they were rejected)

| Approach | Why rejected |
|---|---|
| `mux_output_parser_coalesce_delay_ms = 8` | Writes are not byte-fragmented; coalescing has nothing to merge. |
| `CLAUDE_CODE_NO_FLICKER=1` (alone) | Loses tmux native click-and-drag selection (alt-screen + mouse capture take over). Worth knowing: this *would* also fix the unrelated scrollback-pollution symptom tracked under "Claude Code scrollback frame leak" below — but the rejection here stands on the mouse-selection regression alone. |
| `CLAUDE_CODE_NO_FLICKER=1 + CLAUDE_CODE_DISABLE_MOUSE=1` | Restores tmux selection but loses mouse-wheel scroll inside Claude. Shift+Up extends selection only when an active mouse selection exists, which DISABLE_MOUSE turns off. Plus [claude-code#42821] — `=1` swallows `Ctrl+J` (chat:newline). UX trade-offs unacceptable. See "Claude Code scrollback frame leak" below for why we still don't reach for this even though it's the only knob that addresses both flicker *and* the scrollback dup. |
| Wezterm-side: gate `update_text_cursor` on cursor visibility | Claude's renderer does not emit `CSI ?25l/h` around per-frame redraws (those markers are only emitted entering/exiting alt-screen). The hook would fire too rarely to matter. |
| Wezterm-side: gate IME path on sync state | Equivalent to what we get for free once paint batching works during BSU/ESU. Worth filing upstream as defense-in-depth, but not required to fix the symptom once tmux 3.6+ is in place. |
| Build a wezterm IME-debounce knob | Not needed once the protocol-level path works. |

## What's wired up in this repo

- `tmux.conf:24-30` — declare Sync feature with explanatory comment.
- `scripts/runtime/tmux-version-lib.sh` — shared helper:
  `tmux_version_current`, `tmux_version_at_least`,
  `tmux_version_ensure_supported` (warns at < 3.6).
- `scripts/runtime/open-default-shell-session.sh` and
  `scripts/runtime/open-project-session.sh` — both source
  `tmux-version-lib.sh` and call `tmux_version_ensure_supported`
  before launching tmux.
- `docs/setup.md` — prereq line documents the 3.6+ requirement.

## Verification recipe

Run this after touching anything in the chain (terminal upgrade,
tmux upgrade, wezterm config change, Claude Code upgrade):

```sh
# 1. Versions
tmux -V                          # expect 3.6 or higher
ls -l /proc/$(pgrep -of tmux)/exe  # expect /usr/local/bin/tmux (the 3.6+ build)
claude --version                 # any v2.0.10+ has the differential renderer

# 2. tmux declares Sync to clients
tmux info | grep Sync
# expect: \033[?2026%?%p1%{1}%-%tl%eh%;
# if [missing]: detach + reattach (or restart server) so client refreshes caps

# 3. tmux's terminal-features list contains the sync entries
tmux show-options -g terminal-features | grep sync
# expect: xterm*:sync and wezterm*:sync (one occurrence each is enough)

# 4. Live test
#   - Start a new Claude Code session (em() probes at startup)
#   - Stream a long response while typing Chinese in the input box
#   - Watch the candidate window: should not jump
#   - Stop typing mid-stream: UI should keep updating, not freeze
#   - Mouse wheel should scroll tmux copy-mode normally
```

If any of these fail, work backwards through the chain.

## Open upstream items

- **tmux 3.6 backport to Ubuntu LTS.** Until distros ship 3.6+ by
  default, every host needs an out-of-band install. `apt-cache policy
  tmux` on Ubuntu 24.04 still shows 3.4-1ubuntu0.1 as of 2026-04.
- **wezterm IME-aware sync gating.** Currently
  `wezterm-gui/src/termwindow/mod.rs:2112` calls
  `set_text_cursor_position` per paint frame regardless of sync
  state. Paint batching during BSU/ESU is enough for our case, but
  filing a PR to make the IME path explicitly sync-aware would close
  the window where a third-party renderer using BSU/ESU more
  aggressively could still surface jitter. Tracked externally as
  [wezterm#7465] (sync-output flicker, open) and adjacent issues.
- **Claude Code default-mode renderer flicker rate.** Anthropic
  reports ~85% reduction vs. earlier builds. The remaining ~15% are
  short panes and cursor-bursts on tool-output expansion; no action
  on our side.
- **Claude Code scrollback frame leak.** In default (non-alt-screen)
  rendering, every full-redraw event leaves the previous frame in
  scrollback instead of clearing it. Triggers observed in this repo:
  SIGWINCH (terminal / tmux pane resize), output exceeding the
  visible viewport during streaming, tool-output expansion, long
  markdown tables; users on adjacent issues also report dup with no
  obvious trigger. Symptom: scrolling up in tmux copy-mode (or in
  wezterm scrollback) shows the same conversation block 2–25× over,
  with the input box / status banner wedged between repeats.

  Tracked upstream as [claude-code#49086] (canonical, "per-frame
  redraw leak"); duplicates [claude-code#46462],
  [claude-code#49057], [claude-code#15476]; reverse-symptom
  ([claude-code#41965], `NO_FLICKER` *erasing* scrollback) and
  side-effect ([claude-code#42821], `NO_FLICKER=1` swallows
  `Ctrl+J`) live on the same renderer.

  Status as of 2026-04-27: the `claude` bot account commented on
  #49086 "fixed as of 2.1.116" — verifiably untrue; users on
  v2.1.116 / v2.1.118 / v2.1.119 (macOS, Linux, Windows, VS Code
  terminal) all report the symptom unchanged. No Anthropic engineer
  has re-engaged, no fix PR, no timeline.

  No action on our side. The only Anthropic-supplied workaround is
  `CLAUDE_CODE_NO_FLICKER=1` (force alt-screen), which does kill the
  scrollback dup, but the rejection table above documents why we
  refuse it: tmux mouse-selection regression (with `=1` alone) and
  Ctrl+J / mouse-wheel regressions (with `=1 + DISABLE_MOUSE=1`).
  Users hitting this should `exit` + resume the session as a one-off
  cleanup; do not advise the env knob without re-checking these
  upstream issues for a real fix.

## Adjacent issues (for future research)

- [claude-code#37283] — TUI flickers/cursor jumps in tmux during
  streaming output (open). Closest match to the original symptom.
- [claude-code#6342] — Chinese IME candidate window not following
  cursor (closed, not planned). The macOS variant of the same root
  cause.
- [wezterm#7465] — Flicker when using CSI 2026 synchronization
  (open). Wayland/Mutter case, not directly the IME path but proves
  the sync-output corner cases are not fully landed.
- [wezterm#5560] — Text cursor flickers and jumps around terminal
  (open). Same family — wezterm reports cursor changes downstream
  without batching.
- [wezterm#2569] — IME preedit on all pane cursors
  (fixed-in-nightly). Adjacent IME bug, separate root cause.
- [tmux#4744] — Synchronized output passthrough (merged into 3.6).
- [Anthropic blog post] / HN thread by chrislloyd — high-level
  context on Claude Code's renderer rewrite and the upstream sync
  patches.

[claude-code#37283]: https://github.com/anthropics/claude-code/issues/37283
[claude-code#6342]: https://github.com/anthropics/claude-code/issues/6342
[claude-code#49086]: https://github.com/anthropics/claude-code/issues/49086
[claude-code#46462]: https://github.com/anthropics/claude-code/issues/46462
[claude-code#49057]: https://github.com/anthropics/claude-code/issues/49057
[claude-code#15476]: https://github.com/anthropics/claude-code/issues/15476
[claude-code#41965]: https://github.com/anthropics/claude-code/issues/41965
[claude-code#42821]: https://github.com/anthropics/claude-code/issues/42821
[wezterm#7465]: https://github.com/wezterm/wezterm/issues/7465
[wezterm#5560]: https://github.com/wezterm/wezterm/issues/5560
[wezterm#2569]: https://github.com/wezterm/wezterm/issues/2569
[tmux#4744]: https://github.com/tmux/tmux/pull/4744
[Anthropic blog post]: https://code.claude.com/docs/en/fullscreen
