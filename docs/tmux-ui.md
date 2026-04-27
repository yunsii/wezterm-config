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
- tmux refresh is command-palette-owned instead of WezTerm-shortcut-owned.
- `Ctrl+k` is a tmux chord prefix for memorized low-latency actions such as `Ctrl+k v` for vertical split and `Ctrl+k h` for horizontal split.
- After `Ctrl+k`, tmux temporarily replaces one status line with a generic waiting hint.
- Copy and paste are intentionally split by layer: tmux owns pane-local text selection and copy, while WezTerm owns the smart system clipboard paste path.
- tmux explicitly uses `set-clipboard external`, so copying from tmux copy-mode writes to the system clipboard through OSC 52.
- Outside tmux copy-mode, plain left clicks are consumed by tmux only to focus the pane under the mouse.
- Outside tmux copy-mode, plain left drag does not start any selection path; use `Shift+drag` to start tmux pane-local selection from normal mode.
- Wheel scrolling may move tmux into its copy-mode-backed scrollback state, and tmux selects the pane under the mouse before entering that state.
- Copy-mode entry and exit via directional inputs follow a single symmetric rule: the first press at a boundary only switches mode without scrolling. Upward keys (`PageUp`, `Shift+Up`, wheel-up) entering from the live prompt do not jump, and downward inputs (`PageDown`, `Shift+Down`, wheel-down) at the live bottom exit copy-mode on a single press rather than auto-exiting mid-scroll.
- The `WheelUpPane` guard is `alternate_on || pane_in_mode` and intentionally omits `mouse_any_flag`. TUIs that enable mouse tracking but do not implement wheel scrolling (notably `claude-cli` and similar AI CLIs) would otherwise silently swallow the wheel. The trade-off is that `alternate_on=0` TUIs such as `fzf` or `lazygit` also yield their wheel handling to tmux scrollback inside a tmux pane.
- Releasing the mouse after a drag does not auto-copy or auto-cancel.
- `Ctrl+c` is uniform inside tmux copy-mode: when a selection is present it copies without leaving copy-mode; without a selection it cancels copy-mode.
- This config does not expose a normal WezTerm cross-pane drag-selection path by default; terminal-wide selection is still available when you hold `SUPER`.
- `Ctrl+c` first checks for a WezTerm terminal selection and copies it if one exists; otherwise it sends a normal terminal `Ctrl+c`.
- tmux emits terminal focus-in and focus-out events to applications, which helps mouse-aware TUIs recover cleanly when the WezTerm window regains focus.
- The active pane keeps the base cream background (`#f1f0e9`) while inactive panes render a slightly darker cream (`#eae9e1`), so the focused pane is visually distinct via body tint rather than border color. Pane borders stay muted beige in both states.

## Agent Attention

The agent-attention pipeline (state file, hook install, transitions, rendering, the `Alt+,` / `Alt+.` / `Alt+/` keyboard entry points, focus-based auto-ack, Codex integration) lives in [`agent-attention.md`](./agent-attention.md).

In tmux UI terms what shows up here is: a per-tab badge (a 1-cell `█` block in warm-orange / cool-blue / muted-green for waiting / running / done) and the right-status `🚨 N waiting  ✅ N done  🔄 N running` counter, both rendered by `wezterm-x/lua/attention.lua` from the shared state file. The tab badge stays color-only because the tab strip is dense and emoji at 2-cell width felt visually heavy; the right-status counter and the `Alt+/` picker keep emoji because their adjacent text labels need the visual anchor. The counter slot is reserved even at zero so the bar width stays stable.

## Status Lines

- The first tmux line renders repo, branch, combined git change counts, tracked-branch sync markers, and Node.js version.
- The git-changes group reads `(+S,~U,?T,<sync>)` where `S` is staged, `U` is unstaged, `T` is untracked, and `<sync>` is one of: `=0` (synced with upstream), `^N` (ahead by N), `vN` (behind by N), `*0` (no upstream — local-only branch never pushed).
- The second tmux line renders the repo family's linked worktree count plus the current worktree role, for example `linked:2 · primary`.
- The worktree line derives its repo family and current role from the active pane's live git state instead of stored tmux metadata.
- The third tmux line renders whenever the WakaTime toggle is enabled.
- Any enabled status section keeps a stable on-screen slot. If live data is unavailable, that section renders placeholder text instead of disappearing.
- A section only disappears completely when its toggle is disabled. If an entire line has no enabled sections, that line does not reserve a status row.
- Node.js version lookup includes an `nvm` fallback and the resolved version is cached.
- WakaTime refresh is cache-backed and reuses summary data for up to 60 seconds.

## Notes

- `default` is not managed by `workspaces.lua`; it remains WezTerm's built-in workspace even though `hybrid-wsl` now boots its WSL tabs through a lightweight tmux session.
- `Alt+p` uses WezTerm's built-in relative workspace switching, so it includes `default`.
- Worktree switching stays inside one repo-family tmux session and updates the active tmux window instead of spawning more top-level WezTerm tabs.
- tmux status refresh is hybrid: the draw path reads cached lines, focus and pane or window change hooks trigger debounced background refreshes, a recommended shell prompt hook (see [`setup.md`](./setup.md#tmux-status-prompt-hook); when the hook is not installed, `git` state can lag up to 30s) force-refreshes after each command so `git` operations reflect immediately, and a 30-second `status-interval` acts as a low-frequency fallback poll.
- WakaTime status sources `wezterm-x/local/shared.env`, and WezTerm Lua also reads that same file for shared scalar values.
