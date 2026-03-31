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
- WezTerm cwd-dependent actions inside tmux still rely on shell integration emitting `OSC 7` from the interactive runtime shell, except for `Alt+o` fallback handling.
- Managed workspace creation only requires `default_domain` in `hybrid-wsl` mode.
- The shell integration currently lives in the runtime shell rc files such as `~/.zshrc` and `~/.bashrc`.
- In `hybrid-wsl`, `Alt+o` hands the current pane directory to the synced Windows PowerShell launcher, which resolves the repo family's primary worktree and then opens it with VS Code's `--folder-uri vscode-remote://wsl+<distro>/...` entrypoint.
- In `posix-local`, `Alt+o` hands the current pane directory to the runtime-side VS Code launcher, which resolves the repo family's primary worktree and then launches the configured local VS Code opener there.
- Outside git worktrees, `Alt+o` still opens the current directory.
- If WezTerm only sees the WSL host fallback path such as `/C:/Users/...` in `hybrid-wsl`, it forwards `Alt+o` to the pane instead; tmux then resolves `#{pane_current_path}` to the primary worktree before launching `code .`.
- If WezTerm only reports `/`, managed workspace tabs still fall back to the tab's configured project directory instead of opening the WSL root.
- In `hybrid-wsl`, `Alt+b` uses the synced Windows PowerShell launcher for the debug Chrome profile.
- In `posix-local`, `Alt+b` uses the synced shell launcher at `wezterm-x/scripts/focus-or-start-debug-chrome.sh`.
- Mouse drag selection inside tmux copy-mode no longer writes to the system clipboard on release; keep the selection and press `Enter` to copy explicitly instead.
- A plain click inside the pane exits tmux copy-mode without copying, so you do not need to use `Esc` just to return to normal interaction.
- Outside tmux copy-mode, plain left clicks now follow the terminal default path instead of WezTerm's selection-complete binding, so the first click reaches tmux and mouse-aware TUIs as a full click.
- Hold `Shift` while dragging to start tmux copy-mode selection inside the current pane; the selection stays pane-local, and `Ctrl+c` or `Enter` copies it and exits copy-mode.
- Hold `Alt` while dragging to bypass tmux mouse reporting and use WezTerm's terminal-wide text selection path when you intentionally want to select across pane boundaries; copy that selection with `Ctrl+Shift+c`.
- `Ctrl+c` first checks for a WezTerm terminal selection and copies it without forwarding the key; if there is no WezTerm selection, it sends a normal terminal `Ctrl+c`, which lets tmux copy-mode and regular terminal programs handle it normally.
- tmux now emits terminal focus-in and focus-out events to applications, which helps mouse-aware TUIs recover cleanly when the WezTerm window regains focus.
- The first tmux line renders repo, branch, combined git change counts, tracked-branch sync markers (`^N` ahead, `vN` behind, `=0` synced, `x0` no upstream configured), and Node.js version.
- The second tmux line renders the repo family's linked worktree count plus the current worktree role, for example `linked:2 · primary` in the main worktree or `linked:2 · linked` in a linked worktree.
- The third tmux line renders whenever the WakaTime toggle is enabled.
- Any enabled status section keeps a stable on-screen slot. If live data is unavailable, that section renders placeholder text instead of disappearing, which avoids status-bar flicker.
- A section only disappears completely when its toggle is disabled. If an entire line has no enabled sections, that line does not reserve a status row.
- Managed git project tabs keep one tmux session per repo family and use tmux windows, not WezTerm tabs, to switch between linked worktrees.
- The `config` workspace stays anchored to the repo family's primary worktree tab, even when the synced runtime came from a linked worktree checkout.
- If a synced linked checkout disappears after a reclaim, tmux status and `Alt` worktree helpers fall back to that repo family's primary worktree scripts automatically.
- The `worktree-task` skill reuses the current repo family's tmux session for new linked task worktrees and applies the cleaned-up task prompt only to the newly created window.

## Notes

- `default` is not managed by `workspaces.lua`; it remains WezTerm's built-in workspace.
- `Alt+p` uses WezTerm's built-in relative workspace switching, so it includes `default`.
- `Alt+g` opens a centered tmux popup worktree picker for the current repo family, and `Alt+Shift+g` cycles to the next linked worktree in that same tmux session.
- The `Alt+g` picker runs inside its own tmux popup pane instead of a `display-menu`, which keeps the picker stable even while the active pane is doing full-screen redraws.
- Successful worktree switches update the active tmux window silently instead of showing a transient tmux banner.
- tmux status refresh is hybrid: the draw path reads cached lines, focus and pane/window change hooks trigger debounced background refreshes, and a 30-second `status-interval` acts as a low-frequency fallback poll.
- `Alt+g` and other tmux worktree switches request a fresh status recompute after selecting the target window, so repo, branch, and git-change state usually update without waiting for the fallback poll.
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
- If tmux is reloaded outside the helper scripts, `tmux.conf` derives `@worktree_task_repo_root` from the path of the loaded config file so the status commands can still locate the repository scripts.
- If the runtime shell rc changes, reload the shell or recreate affected tmux sessions before expecting WezTerm cwd tracking to update.
- If `~/.zshrc` or `~/.bashrc` is replaced or reset, re-apply the `OSC 7` integration or WezTerm will fall back to incorrect cwd inference inside tmux.
