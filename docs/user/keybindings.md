# Keybindings

Use this doc when you need shortcut behavior.

- `Alt+d`: switch to WezTerm built-in `default`
- `Alt+w`: open or switch to `work` using the private directories configured in `wezterm-x/local/workspaces.lua`
- `Alt+c`: open or switch to `config`
- `Alt+p`: rotate through all currently known workspaces
- `Alt+Shift+x`: open a centered WezTerm confirmation overlay to close the current non-default workspace
- `Alt+Shift+q`: quit WezTerm and close all windows; WezTerm will handle any built-in confirmation
- `Alt+v`: in any tmux-backed pane, forward to tmux so the active tmux window resolves the live worktree first and, in `hybrid-wsl`, uses the Windows native helper request path; outside tmux, WezTerm opens the current worktree root in VS Code directly and still falls back to pane handling when it only sees the WSL host path
- `Alt+g`: in any tmux-backed pane, open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: in any tmux-backed pane, cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- `Alt+b`: open the configured Chrome debug browser profile from `wezterm-x/local/constants.lua`; in `hybrid-wsl` it uses the same Windows native helper/front-focus path as `Alt+v`, and in `posix-local` it stays unavailable until a native host helper exists
- `Ctrl+Shift+P`: when the current pane is running tmux, open the tmux-owned searchable command palette with repo-shared commands plus optional machine-local extensions from `wezterm-x/local/command-panel.sh`; outside tmux it falls back to WezTerm's native command palette. tmux refresh commands now live here:
- `Refresh current tmux window`: respawn only the focused tmux window in place
- `Refresh current tmux session`: rebuild the attached tmux session through a replacement session so the attached client keeps rendering
- `Refresh current workspace sessions`: confirm and rebuild every tmux session in the current workspace through replacement sessions
- `Refresh all tmux sessions`: confirm and rebuild every tmux session on the current tmux server through replacement sessions
- `Ctrl+k`: tmux chord prefix; in tmux-backed panes, built-in follow-up keys include `v` for vertical split, `h` for horizontal split, and `x` for force-closing all VS Code windows on the Windows host in `hybrid-wsl`. After `Ctrl+k`, tmux temporarily overlays a generic VS Code-style waiting hint in the status area until you press a follow-up key or cancel with `Esc`
- `Ctrl+Shift+;`: open WezTerm's native command palette directly
- `LeftClick`: inside tmux, use the click only to focus the pane under the mouse; it does not start tmux selection and is not forwarded as a mouse click into the pane application
- `Shift+LeftDrag`: start a tmux pane-local selection inside the pane under the mouse, including when that pane was not previously focused and after wheel scrolling has moved tmux into its scrollback mode; press `Ctrl+c` to copy while keeping the selection visible, or `Enter` to copy and exit copy-mode
- `LeftDrag`: plain drag does not start selection, even after wheel scrolling; use `Shift+LeftDrag` for tmux pane-local selection or `Super+LeftDrag` for terminal-wide selection
- `Super+LeftDrag`: bypass tmux mouse reporting and use WezTerm's terminal-wide text selection when you intentionally want to select across pane boundaries; copy it with `Ctrl+c` or `Ctrl+Shift+c`
- `LeftClick` in tmux scrollback: without an active selection it moves the tmux scrollback cursor to the clicked cell; with an active selection it clears that selection without copying if you are still browsing scrollback, and exits copy-mode once you are already back at the live bottom
- `WheelUp` in tmux on an unfocused pane: first retarget tmux to the pane under the mouse, then enter scrollback/copy-mode there
- `Ctrl+LeftClick`: open the link under the mouse cursor in the system browser
- `Ctrl+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise send a normal terminal `Ctrl+c`. In tmux copy-mode, `Ctrl+c` copies the current selection without leaving copy-mode, regardless of whether you entered it via wheel scroll or `Shift+drag`
- `Ctrl+Shift+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise forward `Ctrl+Shift+c` to the pane
- `Ctrl+v`: smart paste; in Windows-hosted `hybrid-wsl`, WezTerm asks the Windows native helper for the live clipboard state over IPC at paste time, falls back to a normal clipboard paste for text, and pastes the exported WSL image path when the latest clipboard content is an image
- `Ctrl+Shift+v`: force a normal clipboard paste without the image-export helper
- `Enter` in tmux copy-mode: copy the current tmux selection to the system clipboard and leave copy-mode
