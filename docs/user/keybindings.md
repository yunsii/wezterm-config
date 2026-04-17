# Keybindings

Use this doc when you need shortcut behavior.

- `Alt+d`: switch to WezTerm built-in `default`
- `Alt+w`: open or switch to `work` using the private directories configured in `wezterm-x/local/workspaces.lua`
- `Alt+c`: open or switch to `config`
- `Alt+p`: rotate through all currently known workspaces
- `Alt+Shift+x`: open a centered WezTerm confirmation overlay to close the current non-default workspace
- `Alt+Shift+q`: quit WezTerm and close all windows; WezTerm will handle any built-in confirmation
- `Alt+v`: split vertically
- `Alt+s`: split horizontally
- `Alt+o`: in `default`, WezTerm opens the current worktree root in VS Code and still falls back to pane handling when it only sees the WSL host path; in non-default managed workspaces, WezTerm forwards the shortcut to tmux so the active tmux window resolves the live worktree before opening VS Code
- `Alt+g`: only in non-default managed workspaces, open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: only in non-default managed workspaces, cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- `Alt+b`: open the configured Chrome debug browser profile from `wezterm-x/local/constants.lua`; in `hybrid-wsl` it uses the synced Windows launcher, and in `posix-local` it uses the synced shell launcher
- `Ctrl+k`: when the current pane is running tmux, open a centered tmux popup command panel with repo-shared commands plus optional machine-local extensions from `wezterm-x/local/command-panel.sh`; the shared `hybrid-wsl` entry force-closes all VS Code windows on the Windows host
- `LeftClick`: inside tmux, use the click only to focus the pane under the mouse; it does not start tmux selection and is not forwarded as a mouse click into the pane application
- `Shift+LeftDrag`: start a tmux pane-local selection inside the current pane, including after wheel scrolling has moved tmux into its scrollback mode; press `Ctrl+c` or `Enter` to copy and exit copy-mode
- `LeftDrag`: plain drag does not start selection, even after wheel scrolling; use `Shift+LeftDrag` for tmux pane-local selection or `Super+LeftDrag` for terminal-wide selection
- `Super+LeftDrag`: bypass tmux mouse reporting and use WezTerm's terminal-wide text selection when you intentionally want to select across pane boundaries; copy it with `Ctrl+c` or `Ctrl+Shift+c`
- `LeftClick` after a tmux selection: when copy-mode already has an active selection, a plain click clears that selection without copying if you are still browsing scrollback; if you are already back at the live bottom, the same click exits copy-mode
- `Ctrl+LeftClick`: open the link under the mouse cursor in the system browser
- `Ctrl+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise send a normal terminal `Ctrl+c`. In tmux copy-mode, `Ctrl+c` keeps the current scrollback position when you are still above the live bottom, and only falls back to copy-and-exit once you are back at the bottom
- `Ctrl+Shift+c`: if the current WezTerm pane has a terminal selection, copy it to the system clipboard and clear the selection; otherwise forward `Ctrl+Shift+c` to the pane
- `Ctrl+v`: smart paste; in Windows-hosted `hybrid-wsl`, a background Windows clipboard listener keeps a cache of exported bitmap images so normal text paste stays low-latency while clipboard images still paste the exported WSL path into the active pane; if that cache is unavailable, fall back to a normal clipboard paste
- `Ctrl+Shift+v`: force a normal clipboard paste without the image-export helper
- `Enter` in tmux copy-mode: copy the current tmux selection to the system clipboard and leave copy-mode
