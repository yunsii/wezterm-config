# Overview

Use this doc when you need the minimum setup and navigation context.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `posix-local` does not yet have a native host-helper for desktop integrations. A future native host-helper should mirror the Windows model: a stable per-user native agent outside the synced runtime, with source under `native/host-helper/<platform>/`.
- `tmux` must be available in the runtime environment that will host managed project tabs.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY` in `wezterm-x/local/shared.env`.

### Fonts

The terminal font uses a platform-aware fallback chain defined in `default_terminal_font()` inside `wezterm-x/lua/constants.lua`. WezTerm tries each font in order and skips any that are not installed.

| Priority | Windows | macOS | Linux |
|----------|---------|-------|-------|
| 1 | Fira Code Retina | Fira Code Retina | Fira Code Retina |
| 2 | Cascadia Code | Menlo | DejaVu Sans Mono |
| 3 | Consolas | PingFang SC | Noto Sans CJK SC |
| 4 | Microsoft YaHei | Hiragino Sans GB | — |
| 5 | Noto Sans CJK SC | Noto Sans CJK SC | — |

- The primary font is Fira Code Retina for code/ASCII glyphs.
- Each platform falls back to a system-bundled monospace font (Cascadia Code / Menlo / DejaVu Sans Mono) when Fira Code is unavailable.
- CJK characters fall back to the platform-native CJK font (Microsoft YaHei on Windows, PingFang SC + Hiragino Sans GB on macOS).
- Noto Sans CJK SC serves as the cross-platform CJK fallback at the end of every chain.
- Override `fonts.terminal` in `wezterm-x/local/constants.lua` to customize the chain per machine.

## Local Setup

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Edit `wezterm-x/local/constants.lua` for your `runtime_mode`, runtime shell, managed CLI theme variant, and any optional OS-specific integrations such as `default_domain` or Chrome debug profile path. In `hybrid-wsl`, WSL tabs now boot through tmux by default, while `Alt+b` and `Alt+v` are handled by the native Windows host helper over the stable local IPC endpoint and require `chrome_debug_browser.user_data_dir` for the debug-browser path.
3. Edit `wezterm-x/local/shared.env` for shared scalar values that both Lua and shell scripts need, such as `WAKATIME_API_KEY` and the machine-local `MANAGED_AGENT_PROFILE`.
4. Optionally create `~/.config/worktree-task/config.env` when you need to point globally installed `worktree-task` back at a tracked `wezterm-config` repo with `WEZTERM_CONFIG_REPO=/absolute/path`.
5. Edit `wezterm-x/local/workspaces.lua` for your private project directories.
6. Optionally edit `wezterm-x/local/command-panel.sh` for machine-local tmux command palette entries exposed through `Ctrl+Shift+P`.

## Repo Entry Points

- `wezterm.lua`: main WezTerm config
- `agent-profiles/`: versioned source for user-level reusable agent profiles hosted in this repo; these files are for external user-level entrypoints such as `~/.codex/AGENTS.md` or `~/.claude/CLAUDE.md`, not for repo-local runtime behavior
- `wezterm-x/workspaces.lua`: shared public workspace baseline and per-project startup defaults
- `wezterm-x/local.example/`: tracked templates for private machine-local overrides
- `wezterm-x/local.example/command-panel.sh`: tracked template for private machine-local tmux command palette items
- `wezterm-x/local.example/shared.env`: tracked template for simple shared scalar values used by both Lua and shell runtime code
- `wezterm-x/local/`: gitignored machine-local overrides that are still copied by the sync skill
- `config/worktree-task.env`: tracked repo profile for the self-contained worktree-task skill, including the explicit `wezterm-config` repo pointer used to collect shared task-launch conventions; legacy `.worktree-task/config.env` remains a compatibility fallback
- `wezterm-x/lua/`: WezTerm Lua modules synced under the target home directory's `.wezterm-x`
- `skills/wezterm-runtime-sync/`: agent skill and scripts that own runtime sync and prompt regression checks
- `skills/worktree-task/`: agent skill, core libraries, and built-in providers for linked task worktrees
- `tmux.conf`: tmux layout and status line rendering
- `scripts/runtime/open-project-session.sh`: tmux session bootstrap for managed project tabs
- `scripts/runtime/run-managed-command.sh`: launcher for managed workspace startup commands
- `skills/worktree-task/scripts/worktree-task`: unified linked worktree task CLI
- `wezterm-x/scripts/`: thin runtime bootstrap/install scripts
- `native/host-helper/windows/`: Windows native host-helper source for `helper-manager.exe` and `helperctl.exe`
- `scripts/dev/`: repo-local maintenance helpers
- `skills/wezterm-runtime-sync/scripts/sync-runtime.sh`: skill-owned sync implementation; the public workflow is to use the `wezterm-runtime-sync` skill
- `skills/worktree-task/scripts/providers/tmux-agent.sh`: built-in tmux agent provider for linked task worktrees

## Read Next

- For workspace behavior or editing workspace items, read [`workspaces.md`](./workspaces.md).
- For shortcuts, read [`keybindings.md`](./keybindings.md).
- For tmux or tab behavior, read [`tmux-and-status.md`](./tmux-and-status.md).
- For syncing and verification, read [`maintenance.md`](./maintenance.md).
