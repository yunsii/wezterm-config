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
  - `Ctrl+k` `g` `h`: prompt `hotfix-:`, create `.worktrees/<repo>/hotfix-<slug>/` for urgent fixes. Resume profile (the agent CLI falls back to a fresh session on first open of a brand-new worktree).
  - `Ctrl+k` `g` `r`: reclaim the worktree owning the current pane. Refuses on main, on `dev-*`, on dirty/untracked, and on unmerged branches (checked against `origin/HEAD` after `git fetch`). On confirm, switches focus to the main worktree's window, runs reclaim detached, then closes the original window.
- `Ctrl+k` `l`: open the project links picker for the current pane's cwd. `links-menu.sh` runs the `vscode-links` CLI (https://github.com/yunsii/vscode-links) for the rendered link list (provider auto-detect plus `.vscode/settings.json` `links.resources` / `links.remoteResources`), pipes the rows into the native `picker links` Go subcommand inside a centered tmux popup, and dispatches via `links-dispatch.sh`. Enter opens the URL on the Windows host via `windows_run_powershell_command_utf8` → `Start-Process`; `Ctrl+Y` copies it to the Windows clipboard via `Set-Clipboard`. Requires `vscode-links` (install with the project's `install.sh`, or set `VSCODE_LINKS_BIN`) and `jq` on `PATH`; the picker binary itself comes from the same `native/picker` Go module that powers the attention / command / worktree popups.
- `LeftClick`: inside tmux, use the click only to focus the pane under the mouse; it does not start tmux selection and is not forwarded as a mouse click into the pane application

## Tabs

These shortcuts switch WezTerm tabs inside the current workspace; they are owned by the WezTerm keymap and do not touch tmux. For the layer model see [`architecture.md`](./architecture.md#interaction-layers).

- `Alt+n`: activate the next WezTerm tab in the current workspace
- `Alt+Shift+n`: activate the previous WezTerm tab in the current workspace
- `Alt+1` … `Alt+9`: activate the WezTerm tab at that position in the current workspace (1-indexed; the key maps to `ActivateTab(N-1)`)

## Agent Attention

These shortcuts navigate the shared agent-attention state. All three require a tmux-backed pane and show the standard `... only available when the current pane is running tmux` toast otherwise. Implementation detail (Lua vs popup, `--direct` vs `--session` paths, focus-based auto-ack, `--only-if-ts` guard, clear-all sentinel): [`agent-attention.md#keyboard`](./agent-attention.md#keyboard).

- `Alt+,`: jump to the next `waiting` task. Silent when there are none. Cycles past the current pane on repeated presses.
- `Alt+.`: jump to the next `done` task. Same flow as `Alt+,`; landing on the pane auto-clears the `✓` counter on the next status tick.
- `Alt+/`: open a centered tmux popup picker listing every pending task. Rows are `<workspace>/<tab_index>_<tab_title>/<tmux_window>_<tmux_pane>/<branch>  <marker> <reason>  (<age>[, no pane])`, where marker is `🚨` waiting / `🔄` running / `✅` done / `📜` recent. The popup has a command-palette-style always-on `Search:` input on row 2 (dim `Type to filter (Tab cycles status)…` placeholder when empty); typing any printable ASCII filters by case-insensitive substring against the row body (workspace / tab / branch / reason all match). `Backspace` edits, `Ctrl+U` clears the query in one keystroke, `Esc` clears a non-empty query first and closes only on the second press. `Up`/`Down` move, `Enter` jumps. `Tab` cycles an orthogonal status filter `all → waiting → done → running → all` shown as a chip in the title; `recent` rows live only in the `all` band and surface previously-active sessions archived from any exit path (TTL prune, focus-ack forget, same-pane eviction, `--clear-all`, etc. — see [`agent-attention.md` *Recent archive*](./agent-attention.md#state-file)). Recent rows render with a dim `(<last_status>, archived)` suffix and dispatch through `attention-jump.sh --recent`, which probes pane existence first; if the pane is gone the row is removed from `recent[]` and you get a toast instead of a silent no-op jump. Press `Alt+/` or `Ctrl+C` again to close from any state (true toggle). Last row is a destructive `——  clear all · N entries  ——` sentinel (hidden when any filter is active) that wipes active state into `recent[]` for recovery (WezTerm restart, agents killed without hooks).

## Agent CLI

- `Ctrl+n`: when the focused pane has a known agent CLI in foreground (`claude` or `codex`), inject `/new` followed by Enter to start a fresh conversation. In tmux-backed panes WezTerm forwards `\x0e` and tmux's root binding does the foreground check via `pane_current_command`; outside tmux WezTerm checks `get_foreground_process_name()` directly. When the foreground is anything else (shell, editor, …), `Ctrl+n` is passed through unchanged so `readline`/`emacs`/etc. next-line bindings keep working. Detection covers the profiles declared in `wezterm-x/lua/constants.lua` `managed_cli.profiles` — add a new profile name to both the Lua handler (`agent_cli_basenames` in `wezterm-x/lua/ui/action_registry.lua`) and the tmux `if-shell` pattern in `tmux.conf` if you introduce another agent CLI.

## Commands

- `Ctrl+k`: tmux chord prefix in tmux-backed panes; follow-up keys act on tmux panes and are listed in `Panes` above
- `Ctrl+Shift+P`: when the current pane is running tmux, open the tmux-owned searchable command palette with repo-shared commands plus optional machine-local extensions from `wezterm-x/local/command-panel.sh`; outside tmux it falls back to WezTerm's native command palette. Inside the palette, Enter dispatches the entry directly via its `palette.command` (executed by `tmux-command-run.sh`). Entries marked `palette.display_only: true` (those whose action only the WezTerm GUI process can perform — `ActivateTab*` / `SwitchToWorkspace` / `QuickSelectArgs` / chrome-debug / attention jumps) print a toast pointing at the hotkey instead, since the popup can't reach the WezTerm event loop. tmux-side actions (kill-pane, worktree pickers, attention overlay, agent-CLI `/new`, …) expose a real `palette.command` so Enter works the same as the hotkey
- `Ctrl+Shift+;`: open WezTerm's native command palette directly

## Project Navigation

- `Alt+v`: in any tmux-backed pane, forward to tmux so the active tmux window resolves the live worktree first and, in `hybrid-wsl`, uses the Windows native helper request path; outside tmux, WezTerm opens the current worktree root in VS Code directly and still falls back to pane handling when it only sees the WSL host path. VS Code profile selection (`WEZTERM_VSCODE_PROFILE`) and the one-time profile-import step are documented in [`setup.md`](./setup.md#local-setup) step 7
- `Alt+g`: in any tmux-backed pane, open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: in any tmux-backed pane, cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- `Alt+b`: launch or reuse the Chrome debug browser profile in **headless** mode (never steals focus). Switches a visible instance to headless if one is already running. The right-status badge flips to `CDP·H·<port>`.
- `Alt+Shift+b`: launch or reuse the same profile in **visible** (headful) mode for manual UI verification. Switches a headless instance to visible. The right-status badge flips to `CDP·V·<port>`.

The Windows helper auto-launches a headless instance on boot, so MCP / agent attach (`--browser-url=http://localhost:<port>`) needs no keypress. Full workflow (auto-start, the four daily paths, launch-flag rationale, badge states, smoke check): [`browser-debug.md`](./browser-debug.md).

## Workspaces

- `Alt+d`: switch to WezTerm built-in `default`
- `Alt+w`: open or switch to `work` using the private directories configured in `wezterm-x/local/workspaces.lua`
- `Alt+c`: open or switch to `config`
- `Alt+m`: switch to `mock-deck` — only useful when that demo workspace is registered in `wezterm-x/local/workspaces.lua` and the orchestrator at `scripts/dev/mock-deck/mock-deck.sh` is running
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
- The last `+`-separated token is the main key. For single-letter keys, declarations are **case-insensitive**: `Ctrl+P` and `Ctrl+p` both bind Ctrl+P with no Shift. To bind Ctrl+Shift+P, write `Ctrl+Shift+P` (or `Ctrl+Shift+p`) explicitly — `Shift` must be in the modifier list. Multi-character key names (`Enter`, `F1`, `BSpace`), digits, and punctuation are left as written.
- Chord keys use space-separated segments: `Ctrl+k s` rebinds a `command-chord` leaf, `Ctrl+k g e` rebinds a `worktree-chord` leaf. The chord prefix stays `Ctrl+k` at the tmux side regardless of what you write for the prefix segment — only the final segment is consumed. The leaf segment follows the same case-insensitive rule as the wezterm-layer parser: `Ctrl+k v` and `Ctrl+k V` both bind the leaf `v`, while `Ctrl+k Shift+v` and `Ctrl+k Shift+V` both bind the leaf `V` (which IS Shift+v in tmux's native key syntax — tmux encodes Shift on letters by uppercasing). Chord leaves are regenerated at runtime-sync time (`scripts/runtime/render-tmux-bindings.sh`); rerun `wezterm-runtime-sync` after editing.

Discoverability:

- `wezterm-x/commands/manifest.json` lists every id, its default keys, and — for parametrized commands — the `args_schema`.
- `scripts/dev/hotkey-usage-report.sh` cross-references the manifest with the live keymap, useful when you need to audit what the override actually produced.

Scope and limits:

- **WezTerm-layer and tmux-chord-layer bindings are customizable.** WezTerm-layer changes take effect on the next WezTerm reload; tmux-chord changes require `wezterm-runtime-sync` to regenerate `wezterm-x/tmux/chord-bindings.generated.conf` and for tmux to re-source it.
- `command-palette.chord-prefix` (`Ctrl+k`) remaps only the WezTerm side. The tmux root `bind-key -n C-k` stays pinned: WezTerm forwards a literal Ctrl+K byte (`\x0b`) to tmux regardless of what key you used on the WezTerm side, so the forwarding stays intact. If you want a completely different tmux chord prefix you'd need to edit `render-tmux-bindings.sh`.
- Chord leaves can be rebound within their chord table but not moved across tables (`pane.split-vertical` stays in `command-chord`, `worktree.quick-create-dev` stays in `worktree-chord`).
- You cannot bind a new key to a command that has no default binding (e.g. `session.refresh-*` entries that exist only in the palette). The override surface is limited to remapping / disabling bindings already declared in `manifest.json`.

Invalid entries (unknown id, bad key string, args out of range, missing args for multi-hotkey ids) are dropped with a `warn` line under logger category `keybindings` at startup — check the diagnostics log (`wezterm-x/local/runtime-logging.sh` routes it) to confirm the override landed.
