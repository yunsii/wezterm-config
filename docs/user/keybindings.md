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
- `Alt+o`: open the current repo family's primary worktree in VS Code; outside git worktrees it still uses the current directory, and when WezTerm only sees the WSL host fallback path it forwards `Alt+o` to the pane so tmux can resolve the real path first
- `Alt+g`: open a centered tmux popup worktree picker for the current repo family; selecting an unopened worktree creates its tmux window on demand
- `Alt+Shift+g`: cycle to the next git worktree in the current repo family, creating the tmux window on demand when needed
- `Alt+b`: open the configured Chrome debug browser profile from `wezterm-x/local/constants.lua`; in `hybrid-wsl` it uses the synced Windows launcher, and in `posix-local` it uses the synced shell launcher
- `LeftClick`: complete selection only; links do not open unless `Ctrl` is held
- `Ctrl+LeftClick`: open the link under the mouse cursor in the system browser
- `Ctrl+c`: copy selection, otherwise send normal `Ctrl+c`
- `Ctrl+v`: smart paste; in Windows-hosted `hybrid-wsl`, if the current Windows clipboard content is a bitmap image, export it to a temporary `.png` on the Windows host and paste its WSL path into the active pane; otherwise do a normal clipboard paste
- `Ctrl+Shift+v`: force a normal clipboard paste without the image-export helper
- `Enter` in tmux copy-mode: copy the current tmux selection to the system clipboard and leave copy-mode
