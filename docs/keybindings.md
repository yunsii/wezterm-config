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

- `PageUp`: in a tmux-backed pane that is on the main screen and not already in copy-mode, enter tmux copy-mode with the cursor parked at the live bottom; subsequent `PageUp` inside copy-mode uses tmux's default page-up. In alt-screen TUIs and once copy-mode is active, the key is forwarded so the app or copy-mode's own paging takes over
- `Shift+Up` / `Shift+Down`: from a main-screen tmux pane, enter copy-mode and scroll 3 lines up or down for fine-grained adjustment from the live prompt; once copy-mode is active the same key keeps scrolling 3 lines in both emacs and vi tables; in alt-screen TUIs the key is forwarded to the app
- `WheelUp` in tmux on an unfocused pane: first retarget tmux to the pane under the mouse, then enter scrollback or copy-mode there
- `LeftClick` in tmux scrollback: without an active selection it moves the tmux scrollback cursor to the clicked cell; with an active selection it clears that selection without copying if you are still browsing scrollback, and exits copy-mode once you are already back at the live bottom

## Panes

- `Ctrl+k` `v`: vertical split of the current pane at its working directory
- `Ctrl+k` `h`: horizontal split of the current pane at its working directory
- `Ctrl+k` `o`: in any tmux-backed pane, rotate focus to the next pane in the current window (same semantics as tmux's `prefix o`)
- `Ctrl+k` `x`: close the current tmux pane; if it is the last pane in its window the window also closes
- `Ctrl+k` `g`: quick-create a task workspace for the current repo family. Opens a tmux `command-prompt` labeled `branch:`; the entered name is forwarded to `skills/worktree-task/scripts/open-task-window`, which execs `worktree-task launch --provider tmux-agent --no-prompt --title <name>` so slug and branch follow the skill's `wt_slugify` / `task/<slug>` convention (leading `task/` is stripped). The agent starts idle in the new window. Colliding names bump to `<slug>-2`, `<slug>-3`, etc.; reopening an existing task worktree belongs to `Alt+g` / `Alt+Shift+g`.
- `LeftClick`: inside tmux, use the click only to focus the pane under the mouse; it does not start tmux selection and is not forwarded as a mouse click into the pane application

## Tabs

These shortcuts switch WezTerm tabs inside the current workspace; they are owned by the WezTerm keymap and do not touch tmux. For the layer model see [`architecture.md`](./architecture.md#interaction-layers).

- `Alt+n`: activate the next WezTerm tab in the current workspace
- `Alt+Shift+n`: activate the previous WezTerm tab in the current workspace
- `Alt+1` … `Alt+9`: activate the WezTerm tab at that position in the current workspace (1-indexed; the key maps to `ActivateTab(N-1)`)

## Agent Attention

These shortcuts jump to the next agent task that needs attention, using the shared state file described in [`tmux-ui.md`](./tmux-ui.md#agent-attention). Both are keyboard-first and require a tmux-backed pane — WezTerm forwards the key into tmux, which executes `scripts/runtime/attention-jump.sh`. Outside tmux the key shows a toast explaining the requirement, consistent with the other forwarding shortcuts (`Alt+v`, `Alt+g`, `Ctrl+k`, `Ctrl+Shift+P`).

- `Alt+,`: jump to the next task whose status is `waiting`. Runs entirely in Lua — `attention.pick_next` chooses a target different from the current pane so repeated presses cycle, `attention.activate_in_gui` issues `SwitchToWorkspace` when needed and activates the target tab + pane via the mux, then `attention-jump.sh --session <id>` is spawned in the background to run `tmux select-window` / `select-pane` against the target's tmux socket. Silent when there is no waiting task.
- `Alt+.`: jump to the next task whose status is `done`. Same Lua-driven flow as `Alt+,`. Entries are kept until the agent writes `cleared` on its next `UserPromptSubmit`; there is no auto-clear on jump.
- `Alt+/`: open a centered WezTerm InputSelector listing every pending task. Each row is shaped as `<workspace>/<tab_index>_<tab_title>/<tmux_window>_<tmux_pane>/<branch>  <marker> <reason>  (<age>)`. Slot separators are `/`; within a slot that needs two pieces (tab index + title, tmux window + pane) the glue is `_` so no terminal-convention glyphs (`#`, `@`, `:`, `%`) leak into the label. Workspace and tab (index + title) are resolved live from the mux at overlay-open time; tmux ids and `git_branch` come from state.json (branch captured from `$CLAUDE_PROJECT_DIR`, tmux `pane_current_path`, or `$PWD` at hook-fire). Unknown components render as `?`; when all four are unknown the prefix is omitted entirely. Combined with the tmux-pane-level dedup at the write layer (`attention_state_upsert` drops other entries sharing the same `(tmux_socket, tmux_pane)`), this guarantees one row per active agent pane. Type to fuzzy-filter, `Enter` to jump to the selected session via the same `attention-jump.sh --session <id>` pipeline. This entry is WezTerm-native (not forwarded to tmux) so it also works in non-tmux panes, but the final jump still requires the target to live in a tmux session in hybrid-wsl. When an entry lacks `wezterm_pane_id` (old entries written before `WEZTERM_PANE` propagated through tmux), the jump script falls back to `tmux show-environment -t <session> WEZTERM_PANE` to recover the pane id from session env; the age suffix `(<age>, no pane)` flags such rows upfront. The last row is a destructive `——  clear all · <N> entries  ——` sentinel: selecting it invokes `attention-jump.sh --clear-all` via a blocking subprocess, then injects an OSC `attention_tick` back into the current pane so the badges and counter repaint in the next frame rather than after the `status_update_interval` tick. Use it to recover from stale entries (WezTerm restart, agents killed without hooks firing).

## Commands

- `Ctrl+k`: tmux chord prefix in tmux-backed panes; follow-up keys act on tmux panes and are listed in `Panes` above
- `Ctrl+Shift+P`: when the current pane is running tmux, open the tmux-owned searchable command palette with repo-shared commands plus optional machine-local extensions from `wezterm-x/local/command-panel.sh`; outside tmux it falls back to WezTerm's native command palette
- `Ctrl+Shift+;`: open WezTerm's native command palette directly

## Project Navigation

- `Alt+v`: in any tmux-backed pane, forward to tmux so the active tmux window resolves the live worktree first and, in `hybrid-wsl`, uses the Windows native helper request path; outside tmux, WezTerm opens the current worktree root in VS Code directly and still falls back to pane handling when it only sees the WSL host path. The VS Code profile is controlled by `WEZTERM_VSCODE_PROFILE` in `wezterm-x/local/shared.env` (default `ai-dev`); unset or empty falls back to VS Code's default profile. Import the template from `wezterm-x/local.example/vscode/ai-dev.code-profile` before first use
- `Alt+g`: in any tmux-backed pane, open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: in any tmux-backed pane, cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- `Alt+b`: open the configured Chrome debug browser profile from `wezterm-x/local/constants.lua`; in `hybrid-wsl` it uses the same Windows native helper path as `Alt+v`, and in `posix-local` it stays unavailable until a native host helper exists

## Workspaces

- `Alt+d`: switch to WezTerm built-in `default`
- `Alt+w`: open or switch to `work` using the private directories configured in `wezterm-x/local/workspaces.lua`
- `Alt+c`: open or switch to `config`
- `Alt+p`: rotate through all currently known workspaces
- `Alt+Shift+x`: open a centered WezTerm confirmation overlay to close the current non-default workspace
- `Alt+Shift+q`: quit WezTerm and close all windows; WezTerm will handle any built-in confirmation
