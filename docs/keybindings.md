# Keybindings

Use this doc when you need shortcut behavior. Sections are ordered by impact radius, smallest first (pane-internal operations) and expanding outward to app- and workspace-level actions.

This workspace is designed keyboard-first: every feature is expected to have a keyboard path, and mouse bindings exist only as fallbacks where keyboard flow would be awkward (cross-pane text selection, quick pane focus, link opening). When a new or changed interaction only has a mouse affordance, treat that as a gap to close rather than a finished design.

## Selection And Clipboard

- `Shift+LeftDrag`: start a tmux pane-local selection inside the pane under the mouse; press `Ctrl+c` to copy while keeping the selection visible, or `Enter` to copy and exit copy-mode
- `LeftDrag`: plain drag does not start selection, even after wheel scrolling; use `Shift+LeftDrag` for tmux pane-local selection or `Super+LeftDrag` for terminal-wide selection
- `Super+LeftDrag`: bypass tmux mouse reporting and use WezTerm's terminal-wide text selection when you intentionally want to select across pane boundaries
- `Ctrl+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise send a normal terminal `Ctrl+c`. In tmux copy-mode, `Ctrl+c` copies the current selection without leaving copy-mode
- `Ctrl+Shift+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise forward `Ctrl+Shift+c` to the pane
- `Ctrl+v`: smart paste; in Windows-hosted `hybrid-wsl`, WezTerm asks the Windows native helper for the live clipboard state over IPC at paste time, falls back to a normal clipboard paste for text, and pastes the exported WSL image path when the latest clipboard content is an image
- `Ctrl+Shift+v`: force a normal clipboard paste without the image-export helper
- `Enter` in tmux copy-mode: copy the current tmux selection to the system clipboard and leave copy-mode
- `Alt+l`: trigger WezTerm QuickSelect to label every `http(s)://…` URL in the visible pane and WezTerm scrollback; press the shown letter to open the URL via the system default handler
- `Ctrl+LeftClick`: open the link under the mouse cursor in the system browser (mouse fallback for `Alt+l`)

## Scrollback

- `PageUp` / `Shift+Up`: upward scroll keys share one entry model. From a main-screen tmux pane that is not yet in copy-mode, the first press enters copy-mode with the cursor parked at the live bottom and does not scroll; subsequent presses inside copy-mode scroll up (one page for `PageUp`, 3 lines for `Shift+Up`). In alt-screen TUIs the key is forwarded to the app
- `PageDown` / `Shift+Down`: at the live prompt these are forwarded as plain terminal keys; inside copy-mode they scroll down (one page / 3 lines) while above the live bottom, and at the live bottom a single press exits copy-mode — mirroring the "one extra press at the boundary to switch mode" rule on entry. If a selection is active at the live bottom, the same press exits and discards the selection (use `Ctrl+c` or `Enter` first if you need to keep it)
- `WheelUp` in tmux on an unfocused pane: first retarget tmux to the pane under the mouse, then enter copy-mode; reaching the live bottom via wheel no longer auto-exits, so one additional wheel-down tick at the bottom is needed to leave, matching the keyboard paths
- `LeftClick` in tmux scrollback: without an active selection it moves the tmux scrollback cursor to the clicked cell; with an active selection it clears that selection without copying if you are still browsing scrollback, and exits copy-mode once you are already back at the live bottom

## Panes

- `Alt+o`: in any tmux-backed pane, rotate focus to the next pane in the current window (same semantics as tmux's `prefix o`); in non-tmux panes it shows the standard forwarding toast
- `Ctrl+k` `v`: vertical split of the current pane at its working directory
- `Ctrl+k` `h`: horizontal split of the current pane at its working directory
- `Ctrl+k` `x`: close the current tmux pane; if it is the last pane in its window the window also closes
- `Ctrl+k` `g`: enter the worktree sub-chord. The hint banner shows the available second keys: `d` / `t` / `h` to quick-create a worktree, `r` to reclaim the current one. All four call `scripts/runtime/worktree/open-task-window` (or `reclaim-current-window`) which then execs into `worktree-task launch` / `worktree-task reclaim`. Slug and branch follow the `wt_slugify` / `task/<slug>` convention; a leading `task/` is stripped on input. Colliding names bump to `<slug>-2`, `<slug>-3`. Reopening an *existing* task worktree belongs to `Alt+g` / `Alt+Shift+g`, not here.
  - `Ctrl+k` `g` `d`: prompt `dev-:`, create `.worktrees/<repo>/dev-<slug>/` for long-lived parallel development. Agent uses the `<base>-resume` profile (auto-continue cwd's last conversation).
  - `Ctrl+k` `g` `t`: prompt `task-:`, create `.worktrees/<repo>/task-<slug>/` for PR-scoped focused work. Resume profile.
  - `Ctrl+k` `g` `h`: prompt `hotfix-:`, create `.worktrees/<repo>/hotfix-<slug>/` for urgent fixes. Bare profile (fresh agent — urgent context shouldn't be polluted).
  - `Ctrl+k` `g` `r`: reclaim the worktree owning the current pane. Refuses on main, on `dev-*`, on dirty/untracked, and on unmerged branches (checked against `origin/HEAD` after `git fetch`). On confirm, switches focus to the main worktree's window, runs reclaim detached, then closes the original window.
- `LeftClick`: inside tmux, use the click only to focus the pane under the mouse; it does not start tmux selection and is not forwarded as a mouse click into the pane application

## Tabs

These shortcuts switch WezTerm tabs inside the current workspace; they are owned by the WezTerm keymap and do not touch tmux. For the layer model see [`architecture.md`](./architecture.md#interaction-layers).

- `Alt+n`: activate the next WezTerm tab in the current workspace
- `Alt+Shift+n`: activate the previous WezTerm tab in the current workspace
- `Alt+1` … `Alt+9`: activate the WezTerm tab at that position in the current workspace (1-indexed; the key maps to `ActivateTab(N-1)`)

## Agent Attention

These shortcuts jump to the next agent task that needs attention, using the shared state file described in [`tmux-ui.md`](./tmux-ui.md#agent-attention). Both are keyboard-first and require a tmux-backed pane — WezTerm forwards the key into tmux, which executes `scripts/runtime/attention-jump.sh`. Outside tmux the key shows a toast explaining the requirement, consistent with the other forwarding shortcuts (`Alt+v`, `Alt+g`, `Alt+o`, `Ctrl+k`, `Ctrl+Shift+P`).

- `Alt+,`: jump to the next task whose status is `waiting`. Runs entirely in Lua — `attention.pick_next` chooses a target different from the current pane so repeated presses cycle, `attention.activate_in_gui` issues `SwitchToWorkspace` when needed and activates the target tab + pane via the mux, then `attention-jump.sh --direct …` is spawned in the background to `select-window` / `select-pane` against the target's tmux socket (fast path — no state re-read, no `wezterm.exe` round-trip). Silent when there is no waiting task. Landing on the target pane lets the focus-based auto-ack in `attention.maybe_ack_focused` spawn a zero-delay `--forget` on the next `update-status` tick and optimistically hide the entry from the in-memory cache in the same frame, so the `⚠` counter drops almost immediately without the keymap having to re-spawn the forget subprocess itself. The entry can also exit earlier through the PostToolUse hook firing `resolved` on tool completion (which flips `waiting` back to `running`), a fresh `Stop` transitioning it to `done`, or a new prompt.
- `Alt+.`: jump to the next task whose status is `done`. Same Lua-driven flow as `Alt+,`. On a successful jump the Lua side additionally spawns `attention-jump.sh --forget <session_id> --delay 3 --only-if-ts <ts>` as a safety-net cleanup, but in practice the focus-based auto-ack in `attention.maybe_ack_focused` fires first (zero-delay + optimistic in-memory hide), so the counter drops almost immediately and the delayed forget only matters if focus-ack never ran (for example, the user jumped away before the next tick). `waiting` and `done` share one clearance pipeline; `running` is not a jump target and is not auto-cleared on focus — the render-time focused-pane filter hides it from the counter instead, since running reflects live work that will transition to `waiting` or `done` on its own.
- `Alt+/`: open a centered WezTerm InputSelector listing every pending task. Each row is shaped as `<workspace>/<tab_index>_<tab_title>/<tmux_window>_<tmux_pane>/<branch>  <marker> <reason>  (<age>)`, where the marker is `⚠` for `waiting`, `⟳` for `running`, or `✓` for `done`. Slot separators are `/`; within a slot that needs two pieces (tab index + title, tmux window + pane) the glue is `_` so no terminal-convention glyphs (`#`, `@`, `:`, `%`) leak into the label. Workspace and tab (index + title) are resolved live from the mux at overlay-open time; tmux ids and `git_branch` come from state.json (branch captured from `$CLAUDE_PROJECT_DIR`, tmux `pane_current_path`, or `$PWD` at hook-fire). Unknown components render as `?`; when all four are unknown the prefix is omitted entirely. Combined with the tmux-pane-level dedup at the write layer (`attention_state_upsert` drops other entries sharing the same `(tmux_socket, tmux_pane)`), this guarantees one row per active agent pane. Type to fuzzy-filter, `Enter` to jump to the selected session via the same `attention-jump.sh --session <id>` pipeline. This entry is WezTerm-native (not forwarded to tmux) so it also works in non-tmux panes, but the final jump still requires the target to live in a tmux session in hybrid-wsl. When an entry lacks `wezterm_pane_id` (old entries written before `WEZTERM_PANE` propagated through tmux), the jump script falls back to `tmux show-environment -t <session> WEZTERM_PANE` to recover the pane id from session env; the age suffix `(<age>, no pane)` flags such rows upfront. The last row is a destructive `——  clear all · <N> entries  ——` sentinel: selecting it invokes `attention-jump.sh --clear-all` via a blocking subprocess, then injects an OSC `attention_tick` back into the current pane so the badges and counter repaint in the next frame rather than after the `status_update_interval` tick. Use it to recover from stale entries (WezTerm restart, agents killed without hooks firing).

## Commands

- `Ctrl+k`: tmux chord prefix in tmux-backed panes; follow-up keys act on tmux panes and are listed in `Panes` above
- `Ctrl+Shift+P`: when the current pane is running tmux, open the tmux-owned searchable command palette with repo-shared commands plus optional machine-local extensions from `wezterm-x/local/command-panel.sh`; outside tmux it falls back to WezTerm's native command palette
- `Ctrl+Shift+;`: open WezTerm's native command palette directly

## Project Navigation

- `Alt+v`: in any tmux-backed pane, forward to tmux so the active tmux window resolves the live worktree first and, in `hybrid-wsl`, uses the Windows native helper request path; outside tmux, WezTerm opens the current worktree root in VS Code directly and still falls back to pane handling when it only sees the WSL host path. The VS Code profile is controlled by `WEZTERM_VSCODE_PROFILE` in `wezterm-x/local/shared.env` (default `ai-dev`); unset or empty falls back to VS Code's default profile. Import the template from `wezterm-x/local.example/vscode/ai-dev.code-profile` before first use
- `Alt+g`: in any tmux-backed pane, open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: in any tmux-backed pane, cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- The Windows helper auto-starts a headless Chrome debug instance the moment it boots (after `ReconcileOnStartup`), so `http://localhost:<remote_debugging_port>` always has a CDP endpoint for MCP / agent tools without requiring `Alt+b` to be pressed first. Detection is mode-agnostic: any chrome already running on that port + `user_data_dir` is adopted as-is regardless of mode (so a visible session you started yesterday survives helper restarts intact); only when nothing is running does the helper launch one, and that launch is **always headless** to avoid interrupting whatever app currently owns the foreground. Auto-start never steals focus and never writes the WindowReuseService cache (those belong to user-driven `Alt+b`). To disable, set `chrome_debug_browser.auto_start = false` in `wezterm-x/local/constants.lua`. The `chrome_debug_browser.headless` field still governs the user-driven `Alt+b` path and is independent of auto-start.
- `Alt+b`: launch or reuse the Chrome debug browser profile from `wezterm-x/local/constants.lua` in headless mode; pressing it never steals focus or flashes the taskbar, and MCP clients attach via `--browser-url=http://localhost:<port>`. The launch always adds the hardening flags `--remote-allow-origins=*` (covers MCP `http://localhost:<port>` clients and the human-debug path through `chrome://inspect` / `edge://inspect` / `devtools://devtools`; the wildcard is acceptable because Chrome binds the port to 127.0.0.1 and the dedicated `user_data_dir` is not the user's main profile), `--disable-extensions`, `--no-first-run`, `--no-default-browser-check`, plus `--headless=new` and `--window-size=1920,1080` (headless defaults to 800×600, which breaks MCP screenshots and viewport-sensitive scrapes). If a visible-mode Chrome is already holding the same port + `--user-data-dir`, the helper terminates it (entire process tree) before launching headless so the Chrome singleton lock is released — this is the automatic mode switch; the visible companion is `Alt+Shift+b` below. Helper writes the current mode/port/pid/alive to `chrome_debug_browser.state_file` (defaults to `$runtime_state_dir/state/chrome-debug/state.json`) on every successful request, and rewrites it to `mode=none, alive=false` the moment the Chrome process exits (via `ChromeLivenessWatcher` which subscribes `Process.Exited` plus a 5 s `HasExited` poll fallback, and re-subscribes on helper restart through `ReconcileOnStartup`). The WezTerm right-status renders just to the right of the IME segment as a fixed-width badge: `CDP·H·9222` (headless, inactive palette, Normal intensity), `CDP·V·9222` (visible, running-attention palette, Bold), `CDP·-·<port>` (helper alive but Chrome not running — `mode=none` or `alive=false`; idle palette with Italic; the port falls back to `remote_debugging_port` when no state file exists yet), or `CDP·?·<port>` (helper itself looks dead — its `state.env` heartbeat is older than `helper_heartbeat_timeout_seconds`, so the chrome state file may be arbitrarily stale and the badge cannot be trusted; emits warning palette with Italic). The four states share the same glyph count so the bar width never jitters when you switch modes. In `hybrid-wsl` this goes through the same Windows native helper path as `Alt+v`; in `posix-local` it stays unavailable until a native host helper exists
- `Alt+Shift+b`: launch or reuse the same Chrome debug browser profile in visible (headful) mode for manual acceptance or UI verification; shares the same `user_data_dir` (cookies, logins, extensions state are preserved across mode switches) and same port as `Alt+b`, so only one mode can run at a time. Pressing this when a headless instance is running will kill that headless first, wait for the `--user-data-dir` singleton lock to release, and start a visible Chrome with the same hardening flags (minus `--headless=new` and `--window-size=1920,1080`, which are headless-only). MCP connections from the previous headless session will drop and can be reestablished on the visible instance. The right-status segment flips to `CDP·V·<port>` after launch

## Browser Debug Workflow

The default day is **headless**: the Windows helper auto-launches a headless Chrome the moment it boots, MCP / agent tools attach without ever surfacing a window, and nothing is allowed to grab the foreground or flash the taskbar. When you actually need to look at the page yourself, you pivot from your default browser through `chrome://inspect` (or `edge://inspect`) — no need to switch the headless instance to visible just to peek. The four daily paths and what they do:

1. **Daily — auto-start (zero keystrokes)**. Helper boot runs `ReconcileOnStartup` then mode-agnostic detection on `localhost:<remote_debugging_port>` + the configured `user_data_dir`; if any chrome (visible or headless) is already there it adopts the existing PID, otherwise it launches a fresh headless one. The status segment lands on `CDP·H·<port>` immediately. MCP servers in your agent / Claude Code config can stay attached via `--browser-url=http://localhost:<port>` across sessions; nothing depends on you having pressed `Alt+b`.
2. **Programmatic — agent tools and MCP**. With auto-start running, every Chrome DevTools MCP server, every agent that takes `--browser-url=http://localhost:<port>`, and every CDP-aware automation script just connects. The endpoint always answers (you can confirm with `curl -sS http://localhost:<port>/json/version` from any pane in WSL or Windows). The agent never has to wait for a human to "set up" the browser.
3. **Human inspection — `chrome://inspect` from your default browser**. Open your normal Chrome (or Edge / any Chromium) and go to `chrome://inspect/#devices`. Click *Configure…* in the *Discover network targets* row and add `localhost:<remote_debugging_port>` (default `9222`). The headless instance's pages and service workers appear under *Remote Target*; click *inspect* on any one to open the standard DevTools window — Console, Network, Elements, Sources, Performance — fully connected to the headless session your agent is driving. This is the path for "agent broke, let me look at what it sees" and "I need to manually adjust state then hand it back". It works because the launch flags use `--remote-allow-origins=*`, so the WebSocket from `chrome://inspect` is not rejected. The headless instance keeps running afterward; closing the inspector does not change anything in the session.
4. **Manual override — `Alt+b` / `Alt+Shift+b`**. Reserved for the cases where chrome://inspect is not enough: `Alt+b` resets the instance to headless (kills any visible chrome on the same port + user_data_dir first, then relaunches headless), `Alt+Shift+b` kills headless and switches to a fully visible chrome (pops a window into the foreground). Use these when the agent flow requires a clean slate, or when chrome://inspect's read-mostly view is not enough and you need a real visible browser window to type in. After either action the right-status badge flips to `CDP·H·<port>` or `CDP·V·<port>` to confirm.

The status badge tells you whether the workflow is healthy: `CDP·H·<port>` headless ready, `CDP·V·<port>` visible ready, `CDP·-·<port>` helper is alive but no chrome is running (auto-start failed or you killed chrome and have not relaunched), `CDP·?·<port>` helper itself is unresponsive (state.env heartbeat stale; running `wezterm-runtime-sync` or restarting WezTerm will respawn it). For an end-to-end smoke check, `curl -sS http://localhost:<port>/json/version` should return a JSON blob with `Browser`, `Protocol-Version`, and `webSocketDebuggerUrl`; that single response confirms helper, chrome, and the inspect path are all live.

## Workspaces

- `Alt+d`: switch to WezTerm built-in `default`
- `Alt+w`: open or switch to `work` using the private directories configured in `wezterm-x/local/workspaces.lua`
- `Alt+c`: open or switch to `config`
- `Alt+p`: rotate through all currently known workspaces
- `Alt+Shift+x`: open a centered WezTerm confirmation overlay to close the current non-default workspace
- `Alt+Shift+q`: quit WezTerm and close all windows; WezTerm will handle any built-in confirmation

## Custom Keybindings

Per-machine overrides live in `wezterm-x/local/keybindings.lua`. Copy the template at `wezterm-x/local.example/keybindings.lua`, uncomment the bindings you want to change, and reload WezTerm. Overrides are addressed **by command id**, not by the old key, so the file survives future default-key reshuffles.

Value shapes (VS Code `keybindings.json` style, Lua-flavored):

- `[id] = 'Ctrl+Shift+v'` — replace the single default key for a one-hotkey id (`vscode.open-current-dir`, `workspace.switch-work`, etc.).
- `[id] = false` — disable the id; every variant is skipped at keymap build time.
- `[id] = { { key = 'Cmd+1', args = 1 }, ... }` — per-variant remap for parametrized ids. `args` must match one of the id's `args_schema` values in `commands/manifest.json` (e.g. `tab.select-by-index` accepts integers `1..9`). Variants not listed keep their defaults.

Key string rules:

- Modifiers joined by `+`: `Ctrl`, `Shift`, `Alt` (aliases: `Opt`, `Option`, `Meta`), `Cmd` (aliases: `Super`, `Win`).
- The last `+`-separated token is the main key; case is preserved (`Ctrl+Shift+v` vs `Ctrl+Shift+V`).
- Chord keys (space-separated segments like `Ctrl+k v`) are **not yet supported** in this file. To change a `Ctrl+k` chord leaf (`pane.split-vertical`, `worktree.quick-create-*`, etc.) edit `tmux.conf` directly.

Discoverability:

- `wezterm-x/commands/manifest.json` lists every id, its default keys, and — for parametrized commands — the `args_schema`.
- `scripts/dev/hotkey-usage-report.sh` cross-references the manifest with the live keymap, useful when you need to audit what the override actually produced.

Scope and limits of this release:

- **Only WezTerm-layer bindings are customizable.** Overrides that target a `tmux-chord` id are accepted syntactically but ignored with a warning; a future pass will regenerate the tmux `command-chord` / `worktree-chord` tables from the same file.
- Overriding `command-palette.chord-prefix` (`Ctrl+k`) currently remaps the WezTerm side only. The tmux side still captures the old `Ctrl+k`, so both keys will work until chord rendering lands.
- You cannot bind a new key to a command that has no default binding (e.g. `session.refresh-*` entries that exist only in the palette). The override surface is limited to remapping / disabling bindings that keymaps.lua already owns.

Invalid entries (unknown id, bad key string, args out of range, missing args for multi-hotkey ids) are dropped with a `warn` line under logger category `keybindings` at startup — check the diagnostics log (`wezterm-x/local/runtime-logging.sh` routes it) to confirm the override landed.
