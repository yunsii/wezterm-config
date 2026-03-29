# Tmux And Status

Use this doc when you need visible UI behavior for tabs, panes, or status lines.

## Tab Behavior

- The native Windows title bar stays hidden.
- The tab bar uses the non-fancy style and remains visible at the bottom.
- The tab bar uses padded labels and stronger background highlighting for hover and active tabs rather than explicit separator characters.
- Managed project tabs use stable project directory names as titles.
- If a managed tab has multiple panes, the title prefers a short summary such as `project +1`.
- Unmanaged tabs fall back to working-directory-based title inference.

## Tmux Behavior

- tmux status follows the active pane working directory.
- WezTerm cwd-dependent actions inside tmux still rely on shell integration emitting `OSC 7` from the interactive runtime shell, except for `Alt+o` fallback handling.
- Managed workspace creation only requires `default_domain` in `hybrid-wsl` mode.
- The shell integration currently lives in the runtime shell rc files such as `~/.zshrc` and `~/.bashrc`.
- In `hybrid-wsl`, `Alt+o` uses WezTerm's current-pane cwd plus `wsl.exe --cd ... code .` when WezTerm has a usable WSL cwd.
- In `posix-local`, `Alt+o` launches the configured local VS Code opener directly with the current directory path.
- If WezTerm only sees the WSL host fallback path such as `/C:/Users/...` in `hybrid-wsl`, it forwards `Alt+o` to the pane instead; tmux then launches `code .` from `#{pane_current_path}`.
- If WezTerm only reports `/`, managed workspace tabs still fall back to the tab's configured project directory instead of opening the WSL root.
- `Alt+b` remains a `hybrid-wsl`-only integration because it targets the Windows desktop Chrome launcher.
- The first tmux line can render repo, branch, combined git change counts, tracked-branch sync markers (`^N` ahead, `vN` behind, `=0` synced, `x0` no upstream configured), and Node.js version.
- The second tmux line renders whenever the WakaTime toggle is enabled.
- Any enabled status section keeps a stable on-screen slot. If live data is unavailable, that section renders placeholder text instead of disappearing, which avoids status-bar flicker.
- A section only disappears completely when its toggle is disabled. If an entire line has no enabled sections, that line does not reserve a status row.

## Notes

- `default` is not managed by `workspaces.lua`; it remains WezTerm's built-in workspace.
- `Alt+p` uses WezTerm's built-in relative workspace switching, so it includes `default`.
- WakaTime refresh is cache-backed: tmux repaints every few seconds, while the script reuses cached data for up to 60 seconds and refreshes asynchronously.
- Each status section has its own toggle. If a section is disabled, tmux skips that section's script entirely.
- `@tmux_status_render_repo`, `@tmux_status_render_branch`, `@tmux_status_render_git_changes`, `@tmux_status_render_node`, and `@tmux_status_render_wakatime` all default to `1`.
- Enabled sections use placeholders when needed: branch shows `no-branch`, git changes shows `no-git`, Node.js shows `Node unavailable`, and WakaTime stays visible with placeholder text until real data becomes available.
- Node.js version lookup includes an `nvm` fallback so it still renders outside an interactive login shell.
- `scripts/runtime/open-project-session.sh` remains the stable execution layer for managed project tabs.
- If tmux is reloaded outside the helper scripts, `tmux.conf` derives `@wezterm_repo_root` from the path of the loaded config file so the status commands can still locate the repository scripts.
- If the runtime shell rc changes, reload the shell or recreate affected tmux sessions before expecting WezTerm cwd tracking to update.
- If `~/.zshrc` or `~/.bashrc` is replaced or reset, re-apply the `OSC 7` integration or WezTerm will fall back to incorrect cwd inference inside tmux.
