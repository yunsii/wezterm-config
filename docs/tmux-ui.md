# Tmux UI

Use this doc when you need visible UI behavior for tabs, panes, or status lines.

## Tab Behavior

- The native Windows title bar stays hidden.
- The tab bar uses the non-fancy style and remains visible at the bottom.
- The tab bar uses padded labels and stronger background highlighting for hover and active tabs rather than explicit separator characters.
- The left side of the tab bar shows the current workspace as a tinted badge that sits flush against the tab strip.
- Managed project tabs use stable project directory names as titles.
- If a managed tab has multiple panes, the title prefers a short summary such as `project +1`.
- Unmanaged tabs fall back to working-directory-based title inference.

## Tmux Behavior

- tmux status follows the active pane working directory.
- `default` stays the built-in WezTerm workspace at the top level, but in `hybrid-wsl` its WSL tabs start inside a lightweight tmux session.
- Managed workspace creation only requires `default_domain` in `hybrid-wsl` mode.
- Managed tmux flows do not require shell rc `OSC 7` integration; tmux status and tmux-owned shortcuts resolve cwd from tmux's own `pane_current_path`.
- In tmux-backed panes, navigation actions such as VS Code open and worktree switching resolve through tmux first, including copy-mode and scrollback.
- `Ctrl+Shift+P` opens a centered tmux popup command palette whenever the current pane is running tmux.
- tmux refresh (respawn) is command-palette-owned instead of WezTerm-shortcut-owned. The lighter **layout fix** (`scripts/runtime/tmux-fix-layout.sh`) runs `refresh-client -S`, rebalances with `even-horizontal`, clamps multi-line `status` to ≤3 lines, and forces a status recompute. Triggers: manual `Ctrl+k r` / palette `Session: Fix layout`; **automatic** (debounced ~200 ms, min interval 500 ms) on WezTerm `window-resized` and after `Ctrl+-` / `Ctrl+=` / `Ctrl+0` font zoom (`wezterm-x/lua/layout_heal.lua`). It does not respawn panes. Palette `Session: Refresh current window` still respawns the focused pane and runs the same heal first.
- `Ctrl+k` is a tmux chord prefix for memorized low-latency actions such as `Ctrl+k v` for vertical split, `Ctrl+k h` for horizontal split, and `Ctrl+k r` for layout fix.
- After `Ctrl+k`, tmux temporarily replaces one status line with a generic waiting hint.
- The Go popup pickers share one selected-row treatment: the focused row gets a full-width warm ANSI 255 background bar plus a leading `▶` caret so row focus is visible without overloading any per-row marker. The `Alt+x` cross-workspace session picker additionally bolds the selected session label; the `Alt+g` worktree picker, `Ctrl+Shift+P` command palette, `Alt+/` agent-attention overlay, and links picker use the same background bar. (The `Alt+j` / `Alt+k` / `Alt+l` attention jumps are direct — they cycle panes without opening a picker, so they have no selected-row surface.) Inner per-cell colors are restored with a background-preserving SGR (`\x1b[22;23;24;27;39m`) rather than a full reset so the bar stays continuous to the end of the line. The bash fallback pickers (used only when the Go binary is unavailable) keep the caret-only look.
- Live TUI popups are a poor fit for mouse text selection (plain drag is unbound; `Shift+drag` enters copy-mode against a redrawing TUI; `Super+drag` is awkward on Windows). Pickers that expose a copyable payload therefore ship a keyboard copy that does **not** rely on OSC/DCS pass-through: tmux `display-popup -E` does not forward those sequences to the parent WezTerm client (same constraint as the attention picker's file event-bus). `Ctrl+y` in the links picker copies the URL via `Set-Clipboard`; in the `Alt+g` worktree picker `Ctrl+y` copies the focused path and `Ctrl+b` copies the branch name via `agent-clipboard.sh` (Windows host helper). The worktree picker paints `path · branch` on a detail line under the title so both payloads are visible before copy (plus ` · <reason>` when the focused worktree has agent-attention state).
- The `Alt+g` worktree picker carries a trailing status column: worktree label + `[branch]` is padded to a common width (measured over every row, not just the visible window, so scrolling does not shift the column) and the cell shows `▲ 2m` / `● 12s` / `✓ 30s` for a live agent entry, a dim age (`3h` / `2d`) when there is no tmux window (last user visit, else directory birth/mtime), and nothing when there is a window with no pending agent state — same "nothing pending" meaning as a tab with no badge. The visit/sort clock is user interact + access ledger + dir birth/mtime — **not** agent hooks (hooks only feed the live ▲/●/✓ badges). The old `(new)` window hint and dimmed `last ✓` archive form were dropped; see [`agent-attention.md`](./agent-attention.md). Glyph vocabulary for live attention matches `Alt+/` on purpose; the tab strip is the one surface that drops the glyph for a color block. The dim runs restore with the background-preserving SGR so the selected-row bar stays continuous.
- Copy and paste are intentionally split by layer: tmux owns pane-local text selection and copy, while WezTerm owns the smart system clipboard paste path.
- tmux explicitly uses `set-clipboard external`, so copying from tmux copy-mode writes to the system clipboard through OSC 52.
- Outside tmux copy-mode, plain left clicks always `select-pane`. When `alternate_on` or `mouse_any_flag` is set, the same click is also `send-keys -M` so mouse-aware TUIs (Grok follow ▼, Vim `mouse=a`, …) receive it — stock tmux does this via `mouse_any_flag`; an older select-pane-only bind made Grok's ▼ look dead while a macOS box without that override still worked.
- Outside tmux copy-mode, plain left drag does not start any selection path. `Shift+drag` starts tmux pane-local selection in normal (non-alternate) panes; when the pane is on the alternate screen (vim and similar), `Shift+drag` is forwarded to the application so selection stays in one layer instead of jumping into copy-mode.
- Wheel scrolling may move tmux into its copy-mode-backed scrollback state, and tmux selects the pane under the mouse before entering that state.
- Copy-mode entry and exit via directional inputs follow a single symmetric rule: the first press at a boundary only switches mode without scrolling. Upward keys (`PageUp`, `Shift+Up`, wheel-up) entering from the live prompt do not jump, and downward inputs (`PageDown`, `Shift+Down`, wheel-down) at the live bottom exit copy-mode on a single press rather than auto-exiting mid-scroll.
- While a pane is in copy-mode, tmux 3.7+'s `refresh-from-pane` is run automatically every `@copy_mode_auto_refresh_interval_ms` milliseconds (default `1000`) so streaming agent output is periodically flushed into the backing grid without leaving copy-mode. The automatic loop refreshes while copy-mode is within `@copy_mode_auto_refresh_prefetch_screens` screens of the live bottom (default `3`), like a bottom-side prefetch window; farther back, it pauses so older viewport positions do not jump forward as new output pushes history past `history-limit`. It also pauses when `history_size` is within `@copy_mode_auto_refresh_history_guard_lines` lines of `history-limit` (default `200`). Because `refresh-from-pane` clears tmux's active selection, automatic refresh pauses while `selection_present=1`; manual `r` also skips refresh during an active selection. The loop also pauses while `@wezterm_popup_active=1` (boolean, set by `scripts/runtime/tmux-display-popup.sh` for the overlay lifetime): refreshing the underlying grid during a popup races tmux's client composite and garbles double-width CJK cells into the overlay. The flag is **server-global** — one reminder popup pauses auto-refresh on every pane for a few seconds (intentional, cheap). Concurrent popups are not refcounted; last closer clears. A hard-killed wrapper can leave the flag stuck (`tmux set -gu @wezterm_popup_active` clears it). Set `@copy_mode_auto_refresh` to `0` to disable the loop.
- Runtime popup opens must go through `scripts/runtime/tmux-display-popup.sh` (not bare `tmux display-popup`, except `-C` close). That is a cooperative contract enforced by `scripts/dev/check-display-popup-guard.sh`. Separate from this: command palette still uses its own `popup-open.flag` for the WezTerm second-press toggle — different reader, different lifecycle. Popup chrome uses a solid cream fill (`popup-style` / `popup-border-style` from `render-tmux-appearance.sh`) even under the frosted preset, so empty overlay cells never show the underlying pane through.
- The `WheelUpPane` guard is `alternate_on || pane_in_mode` and intentionally omits `mouse_any_flag`. TUIs that enable mouse tracking but do not implement wheel scrolling (notably `claude-cli` and similar AI CLIs) would otherwise silently swallow the wheel. The trade-off is that `alternate_on=0` TUIs such as `fzf` or `lazygit` also yield their wheel handling to tmux scrollback inside a tmux pane.
- Releasing the mouse after a drag does not auto-copy or auto-cancel.
- `Ctrl+c` is uniform inside tmux copy-mode: when a selection is present it copies without leaving copy-mode; without a selection it cancels copy-mode.
- This config does not expose a normal WezTerm cross-pane drag-selection path by default; terminal-wide selection is still available when you hold `SUPER`.
- `Ctrl+c` first checks for a WezTerm terminal selection and copies it if one exists; otherwise it sends a normal terminal `Ctrl+c`.
- tmux emits terminal focus-in and focus-out events to applications, which helps mouse-aware TUIs recover cleanly when the WezTerm window regains focus.
- Pane and status backgrounds are driven by the active appearance preset (`WEZTERM_APPEARANCE_PRESET`), not hardcoded in `tmux.conf`: `render-tmux-appearance.sh` regenerates `wezterm-x/tmux/appearance.generated.conf` (sourced via `source-file -Fq`) during sync. The `opaque` preset uses cream/dim-cream backgrounds; the `frosted` preset sets `status-style` / `window-style` / `window-active-style` all to `bg=default` so cells inherit WezTerm's window transparency + acrylic (the focused pane is then told apart by border color, not body tint). Giving any of those an explicit `bg=<hex>` paints cells opaque and hides window transparency. Full model: [`appearance-presets.md`](./appearance-presets.md).
- ANSI 256-color index 255 is remapped to `#dedcd0` via `colors.indexed` in `wezterm-x/lua/ui.lua` (sourced from `palette.indexed` in `constants.lua`). Claude Code's scrollback renderer paints user-message backgrounds with `\e[48;5;255m`, and the default xterm value (`#eeeeee`) is too close to the cream pane background to read clearly. The remap is applied to the wezterm color scheme rather than a Claude theme override because Claude Code's `userMessageBackground` token only takes effect in fullscreen rendering mode; in scrollback mode the only point of intervention is the terminal palette.
- Managed agent panes show a single dim-cyan `Loading <agent> ...` line while the agent boots, printed by `scripts/runtime/agent-launcher.sh` right before it execs the CLI. The agent's first paint clears the screen, so the cue is only visible while it's actually useful — covering the multi-second `claude --continue` / `codex resume --last` session-load window where the pane would otherwise stay blank. The shell-chain forks before the launcher (~130ms, dominated by `zsh -ilc` to inherit the interactive PATH) are intentionally kept: the post-agent fallback shell (Ctrl+D / agent crash) execs the same login shell on the same tty, so it pays the equivalent zshrc cost regardless — splitting the env across `~/.zshrc` and `~/.config/shell-env.d/` to shave that 130ms would desync interactive-shell behavior for no perceptual win. Disable the cue with `WEZTERM_NO_LOADING_BANNER=1`.

## Vim in tmux

Terminal Vim inside this stack is a frequent source of “scroll jitter” reports. Most of them are **not** a tmux↔Vim incompatibility; they are Vim display/scroll semantics amplified by long lines and by which layer owns `Shift+drag`. Repo-side mouse policy lives in `tmux.conf`; editor options live in the user’s `~/.vim/vimrc` (template: [`wezterm-x/local.example/vimrc.recommended`](../wezterm-x/local.example/vimrc.recommended)). Install notes for Vim 9.2+: [`setup.md`](./setup.md#vim-92-optional).

### Symptoms and causes

| What you see | Cause | Fix layer |
| --- | --- | --- |
| Screen full of `@` rows; scroll feels like skipping a whole page | A wrapped line does not fit the window and `'display'` lacks `lastline`, so Vim fills with `@`. Without `'smoothscroll'`, scroll steps by **logical** lines — one SOPS `.enc` line can be 10k+ chars. | User vimrc: `set display+=lastline` and `set smoothscroll` (Vim 9+) |
| Tear / flash *within* a redraw | Vim 9.1 and older have no `'termsync'`. Vim 9.2+ supports DEC 2026, but auto-probe only enables it for some DA2 ids (kitty / foot / iTerm2). **tmux answers DA2 `>84;…`**, so Vim never sends DECRQM and stays on `notermsync` unless helped. | Vim ≥ 9.2 + vimrc DECRPM inject (see template); tmux already advertises `sync` ([`ime-flicker-and-sync-output.md`](./ime-flicker-and-sync-output.md)) |
| Remaining “frame jump” after termsync | `'termsync'` batches *one* redraw; each scroll still replaces the screen. Cursor/status updates can sit outside BSU/ESU. | Expectation: less tearing, not frozen smooth scrolling. Prefer `Ctrl-D`/`Ctrl-U` over a fast wheel for fewer frames. |
| `Shift+drag` in Vim jumps into a frozen grid | Previously root `S-MouseDrag1Pane` always ran `copy-mode -M`, stealing the gesture before Vim saw it. | **Repo:** when `alternate_on`, forward with `send-keys -M`; otherwise keep tmux pane-local selection ([keybindings](./keybindings.md)) |

Changing Vim keymaps alone cannot fix `Shift+drag` ownership — tmux binds the gesture first.

### Selection cheat sheet

- **Inside Vim (alternate screen):** plain drag or `Shift+drag` → Vim (`mouse=a`); or `v` / `V`.
- **Normal shell pane:** `Shift+drag` → tmux copy-mode; plain drag does not start tmux selection.
- **Terminal-wide:** `Super+drag` (WezTerm).

### Verify

```vim
:version          " prefer 9.2+ with termsync support
:set termsync?    " expect:  termsync  (after the DECRPM inject)
:set display?     " expect:  …lastline…
:set smoothscroll?
```

```sh
tmux list-keys -T root | grep S-MouseDrag1Pane
# expect: if-shell … alternate_on … send-keys -M … copy-mode -M
```

## Agent Attention

The agent-attention pipeline (state file, hook install, transitions, rendering, the `Alt+j` / `Alt+k` / `Alt+l` / `Alt+/` keyboard entry points, focus-based auto-ack, Codex integration) lives in [`agent-attention.md`](./agent-attention.md).

In tmux UI terms what shows up here is: a per-tab badge (an unfocused tab filled amber / blue / green for waiting / running / done; the focused tab keeps its own colors — priority is focused > status > hover > inactive. Focus / waiting / done / running hexes are Tailwind-first (`cyan-500`, `amber-200`, `green-200`, `sky-200`) — see the palette policy in [`agent-attention.md`](./agent-attention.md). Recoloring adds no width, so the strip never re-flows when a status appears or clears) and the right-status `▲ N waiting  ✓ N done  ● N running` counter, both rendered by `wezterm-x/lua/attention.lua` from the shared state file. The tab badge stays color-only because the tab strip is dense and one status per tab needs no shape cue; the right-status counter and the `Alt+/` picker keep a per-status glyph because they list several statuses side by side, where color alone would not separate them. The glyphs are monochrome 1-cell text code points rather than color emoji (swapped 2026-08-19): the rest of the bar is typographic (`CDP·…`, `D·151G`, `M·88%`) and the emoji set read as a foreign body next to it. The counter slot is reserved even at zero so the bar width stays stable.

## Status Lines

- The first tmux line renders repo, branch, combined git change counts, tracked-branch sync markers, and Node.js version.
- The git-changes group reads `(+S,~U,?T,<sync>)` where `S` is staged, `U` is unstaged, `T` is untracked, and `<sync>` is one of: `=0` (synced with upstream), `^N` (ahead by N), `vN` (behind by N), `*0` (no upstream — local-only branch never pushed).
- The second tmux line renders the repo family's linked worktree count plus the current worktree role, for example `linked:2 · primary`.
- The worktree line derives its repo family and current role from the active pane's live git state instead of stored tmux metadata.
- The third tmux line renders whenever the WakaTime toggle is enabled.
- Any enabled status section keeps a stable on-screen slot. If live data is unavailable, that section renders placeholder text instead of disappearing.
- A section only disappears completely when its toggle is disabled. If an entire line has no enabled sections, that line does not reserve a status row.
- Node.js version lookup falls back to `~/.local/share/fnm/aliases/default/bin` when `node` is not already on `$PATH` (this is the path `fnm` populates from its `default` alias). The resolved version is cached.
- WakaTime refresh is cache-backed and reuses summary data for up to 60 seconds.

## Notes

- `default` is not managed by `workspaces.lua`; it remains WezTerm's built-in workspace even though `hybrid-wsl` now boots its WSL tabs through a lightweight tmux session.
- `Alt+p` uses WezTerm's built-in relative workspace switching, so it includes `default`.
- Worktree switching stays inside one repo-family tmux session and updates the active tmux window instead of spawning more top-level WezTerm tabs.
- tmux status refresh is hybrid: the draw path reads cached lines, focus and pane or window change hooks trigger debounced background refreshes, a recommended shell prompt hook (see [`setup.md`](./setup.md#tmux-status-prompt-hook); when the hook is not installed, `git` state can lag up to 30s) force-refreshes after each command so `git` operations reflect immediately, and a 30-second `status-interval` acts as a low-frequency fallback poll.
- The force-refresh debounce (`@tmux_status_force_debounce`, default 2s) is context-aware: it only collapses repeated refreshes for the *same* pane cwd (prompt-hook storms, repeated focus events). Switching to a different cwd — e.g. moving between repos in a worktree family — bypasses the debounce and recomputes the branch/worktree segment immediately, so the branch never lags behind the repo you just landed on. The last-refreshed cwd is tracked in `@tmux_status_last_cwd`.
- The status hooks pass **resolved context**, never `hook_window` / `hook_pane`. tmux only populates a `hook_*` variable when the notification carries that scope: `session-window-changed` is session-scoped (so `hook_window` is empty) and `window-pane-changed` is window-scoped (so `hook_pane` is empty) — only the client hooks get a usable `hook_client`. The old `--window #{q:hook_window}` form therefore expanded to a bare `--window`, whose value slot consumed the following `--force`, so switching worktree windows or panes recomputed nothing and the branch segment only caught up on the 30s poll (measured 20.4s vs 0.3s after the fix; the shell prompt hook masked it in shell panes, so it showed up mostly in agent panes). Both hooks now pass `--session #{q:session_name} --window #{q:window_id} --cwd #{q:pane_current_path}`, which resolve to the *new* window and pane in either scope, and `tmux-status-refresh.sh` refuses to read a flag-shaped token as an option value. Covered by `tests/hook-units/test_tmux_status_refresh_args.sh`.
- **Concurrent refreshes cannot lose the switch.** Every jump fires two or three refresh requests within ~15ms — the `session-window-changed` / `window-pane-changed` hook, `attention-jump.sh`'s explicit `--no-debounce` refresh, and `client-focus-in` — and each captured its context when it was queued. Two rules keep the last switch from being dropped: (1) `perform_refresh` re-reads the session's **live** active window / pane immediately before rendering, so a request queued a few ms before the switch landed still paints the worktree you are on rather than the previous one (the status line only ever describes the active pane, so live is also the correct semantics; the caller's `--cwd` remains the input to the debounce decision); (2) a `--force` request **waits** for a busy lock (`@tmux_status_lock_wait_attempts`, default 20 × 50ms) instead of returning silently. Before the fix the loser was dropped with nothing re-queuing it, so a jump could sit on the previous branch until the poll — and the poll measured **44-45s**, not the nominal 30s. After the wait, if the winner already rendered this live context (same `@tmux_status_last_cwd`, refreshed within 1s) the duplicate git probe is short-circuited. Covered by `tests/hook-units/test_tmux_status_refresh_args.sh`.
- Attention jumps (`Alt+j` / `Alt+k` / `Alt+l` / the `Alt+/` picker, via `attention-jump.sh`) force an un-debounced refresh of the landed session right after the `select-window` / `select-pane`. This is needed because those `select-*` calls are no-ops when the target window/pane is already active (the session was parked there), so the `session-window-changed` / `window-pane-changed` hooks never fire — without the explicit refresh the branch/worktree segment would stay stale until `client-focus-in` or the 30s poll.
- WakaTime status sources `wezterm-x/local/shared.env`, and WezTerm Lua also reads that same file for shared scalar values.
- Grok Build fullscreen TUI focus flash / cream `bg_base` tint / mouse-wheel feel: see [Grok Build in tmux](#grok-build-in-tmux) below (not a WezTerm paint bug).

## Grok Build in tmux

Grok’s fullscreen (alt-screen) TUI under this stack has three separable issues. The **primary** one is whole-content flash on pane focus; the **secondary** one is GrokDay’s cool `#eeeeee` canvas fighting cream pane styles; the **tertiary** one is mouse-wheel scroll feel under tmux (lines-per-tick + wheel/trackpad heuristic). Do not collapse them — cream-matching alone does not stop the flash, and scroll knobs live in `~/.grok/config.toml`, not this repo’s runtime sync.

### Symptom → cause → fix

| What you see | Cause | Fix layer |
| --- | --- | --- |
| Entire transcript flashes one frame on `Alt+o` / pane click (empty session often quieter) | tmux `focus-events on` delivers CSI FocusIn (`\e[I`); Grok enables `\e[?1004h`, then on FocusGained runs `terminal.clear()` (`\e[2J`) + full `app.draw` when `repaints_pane_out_of_band()` is true | **Repo:** PATH wrapper strips FocusIn/Out before they reach Grok ([Local fix](#local-fix-focus-filter)). Do **not** turn session `focus-events` off as the standing fix (starves Vim / Claude / attention). |
| Cool-grey flash / canvas vs cream pane | Stock GrokDay `bg_base` is opaque `#eeeeee` vs `window-style` `#eae9e1` / `window-active-style` `#f1f0e9` | **Optional:** `scripts/dev/patch-grok-theme-wezdeck.sh` with `WEZDECK_GROK_BG=f1f0e9` (or `default` → `Color::Reset`). Re-run after every Grok self-update. Pin `auto_light_theme = "grokday"` in `~/.grok/config.toml`. |
| Slow single-notch scroll (≈1 line/tick) under tmux | Grok `[ui] scroll_lines` unset → per-terminal profile defaults to a conservative 1 line/event inside tmux | **Machine-local:** set `scroll_lines` in `~/.grok/config.toml` (this host aligns with tmux `Wheel* -N 5` → `scroll_lines = 5`). Also `/settings` → **Scroll lines**. |
| Single-notch feels fine (~5 lines) but a fast flick barely moves | Terminal wheel events carry no magnitude; `scroll_mode = "auto"` guesses wheel vs trackpad from event timing and often treats a rapid notch burst as trackpad, damping the flick | **Machine-local:** force `scroll_mode = "wheel"` and raise `scroll_speed` (this host: `80`; `50` = 1.0x, `100` ≈ 6.0x). No per-tick scroll log in `runtime.log` — tune by feel or `/settings`. |
| Grok follow ▼ visible but click does nothing (colleague macOS works) | Repo used to bind root `MouseDown1Pane` to `select-pane` only, so the click never reached Grok; stock / uncustomized tmux forwards when the app sets mouse tracking | **Repo:** `MouseDown1Pane` now `select-pane` + `send-keys -M` when `alternate_on` or `mouse_any_flag`. Reload tmux conf / refresh session to pick up. Keyboard fallback: `Shift+G` (with `/vim-mode`) or overscroll past bottom. |

### Upstream root cause

Open source [`xai-org/grok-build`](https://github.com/xai-org/grok-build) (checked through public `main` and binaries **1.0.5 stable** / **1.0.7 alpha**, 2026-08-20):

1. `Event::FocusGained` in `xai-grok-pager` `event_loop.rs` sets `force_repaint` when `terminal_context().repaints_pane_out_of_band()` is true.
2. That predicate is `embedded_editor.is_some() || multiplexer != Undetected` (`xai-grok-pager-render` `terminal/mod.rs`) — **plain tmux always qualifies**.
3. Presenter does `terminal.clear()` then `app.draw(...)`.
4. Motivation (regression `tests/pty_e2e/doubled_lines_out_of_band_repro.rs`): heal stranded rows when **nvim `:terminal` / multiplexer** rewrites the pane out-of-band while Grok’s diff renderer only updates cells it owns.

So: heal for nested-editor doubled lines, gate too wide → ordinary tmux splits take the full clear on every focus. Not a WezTerm bug; WezTerm paints what the PTY emits.

Ideal upstream: narrow the gate to `embedded_editor` (or only after detecting stranded rows), or add a kill-switch. Repo Issues are disabled; product path is `/feedback` (submitted 2026-08-20; draft `~/.grok/feedback-drafts/tmux-focus-flicker.md`).

### Why macOS WezTerm + tmux can “not flash” even with the same heal

**One-line answer:** macOS is not exempt from the heal — Grok still clears on FocusIn. What differs is whether WezTerm ever **paints** the cleared intermediate state as its own display frame. On native macOS the clear→redraw usually finishes inside one 60 Hz frame (~16.7 ms), so the eye only sees the final UI. On this WSL→Windows WezTerm path the same clear is often long enough (or chunked enough) to become a visible frame — even when the pane is tiny.

Colleague check (2026-08-20, macOS aarch64, Grok **1.0.5** same commit as this machine, tmux **3.6a**, `focus-events = on`, fullscreen/alt-screen, non-nested tmux under WezTerm, `/doctor` clean with `multiplexer.kind = "tmux"`):

```text
FocusIn (\e[I)
  → Grok: terminal.clear() \e[2J + full app.draw   ← same on macOS and WSL
  → tmux: updates pane grid, re-encodes to client  ← “app cleared” ≠ “pixels flashed”
  → WezTerm: paints ~60 Hz frames
       native macOS: clear+redraw burst ~1–6 ms  → usually 1 composited frame → invisible
       WSL→Win WezTerm: burst delayed/fragmented → intermediate clear can be a painted frame → visible flash
```

1. **Mechanism matches this repo (macOS included).** Pty capture of Grok’s own writes: every FocusIn (`\e[I`) is followed by a lone `\e[2J` (~1 ms later the full redraw starts). FocusOut / idle never clear. Gate is still “any multiplexer”: forcing `multiplexer=tmux` or `herdr` → emits `2J`; clearing `TMUX`/`HERDR_ENV`/`STY`/`ZELLIJ`/… so `undetected` → no `2J`. `\e[?1004h` stays on in all three modes — only the clear-on-focus handler is gated. So “dingbo has no flash” is **not** “macOS skipped the heal”.
2. **`\e[2J` hits tmux first, not the GPU.** tmux eats the clear into its pane buffer and re-encodes a client update. A flash is only possible if WezTerm presents a frame while that buffer (or the in-flight client stream) still looks empty/partial.
3. **On dingbo’s macOS, that window is almost always sub-frame.** Real tmux **client** byte stream + pyte frame replay when returning to the Grok pane:
   - `focus-events on`: redraw burst ~**5.0 KiB** over **1.0–1.5 ms**
   - `focus-events off`: ~**0.6–1.0 KiB** / **0.2 ms** (mostly tmux redrawing the active-pane border)
   - Non-empty cell count dips **503 → 104 → … → 503** (floor ≠ 0) and the whole dip lands **inside one frame**. At 60 Hz a frame is **16.7 ms**, so WezTerm’s presented frame is already the restored UI → **no perceptible flash**.
4. **Burst grows with pane cells, still usually one frame on native macOS:**

   | Pane | Cells | Burst | Span |
   | --- | --- | --- | --- |
   | 59×40 | 2360 | ~5.0 KiB | 1.0–1.3 ms |
   | 207×60 | 12420 | ~17.8 KiB | 1.9–2.8 ms |
   | 307×90 | 27630 | ~34.7 KiB | 2.6–5.9 ms |

5. **macOS is timing-lucky, not timing-proof.** One small-pane trial there stretched to **19.19 ms** (over one frame) — so macOS can flash too; dingbo’s usual case just stays ~1–6 ms with headroom.
6. **This WSL host is the opposite timing regime.** Leading suspect: **WSL interop cutting/delaying** the pty burst before Windows WezTerm. Measured A/B (2026-08-20, unfiltered `grok.real`, isolated WezTerm + `groknofilter`, `focus-events on`): Grok pane ~**31×15** in a ~**60×18** client — `Alt+o` / pane-click **still** whole-content flashes. Shrinking the pane does **not** buy a free pass here; the standing fix remains the PATH focus-filter. Size scaling on macOS only explains why that machine often *looks* clean, not how to drop the wrapper on WSL.

Other quiet machines can still be explained by stock `focus-events off`, WezTerm-only panes (`multiplexer=undetected`), `--minimal`, or pre-heal Grok builds — but **do not assume macOS is config-off**; dingbo’s box had `focus-events on` and still no visible flash for timing reasons.

Upstream feedback: include the “`2J` always fires under multiplexer, but client burst is sub-frame on native hosts” numbers — otherwise maintainers may keep treating the heal as invisible.

### Investigation notes (what not to chase)

| Dead end | Why |
| --- | --- |
| Only patching cream / `Color::Reset` | Stops cool-grey tint mismatch; FocusGained still clears the whole UI |
| Equalizing `window-style` == `window-active-style` | Does not stop `terminal.clear()` + full redraw |
| Blaming missing DEC 2026 | Grok already wraps frames in `\e[?2026h`…`l`; the flash is a deliberate clear, not a torn differential |
| “Colleague on macOS doesn’t flash ⇒ mechanism wrong / OS-exempt” | Mechanism still fires `\e[2J` on FocusIn under tmux; macOS often stays sub-frame so the eye never sees it ([section above](#why-macos-wezterm--tmux-can-not-flash-even-with-the-same-heal)) |
| “Shrink the Grok pane on WSL to avoid flash” | Closed 2026-08-20: ~**31×15** unfiltered pane in ~**60×18** client still flashed on `Alt+o`. Size A/B explains macOS headroom, not a local workaround |
| Detached `tmux select-pane` as automated bounce | No attached client → FocusIn often never delivered; use CSI inject or interactive WezTerm `Alt+o` |
| Live process still flashing after installing the wrapper | (1) Wrapper only under `~/.local/bin` while `~/.zshrc` prepends `~/.grok/bin` — run `--install` so `~/.grok/bin/grok` is the wrapper. (2) Already-running process keeps the old stdin path until exit/`--resume`. Confirm tree is `python3 → grok.real`, not `zsh →` ELF `grok`. |
| Still flashes right after resume | `type -a grok` — if the first hit is a real ELF under `~/.grok/bin/grok` (not a symlink to `grok-with-focus-filter.sh`), re-run `--install` (often after `grok update`). |

### Local fix (focus-filter)

Keep session `focus-events on`. Blind only Grok.

Grok’s installer adds `export PATH="$HOME/.grok/bin:$PATH"` in `~/.zshrc`, so **`~/.grok/bin` wins over `~/.local/bin`**. A symlink only under `~/.local/bin/grok` is skipped — that is why a resume can still flash after “installing” the filter there. Install into the path Grok actually uses:

```bash
scripts/runtime/grok-with-focus-filter.sh --install
# parks the real binary at ~/.grok/bin/grok.real
# points ~/.grok/bin/grok (+ ~/.local/bin/grok) at the wrapper
hash -r
type -a grok          # first hit should be ~/.grok/bin/grok → …/grok-with-focus-filter.sh
grok --version        # still prints Grok version via grok.real
```

- Implementation: `scripts/runtime/grok-with-focus-filter.sh` + `scripts/runtime/grok-focus-filter.py` (PTY relay; strips `\e[I` / `\e[O]`).
- **Hold policy:** only an incomplete `\e[` suffix is buffered (needs one more byte to decide Focus vs other CSI). A **bare Esc is forwarded immediately** — an earlier version held every lone `\e` until more bytes arrived, which made `/settings` need several Esc presses to close and left a pending Esc so the next `/` looked like it needed two presses. Unit coverage: `tests/hook-units/test_grok_focus_filter.sh`.
- Opt out one run: `GROK_FOCUS_FILTER=0 grok …`
- Override binary: `GROK_REAL_BIN=/path/to/grok`
- After install (and after every `grok update`, which overwrites `~/.grok/bin/grok`), **exit and `--resume`** any live Grok. Confirm the new process is `python3 → grok.real`, not `zsh → grok` with exe `~/.grok/bin/grok` as a plain ELF.

### Mouse scroll (`~/.grok/config.toml` `[ui]`)

Grok’s wheel/trackpad knobs are **not** synced by `wezterm-runtime-sync`; they live in the user’s Grok config (or `/settings` → **Scroll speed** / **Scroll input** / **Scroll lines** / **Invert scroll**). There is no standing “one log line per wheel tick” in this repo’s `runtime.log` — `GROK_LOG_FILE` + `RUST_LOG=debug` is for Grok-internal tracing, not scroll UX metering.

Standing values on this machine (adjust per device):

```toml
[ui]
scroll_lines = 5          # match tmux.conf copy-mode WheelUp/Down -N 5
scroll_mode = "wheel"     # avoid auto misreading rapid notches as trackpad
scroll_speed = 80         # 50 = 1.0x; raise further if flicks still feel soft
```

Diagnostic split that led here: notch-by-notch already showed ~5 lines after setting `scroll_lines`, but fast flicks stayed sluggish until `scroll_mode = "wheel"`. If a trackpad is the primary input, try `scroll_mode = "trackpad"` instead of forcing wheel.

### Verify

```bash
# Headless causal matrix (isolated tmux; does not touch work sessions).
# inject-real uses ~/.grok/bin/grok.real (ELF); inject-wrap uses the installed wrapper.
scripts/dev/repro-grok-focus-flash.sh matrix
# Expect: inject-real / inject-wrap-off → FLASH(clear+redraw);
#         inject-wrap → no-clear
```

Interactive: split Grok + shell with transcript, `Alt+o` several times — whole surface should stay steady. Live tree should look like `python3 …/grok-focus-filter.py -- …/grok.real --resume …` (confirmed on this machine 2026-08-20 after `--install` + resume).

Version check when revisiting upstream: `grok update --check --json` (stable) and, if needed, side-load an alpha artifact under `/tmp` and re-run the inject harness — do not flip the machine’s `channel` unless intending to stay on alpha. After any `grok update`, re-run `--install` before trusting the interactive check.

## Upstream Constraints

- **Copy-mode flush flicker on streaming agents.** Entering tmux copy-mode while an agent (Claude Code, Codex, etc.) is still streaming causes a visible jump + flicker on exit: tmux stops reading PTY bytes for the whole duration of copy-mode, so all output the agent produced while you were scrolled up gets buffered, then flushes into the backing grid in one frame at exit. Confirmed by tmux maintainer nicm in [tmux/tmux#1718] as a design choice, not a bug — wezterm and the agent renderer cannot mitigate it. Two upstream commands have already landed in tmux master (post-3.6a, expected in the next release):
  - [tmux/tmux#4885] `refresh-from-pane` — flushes the buffer into the backing grid from inside copy-mode while preserving scroll position (records `oy_from_top` before reclone, restores it after). This config runs it automatically while copy-mode is active, but pauses while a selection is active because tmux 3.7b clears `selection_present` during the refresh.
  - [tmux/tmux#4884] `scroll-exit-on/off/toggle` — runtime toggle for `scroll_exit` so a long selection that crosses the bottom is not kicked out of copy-mode mid-drag.

  Remaining caveat: auto-refresh reduces the exit-time burst while you stay near the live bottom, but it deliberately stops once you browse older output. Output produced after the last refresh can still flush when leaving copy-mode; this is the tradeoff that keeps older scrollback positions stable.

[tmux/tmux#1718]: https://github.com/tmux/tmux/issues/1718
[tmux/tmux#4884]: https://github.com/tmux/tmux/pull/4884
[tmux/tmux#4885]: https://github.com/tmux/tmux/pull/4885
