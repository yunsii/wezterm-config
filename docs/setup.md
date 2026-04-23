# Setup

Use this doc when you need prerequisites and local setup.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `tmux` must be available in the runtime environment that will host managed project tabs.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY` in `wezterm-x/local/shared.env`.
- Repo-local helper wrappers such as `scripts/runtime/agent-clipboard.sh` require `hybrid-wsl`, `cmd.exe`, `powershell.exe`, `wslpath`, and a synced Windows helper runtime.

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

The agent-attention feature (see [`tmux-ui.md`](./tmux-ui.md#agent-attention) and [`keybindings.md`](./keybindings.md#agent-attention)) expects Claude Code to emit OSC 1337 user vars from four hook events (`UserPromptSubmit`, `Notification`, `Stop`, `PostToolUse`). The hook script ships in this repo at `scripts/claude-hooks/emit-agent-status.sh` and is keyboard-first: when it runs it only decorates the pane, so installing it globally is safe and a no-op in non-WezTerm terminals.

> **Upgrading from an earlier version of this doc** — the hook argument for `UserPromptSubmit` changed from `cleared` to `running`. If your existing `~/.claude/settings.json` still points at `... emit-agent-status.sh cleared`, swap it for `running`. Claude Code re-reads `settings.json` on every hook firing, so the change takes effect on the next event (send a fresh prompt to exercise `UserPromptSubmit`) — no Claude restart needed. Use the verification command at the bottom of this section to confirm the new command is firing.

### Install / update

Merge the block below into the `hooks` section of `~/.claude/settings.json` (do not replace the file). Four hook events, each with one shell invocation:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": "/home/yuns/github/wezterm-config/scripts/claude-hooks/emit-agent-status.sh running" }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          { "type": "command", "command": "/home/yuns/github/wezterm-config/scripts/claude-hooks/emit-agent-status.sh waiting" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/home/yuns/github/wezterm-config/scripts/claude-hooks/emit-agent-status.sh done" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "/home/yuns/github/wezterm-config/scripts/claude-hooks/emit-agent-status.sh resolved" }
        ]
      }
    ]
  }
}
```

Substitute the absolute path for your clone if different. `jq` is optional — with it, the hook reads `.session_id` from the piped hook payload and extracts `.message` / `.stop_reason` / `.prompt` as the state entry's `reason`; without it, the hook still writes the entry but keys it to `pane:<WEZTERM_PANE>` and uses canned per-status labels. There is no Windows dependency; the hook script writes only the `attention_tick` OSC to `/dev/tty` in the enclosing WezTerm pane.

### What each hook does

- `UserPromptSubmit → running` lights the `⟳ N running` counter the moment a turn begins so the user can see at a glance which panes are mid-turn.
- `Notification → waiting` raises the `⚠ N waiting` counter only for `permission_prompt` / `elicitation_dialog` notifications (other notification types, notably `idle_prompt`, are re-routed to `done` so they do not re-raise a stale waiting). Sticky: a second `waiting` on a session whose current status is already `waiting` is a no-op, so repeated prompts inside one turn do not oscillate the counter.
- `Stop → done` flips the entry to `done` when the turn ends, so the `✓ N done` counter surfaces work that finished while you were elsewhere.
- `PostToolUse → resolved` flips `waiting` back to `running` the moment a permission prompt is allowed (the tool runs and completes, so the `⚠` counter drains immediately into `⟳`); no-op for any other current status, so auto-allowed tools do not churn the state.

Without `UserPromptSubmit → running` the `⟳ running` counter will never light up, and without `PostToolUse → resolved` the `⚠ waiting` counter will linger from the permission prompt all the way until `Stop` fires at the end of the turn.

### After editing settings.json

Claude Code re-reads `settings.json` on each hook firing, so an edit takes effect immediately — no Claude restart is required. Exercise the new hook by sending a prompt in each Claude pane, then verify from a WSL shell:

```bash
tail -200 ~/.local/state/wezterm-runtime.log \
  | grep -a 'status="running"' \
  | sed -n 's/.*session_id="\([^"]*\)".*/\1/p' \
  | sort -u
```

You should see one UUID per active pane. If the list only shows `pane:<N>` entries (the script's fallback key when no Claude payload is piped in) or is empty, the `running` hook is not wired — double-check `~/.claude/settings.json` points at `... emit-agent-status.sh running` (not `cleared`) and that the hook script is executable.

### Codex integration

Codex's hook surface is narrower than Claude Code's: `~/.codex/config.toml`'s `notify` fires once per `agent-turn-complete`, equivalent to Claude's `Stop` hook, and there is no stable event yet for permission prompts or for the user submitting the next prompt. Codex's `hooks.json` lifecycle system, which would let us wire `waiting` and `cleared`, is still under development upstream (tracked in [openai/codex#2150](https://github.com/openai/codex/discussions/2150) and [#15497](https://github.com/openai/codex/issues/15497)).

Practical consequence for this repo:

- Wiring `notify` to `emit-agent-status.sh done` would give a half-integration — `done` badges and counts work, but those entries would never auto-clear on the next prompt. You would rely on the 30-minute TTL, a fresh `Stop` overwrite, or the `Alt+/` clear-all sentinel.
- Codex's `notify` payload does not publish a stable `session_id` today, so the hook's fallback key (`pane:<WEZTERM_PANE>`) would be used. In the hybrid-wsl one-agent-per-pane layout this still dedupes correctly; mixing Claude and Codex in the same WezTerm pane is not supported in that mode.
- Nothing Codex-specific ships in `~/.codex/config.toml` from this repo. When the upstream lifecycle hooks GA and cover the `waiting` / `cleared` / `resolved` equivalents, integration collapses to adding the matching `notify`/`hooks.json` entries that call the same `emit-agent-status.sh waiting|done|cleared|resolved` interface — no changes in the hook script or Lua side.

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
