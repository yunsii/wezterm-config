# Tmux And Status

Use this doc when you need visible UI behavior for tabs, panes, or status lines.

## Tab Behavior

- The native Windows title bar stays hidden.
- The tab bar uses the non-fancy style and remains visible at the bottom.
- The tab bar uses padded labels and stronger background highlighting for hover and active tabs rather than explicit separator characters.
- The left side of the tab bar shows the current workspace as a tinted badge that sits flush against the tab strip; `default` stays neutral, while managed workspaces use category-specific background colors when configured.
- Managed project tabs use stable project directory names as titles.
- If a managed tab has multiple panes, the title prefers a short summary such as `project +1`.
- Unmanaged tabs fall back to working-directory-based title inference.

## Tmux Behavior

- tmux status follows the active pane working directory.
- `default` stays WezTerm-owned for repo-aware shortcuts, while non-default managed workspaces delegate `Alt+o`, `Alt+g`, `Alt+Shift+g`, and `Ctrl+k` straight to tmux.
- Managed workspace creation only requires `default_domain` in `hybrid-wsl` mode.
- Managed tmux flows no longer require shell rc `OSC 7` integration; tmux status and tmux-owned shortcuts resolve cwd from tmux's own `pane_current_path`.
- Outside tmux in `hybrid-wsl`, `Alt+o` hands the current pane directory to the synced Windows PowerShell launcher, which resolves the current worktree root, re-focuses a cached matching VS Code project window when available, and otherwise opens the target with VS Code's `--folder-uri vscode-remote://wsl+<distro>/...` entrypoint.
- Outside tmux in `posix-local`, `Alt+o` hands the current pane directory to the runtime-side VS Code launcher, which resolves the current worktree root and then launches the configured local VS Code opener there.
- Outside git worktrees, `Alt+o` still opens the current directory.
- In managed workspaces, `Alt+o` is forwarded directly to tmux so the active tmux window resolves the live worktree path first and, in `hybrid-wsl`, then uses the same Windows helper/front-focus path as the `default` workspace instead of `code .`.
- If WezTerm only sees the WSL host fallback path such as `/C:/Users/...` in `hybrid-wsl`, `Alt+o` also forwards to the pane instead of using the stale host-side path.
- In `hybrid-wsl`, `Alt+b` uses the same Windows helper/front-focus path as `Alt+o` for the debug Chrome profile, with the direct launcher kept only as fallback.
- In `posix-local`, `Alt+b` uses the synced shell launcher at `wezterm-x/scripts/focus-or-start-debug-chrome.sh`.
- `Ctrl+k` opens a centered tmux popup command panel whenever the current pane is running tmux; repo-shared commands appear alongside any machine-local entries from `wezterm-x/local/command-panel.sh`.
- The shared `hybrid-wsl` command panel entry force-closes all VS Code windows on the Windows host with `taskkill /IM code.exe /F`.
- Copy and paste are intentionally split by layer: tmux owns pane-local text selection and copy, while WezTerm owns the smart system clipboard paste path.
- tmux explicitly uses `set-clipboard external`, so copying from tmux copy-mode writes to the system clipboard through the terminal's OSC 52 clipboard path instead of keeping a separate terminal-side selection flow.
- Outside tmux copy-mode, plain left clicks are consumed by tmux only to focus the pane under the mouse; tmux does not turn that click into a selection, and the pane application does not receive it as a mouse click.
- Outside tmux copy-mode, plain left drag still does not start any selection path, which avoids accidental cross-pane selections in the default two-pane layout; use `Shift+drag` to start tmux pane-local selection from normal mode.
- Wheel scrolling may move tmux into its copy-mode-backed scrollback state, but plain left drag still does not start a selection there; `Shift+drag` remains the only tmux pane-local selection entrypoint.
- Releasing the mouse after a drag does not auto-copy or auto-cancel; keep the selection visible and press `Enter` or `Ctrl+c` to copy explicitly and exit copy-mode.
- In tmux scrollback, a plain click without an active selection repositions the copy-mode cursor to the clicked cell; when a selection is active, the same click clears that selection without copying if the pane is still above the live bottom, and exits copy-mode once the pane is back at the live bottom.
- `Ctrl+c` follows the same split: above the live bottom it copies the current tmux selection without leaving scrollback, and at the live bottom it copies and exits copy-mode.
- This config does not expose a normal WezTerm cross-pane drag-selection path by default; `bypass_mouse_reporting_modifiers` is parked on `SUPER`, so pane-local selection remains the default mental model and terminal-wide selection is still available when you hold that modifier intentionally.
- `Ctrl+c` first checks for a WezTerm terminal selection and copies it if one exists; otherwise it sends a normal terminal `Ctrl+c`, which means tmux copy-mode copies the current selection and regular shells and TUIs still receive interrupt as usual.
- In `hybrid-wsl`, `Ctrl+v` smart image paste is cache-backed: a background Windows clipboard listener exports bitmap clipboard content ahead of time, so ordinary text paste does not block on synchronous clipboard image checks.
- tmux now emits terminal focus-in and focus-out events to applications, which helps mouse-aware TUIs recover cleanly when the WezTerm window regains focus.
- The first tmux line renders repo, branch, combined git change counts, tracked-branch sync markers (`^N` ahead, `vN` behind, `=0` synced, `x0` no upstream configured), and Node.js version.
- The second tmux line renders the repo family's linked worktree count plus the current worktree role, for example `linked:2 · primary` in the main worktree or `linked:2 · linked` in a linked worktree.
- The worktree line derives its repo family and current role from the active pane's live git state instead of stored tmux worktree metadata.
- The third tmux line renders whenever the WakaTime toggle is enabled.
- Any enabled status section keeps a stable on-screen slot. If live data is unavailable, that section renders placeholder text instead of disappearing, which avoids status-bar flicker.
- A section only disappears completely when its toggle is disabled. If an entire line has no enabled sections, that line does not reserve a status row.
- Managed git project tabs keep one tmux session per repo family and use tmux windows, not WezTerm tabs, to switch between linked worktrees.
- Within managed workspaces, `Alt+g` and `Alt+Shift+g` work for any tmux window whose current pane or active window layout still resolves to a git worktree, including linked worktrees created outside the managed launcher flow.
- The `config` workspace stays anchored to the repo family's primary worktree tab, even when the synced runtime came from a linked worktree checkout.
- If a synced linked checkout disappears after a reclaim, tmux status and `Alt` worktree helpers fall back to that repo family's primary worktree scripts automatically.
- When `Alt+g` opens a linked worktree that does not already have a tmux window, tmux clones the current window's pane layout and remaps pane directories into the target worktree instead of relying on stored per-session startup metadata.
- The `worktree-task` skill reuses the current repo family's tmux session and finds reclaim cleanup windows from live git context, and it still applies the cleaned-up task prompt only to the newly created window while keeping the launched agent CLI configurable.

## Notes

- `default` is not managed by `workspaces.lua`; it remains WezTerm's built-in workspace.
- `Alt+p` uses WezTerm's built-in relative workspace switching, so it includes `default`.
- `Alt+g` opens a centered tmux popup worktree picker for the current repo family, and `Alt+Shift+g` cycles to the next linked worktree in that same tmux session, but only inside non-default managed workspaces.
- `Ctrl+k` follows the same tmux popup model as `Alt+g`, but it is not git-worktree-specific; any tmux pane can open it.
- The `Alt+g` picker runs inside its own tmux popup pane instead of a `display-menu`, which keeps the picker stable even while the active pane is doing full-screen redraws.
- Successful worktree switches update the active tmux window silently instead of showing a transient tmux banner.
- tmux status refresh is hybrid: the draw path reads cached lines, focus and pane/window change hooks trigger debounced background refreshes, and a 30-second `status-interval` acts as a low-frequency fallback poll.
- `Alt+g` and other tmux worktree switches force an immediate status recompute after selecting the target window, so repo, branch, and git-change state update without waiting for the fallback poll or force-refresh debounce.
- WakaTime refresh is cache-backed: the status script reuses cached summary data for up to 60 seconds, refreshes asynchronously, and upgrades older JSON cache entries to the current compact summary format.
- WakaTime status sources `wezterm-x/local/shared.env`, and WezTerm Lua also reads that same file for shared scalar values; both sides currently use it for `WAKATIME_API_KEY`.
- WakaTime status no longer depends on WezTerm injecting the API key into the WSL shell environment; reloading tmux is enough after updating `shared.env`.
- The first tmux line still shows the active git branch; the second line only distinguishes the current worktree as `primary` or `linked` to avoid repeating the branch or worktree name.
- Each status section has its own toggle. If a section is disabled, tmux skips that section's script entirely.
- `@tmux_status_render_repo`, `@tmux_status_render_worktree`, `@tmux_status_render_branch`, `@tmux_status_render_git_changes`, `@tmux_status_render_node`, and `@tmux_status_render_wakatime` all default to `1`.
- `@tmux_status_poll_interval` defaults to `30`, matching the low-frequency fallback poll.
- Enabled sections use placeholders when needed: the worktree line shows `no-worktree` outside git worktrees, branch shows `no-branch`, git changes shows `no-git`, Node.js shows `Node unavailable`, and WakaTime stays visible with placeholder text until real data becomes available.
- Node.js version lookup includes an `nvm` fallback so it still renders outside an interactive login shell, and the resolved version is cached to avoid repeated shell bootstrap on every status refresh.
- `scripts/runtime/open-project-session.sh` remains the stable execution layer for managed project tabs.
- If tmux is reloaded outside the helper scripts, `tmux.conf` derives `@wezterm_runtime_root` from the path of the loaded config file so the status commands can still locate the synced runtime scripts.
- Optional shell rc `OSC 7` integration can still improve WezTerm-side cwd inference for unmanaged tabs, fallback tab-title inference, and `default` workspace `Alt+o` behavior inside tmux.
