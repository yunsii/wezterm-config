# Setup

Use this doc when you need prerequisites and local setup.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `tmux 3.6+` must be available in the runtime environment that will host managed project tabs. Required because the repo's `tmux.conf` advertises DEC mode 2026 (synchronized output) and tmux 3.4 deadlocks on stuck sync windows where 3.6's 1-second flush timeout does not. Ubuntu 24.04 LTS still ships 3.4, so build 3.6+ from source if your distro lags. Background, verification recipe, and the IME-flicker symptom that originally drove this requirement: [`ime-flicker-and-sync-output.md`](./ime-flicker-and-sync-output.md).
- `lua5.4` (or `lua5.3` / `lua`) **recommended** in the WSL/Linux side. Used by `wezterm-runtime-sync`'s `lua-precheck` step (`skills/wezterm-runtime-sync/scripts/lua-precheck.lua`) to dofile the synced `wezterm-x/lua/constants.lua` under a mocked `wezterm` module and assert that managed-launcher resolution still works (`default_profile` resolves, `default_resume_profile ≠ default_profile`, the resume command literally contains `--continue` or `resume`). Without it, sync skips the precheck with a warning instead of failing — same surface that historically let `<base>-resume` vs `<base>_resume` mis-naming and unreachable WSL-path env files slip through to runtime. Install with `sudo apt install lua5.4` on Ubuntu/Debian.
- `go 1.21+` **recommended** in the WSL/Linux side. Used by `wezterm-runtime-sync`'s `build-picker` step (`scripts/runtime/picker/build.sh`, invoked from `skills/wezterm-runtime-sync/scripts/sync-runtime.sh`) to compile the static `scripts/runtime/picker/bin/picker` ELF that powers the three high-frequency tmux popups: `Alt+/` (attention), `Alt+g` (worktree), and `Ctrl+Shift+P` (command palette). The build script auto-discovers `go` in `PATH` → `~/.local/go/bin/go` → `/usr/local/go/bin/go` and silently skips with a one-line note when none are found; the popups then fall back to the bash pickers (`tmux-attention-picker.sh`, `tmux-worktree-picker.sh`, `tmux-command-picker.sh`), which work but cold-start at ~30-80ms vs ~2-5ms for the Go binary (~10×, per `docs/performance.md`). Only direct dep is `golang.org/x/term`. Install with `sudo apt install golang-go` on Ubuntu 24.04+ (ships ≥ 1.22), or download from <https://go.dev/dl/> into `~/.local/go`. After install, run `wezterm-runtime-sync` once and confirm `scripts/runtime/picker/bin/picker` exists and the sync trace logs `step=build-picker status=completed`.
- `jq` **recommended** in the WSL/Linux side. Used by the agent-attention state writer (`scripts/runtime/attention-state-lib.sh`), the focus emit path (`scripts/runtime/tmux-focus-emit.sh`), and the hotkey-usage telemetry (`scripts/runtime/hotkey-usage-bump.sh`); also opportunistically by `scripts/claude-hooks/emit-agent-status.sh` to extract `session_id` / `message` / `prompt` from hook payloads. Without it, the Claude hook still writes attention entries but keys them to `pane:<WEZTERM_PANE>` with canned per-status labels, and the other call sites take their respective degraded paths. Install with `sudo apt install jq` on Ubuntu/Debian.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY` in `wezterm-x/local/shared.env`.
- Repo-local helper wrappers such as `scripts/runtime/agent-clipboard.sh` require `hybrid-wsl`, `cmd.exe`, `powershell.exe`, `wslpath`, and a synced Windows helper runtime.
- In `hybrid-wsl` mode, `wezterm.exe` runs on Windows and its Lua cannot resolve WSL-native paths like `/home/yuns/...`, so `wezterm-runtime-sync` mirrors `config/worktree-task.env` into the runtime dir as `repo-worktree-task.env` (Windows-readable NTFS path) on every sync. Skipping a sync after editing `config/worktree-task.env` will leave wezterm.exe on the previous snapshot. Full pickup chain and the `<base>-resume` / `<base>_resume` naming asymmetry: see [`workspaces.md#behavior`](./workspaces.md#behavior).

## Local Setup

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Edit `wezterm-x/local/constants.lua` for `runtime_mode`, runtime shell, UI variant, and OS-specific integrations such as `default_domain` or Chrome debug profile path.
3. Edit `wezterm-x/local/shared.env` for shared scalar values such as `WAKATIME_API_KEY` and `MANAGED_AGENT_PROFILE`.
4. Edit `wezterm-x/local/workspaces.lua` for your private project directories.
5. Optionally create `~/.config/worktree-task/config.env` when you need to point globally installed `worktree-task` back at a tracked `wezterm-config` repo with `WEZTERM_CONFIG_REPO=/absolute/path`.
6. Optionally edit `wezterm-x/local/command-panel.sh` for machine-local tmux command palette entries exposed through `Ctrl+Shift+P`.
7. One-time: in VS Code, open Profiles → Import Profile → select `wezterm-x/local.example/vscode/ai-dev.code-profile` (or your customized `wezterm-x/local/vscode/ai-dev.code-profile`). `Alt+v` and `scripts/runtime/open-current-dir-in-vscode.sh` read `WEZTERM_VSCODE_PROFILE` from `wezterm-x/local/shared.env` (default `ai-dev`); set it to empty to use VS Code's default profile instead. After import, open the target WSL folder once in the new profile and click "Install in WSL" for each workspace extension you want enabled (GitLens, etc.) — VS Code tracks WSL-remote extensions per profile and does not replicate them automatically. The Windows helper's window-reuse key is `distro + folder`, not profile; if the folder is already open in another profile, `Alt+v` focuses that window instead of launching a new one — close the existing window first.
8. Recommended: source `scripts/runtime/tmux-status-prompt-hook.sh` from your shell rc so the tmux status line reflects local `git` commands immediately instead of lagging up to 30s on the fallback poll. See [Tmux Status Prompt Hook](#tmux-status-prompt-hook) for the source line and a verification command.

## File Boundaries

- `wezterm-x/workspaces.lua`: tracked shared workspace defaults
- `wezterm-x/local/workspaces.lua`: private directories and machine-local workspace overrides
- `wezterm-x/local/shared.env`: shared scalar values used by Lua and shell code
- `wezterm-x/local/constants.lua`: machine-local structured Lua settings
- `wezterm-x/local.example/`: tracked templates for `wezterm-x/local/`

## Repo-Local Runtime Wrappers

- When your automation can already resolve the repository root, prefer repo-local wrappers under `scripts/runtime/` over rebuilding helper IPC or Windows bootstrap logic.
- `scripts/runtime/agent-clipboard.sh` is the current agent-facing clipboard wrapper. It stays in WSL, ensures the Windows helper is healthy, and then writes text or an image file to the Windows clipboard.
- If that wrapper reports that the helper bootstrap is missing, sync the runtime first, then rerun the command.
- `sync-runtime.sh` writes `~/.wezterm-x/agent-tools.env` on the target home. That marker is the primary discovery contract for external agent platforms.
- Read `agent_clipboard` from `~/.wezterm-x/agent-tools.env` instead of inferring wrapper paths from the current task repository or AGENTS symlinks.

## Windows Launch Hotkey

For `hybrid-wsl` on Windows, pin WezTerm to the taskbar together with the two apps you reach most often so the built-in `Win+N` shortcut can launch or focus them without a background hotkey daemon. Recommended layout:

- `Win+1`: WezTerm
- `Win+2`: primary browser
- `Win+3`: primary IM client (Feishu, Slack, Teams, etc.)

Pin each app, then drag the icons so WezTerm sits in slot 1, the browser in slot 2, and the IM client in slot 3. The binding survives reboots, needs no extra tooling, and stays out of the in-WezTerm keymap documented in [`keybindings.md`](./keybindings.md).

## Claude Agent Attention Hooks

Hook install / upgrade template, "what each hook does", verification, and Codex integration live in [`agent-attention.md#hook-installation`](./agent-attention.md#hook-installation). The hook script ships in this repo at `scripts/claude-hooks/emit-agent-status.sh`.

## Tmux Status Prompt Hook

This is a **recommended** part of local setup. The tmux status line polls git state on a 30-second timer and refreshes when you switch pane, window, or client. Neither path fires right after you run a `git` command from the shell, so branch and change counters can lag up to 30s behind reality. The prompt hook closes that gap: every time the shell returns to the prompt, it asks tmux to force-refresh (debounced to 2s by `@tmux_status_force_debounce`, so rapid commands do not stampede).

The hook ships at `scripts/runtime/tmux-status-prompt-hook.sh`. It is safe to re-source, a no-op outside tmux, and self-locates through the tmux `@wezterm_runtime_root` option so the sourcing line does not hardcode a repo path. Add one line to your shell rc:

```sh
# ~/.zshrc (zsh) or ~/.bashrc (bash)
[ -n "$TMUX" ] && . /home/yuns/github/wezterm-config/scripts/runtime/tmux-status-prompt-hook.sh
```

Substitute the absolute path for your clone if different. Existing shells also need `source ~/.zshrc` (or a restart) to pick up the new line.

Verify the hook is active from a tmux pane running the shell you configured:

```sh
typeset -f __tmux_status_prompt_refresh >/dev/null && echo ok || echo missing
```

If it prints `missing`, the rc did not source the hook. Without the hook, the 30s poll and pane-switch hooks keep working unchanged, so `git` state can lag up to 30s before the status line updates.

## IME State Indicator

In `hybrid-wsl` the WezTerm right status bar renders a compact IME state badge so keyboard-first interactions (chord prefixes, `y/n` confirmations, single-letter shortcuts) do not have to guess which input mode is active.

The badge reflects what the Windows host-helper reads from the foreground window, not WezTerm's internal `use_ime` flag:

- `中`: a CJK IME is loaded and currently in native composition mode (about to produce Chinese/Japanese/Korean characters).
- `英`: a CJK IME is loaded but the user has toggled the IME itself to English mode (typically via `Shift` on Microsoft Pinyin, Sogou, QQ, etc.).
- `EN`: the active keyboard layout is a non-CJK language (e.g. `en-US`); IMM composition is not in play.
- `中?` (italic, dim): the helper is unreachable or the IME did not expose a conversion state. Usually transient while the helper is restarting.

The badge is hidden entirely in `posix-local` because no Windows host-helper is running to query IMM. On Windows the helper pulls state via `GetForegroundWindow` → `GetKeyboardLayout` → `ImmGetConversionStatus`, so tapping `Shift` (or your IME's own toggle key) updates the badge within the next `update-status` tick. There is no WezTerm-managed override: the OS IME and this badge agree by construction.

## Windows Script Execution

- For Windows-facing shell automation in this repo, source `scripts/runtime/windows-shell-lib.sh` and run PowerShell through `windows_run_powershell_script_utf8` or `windows_run_powershell_command_utf8`.
- Prefer checked-in `.ps1` entrypoints over ad-hoc inline `powershell.exe -Command ...`; when inline PowerShell is unavoidable, keep the body inside the shared UTF-8 wrapper instead of calling `powershell.exe` directly.
- Do not use `cmd.exe /c dir`, `cmd.exe /c type`, or similar commands for file inspection. Resolve the Windows runtime paths with `scripts/runtime/windows-runtime-paths-lib.sh`, convert to WSL paths there, and then use WSL-native tools such as `ls`, `cat`, and `rg`.
- Keep `cmd.exe` usage limited to ASCII-safe environment discovery such as `%LOCALAPPDATA%` or `%USERPROFILE%`.

## Read Next

- Workspace semantics and config shape:
  Read [`workspaces.md`](./workspaces.md).
- Sync, reload, and verification:
  Read [`daily-workflow.md`](./daily-workflow.md).
- Runtime ownership and entry points:
  Read [`architecture.md`](./architecture.md).
