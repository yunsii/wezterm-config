# Setup

Use this doc when you need prerequisites and local setup.

## Prerequisites

- `hybrid-wsl` uses the Windows WezTerm nightly build plus a WSL domain configured in `wezterm-x/local/constants.lua`.
- `posix-local` runs directly on Linux or macOS without a WSL domain.
- `tmux 3.7+` must be available in the runtime environment that will host managed project tabs (DEC mode 2026 / sync needs 3.6+; copy-mode auto-refresh needs 3.7 `refresh-from-pane`). **If the OS/package-manager `tmux` already meets ≥ 3.7, use it — do not compile a user copy.** Only when the distro package is too old (e.g. Ubuntu 24.04 apt 3.4) install a user-prefix build to `~/.local/bin/tmux` and put that dir first on PATH. Cross-OS decision tree, package options, and fallback script: [`tmux-install.md`](./tmux-install.md). Why the floor: [`ime-flicker-and-sync-output.md`](./ime-flicker-and-sync-output.md).
- **Vim 9.2+ (optional, recommended if you edit in terminal Vim).** `'termsync'` (DEC 2026 synchronized redraw) exists only on 9.2+. Ubuntu 24.04 apt stays on 9.1 — `apt upgrade` cannot get it. Prefer a user-prefix build to `~/.local/bin/vim` (same PATH pattern as the tmux fallback). Merge [`wezterm-x/local.example/vimrc.recommended`](../wezterm-x/local.example/vimrc.recommended) into `~/.vim/vimrc` for `lastline` / `smoothscroll` / tmux DECRPM inject. Scroll/`@`-line / `Shift+drag` behavior: [`tmux-ui.md#vim-in-tmux`](./tmux-ui.md#vim-in-tmux). Details: [Vim 9.2 (optional)](#vim-92-optional).
- **Grok Build focus-filter (optional, recommended if you run `grok` fullscreen in tmux splits — especially WSL→Windows WezTerm).** Stock Grok clears the alt-screen on every FocusGained under tmux (`focus-events on`). Native macOS often makes that clear **invisible** (client redraw usually finishes inside one 60 Hz frame); this hybrid stack still shows a whole-transcript flash even on a tiny pane, so install the filter here. First install / after every `grok update`:

  ```bash
  scripts/runtime/grok-with-focus-filter.sh --install
  scripts/runtime/grok-with-focus-filter.sh --check   # expect ok on ~/.grok/bin/grok + login PATH
  hash -r
  ```

  Puts the wrapper at `~/.grok/bin/grok` with the real binary at `grok.real` (required because Grok prepends `~/.grok/bin` in `~/.zshrc` ahead of `~/.local/bin`). Then **exit / `--resume` every live Grok** — already-running processes keep the old stdin path. `agent-launcher.sh grok` calls the wrapper by absolute path (managed panes stay filtered even if PATH is broken); interactive `grok` still needs `--install`. Full cause, standing ops checklist, macOS timing, WSL size A/B, and `scripts/dev/repro-grok-focus-flash.sh`: [`tmux-ui.md#grok-build-in-tmux`](./tmux-ui.md#grok-build-in-tmux).
- `lua5.4` (or `lua5.3` / `lua`) **recommended** in the WSL/Linux side. Used by `wezterm-runtime-sync`'s `lua-precheck` step (`skills/wezterm-runtime-sync/scripts/lua-precheck.lua`) to dofile the synced `wezterm-x/lua/constants.lua` under a mocked `wezterm` module and assert that managed-launcher resolution still works (`default_profile` resolves, `default_resume_profile ≠ default_profile`, and the resume command contains a recognized sentinel — `--continue`, `resume`, or `agent-launcher.sh`). Without it, sync skips the precheck with a warning instead of failing — same surface that historically let `<base>-resume` vs `<base>_resume` mis-naming and unreachable WSL-path env files slip through to runtime. Install with `sudo apt install lua5.4` on Ubuntu/Debian.
- `jq` **recommended** in the WSL/Linux side. Used by the agent-attention state writer (`scripts/runtime/attention-state-lib.sh`), the focus emit path (`scripts/runtime/tmux-focus-emit.sh`), and the hotkey-usage telemetry (`scripts/runtime/hotkey-usage-bump.sh`); also opportunistically by `scripts/runtime/agent-attention/adapters/*.sh` to extract stable session ids and readable reasons from hook payloads. Without it, attention hooks still write entries but key them to `pane:<WEZTERM_PANE>` with canned per-status labels, and the other call sites take their respective degraded paths. Install with `sudo apt install jq` on Ubuntu/Debian.
- WakaTime status needs `python3` in that same runtime environment and a private `WAKATIME_API_KEY`. Drop it in `~/.config/shell-env.d/wakatime.env` (the canonical home for user-level secrets — see [Env Loading Model](#env-loading-model)) or, equivalently, in `wezterm-x/local/shared.env` if you prefer to keep it next to the rest of the repo-machine config. Both paths feed the unified loader; if both files set the key, `~/.config/shell-env.d/` wins.
- Repo-local helper wrappers such as `scripts/runtime/agent-clipboard.sh` require `hybrid-wsl`, `cmd.exe`, `powershell.exe`, `wslpath`, and a synced Windows helper runtime.
- In `hybrid-wsl` mode, `wezterm.exe` runs on Windows and its Lua cannot resolve WSL-native paths like `/home/yuns/...`, so `wezterm-runtime-sync` mirrors `config/worktree-task.env` into the runtime dir as `repo-worktree-task.env` (Windows-readable NTFS path) on every sync. Skipping a sync after editing `config/worktree-task.env` will leave wezterm.exe on the previous snapshot. Full pickup chain and the `<base>-resume` / `<base>_resume` naming asymmetry: see [`workspaces.md#behavior`](./workspaces.md#behavior).

## Local Setup

1. Copy `wezterm-x/local.example/` to `wezterm-x/local/`.
2. Edit `wezterm-x/local/constants.lua` for `runtime_mode`, runtime shell, UI variant, and OS-specific integrations such as `default_domain` or Chrome debug profile path.
3. Edit `wezterm-x/local/shared.env` for repo-machine config values consumed by both Lua and shell — `MANAGED_AGENT_PROFILE`, `WEZTERM_VSCODE_PROFILE`, `WEZTERM_VSCODE_MAX_WINDOWS`, and so on. For user-level secrets that should not be tied to a specific repo clone (CNB tokens, third-party API keys), prefer `~/.config/shell-env.d/<name>.env` instead — see [Env Loading Model](#env-loading-model) for the contract.
4. Edit `wezterm-x/local/workspaces.lua` for your private project directories.
5. Optionally create `~/.config/worktree-task/config.env` when you need to point globally installed `worktree-task` back at this checkout with `WEZDECK_REPO=/absolute/path` (legacy `WEZTERM_CONFIG_REPO=...` still accepted).
6. Optionally edit `wezterm-x/local/command-panel.sh` for machine-local tmux command palette entries exposed through `Ctrl+Shift+P`.
7. One-time: in VS Code, open Profiles → Import Profile → select `wezterm-x/local.example/vscode/ai-dev.code-profile` (or your customized `wezterm-x/local/vscode/ai-dev.code-profile`). `Alt+v` and `scripts/runtime/open-current-dir-in-vscode.sh` read `WEZTERM_VSCODE_PROFILE` from `wezterm-x/local/shared.env` (default `ai-dev`); set it to empty to use VS Code's default profile instead. After import, open the target WSL folder once in the new profile and click "Install in WSL" for each workspace extension you want enabled (GitLens, etc.) — VS Code tracks WSL-remote extensions separately and reuses the shared WSL server data under `~/.vscode-server`. Set `WEZTERM_VSCODE_MAX_WINDOWS=<n>` in the same file if you want `Alt+v` to stop launching new folder windows after that many visible VS Code windows already exist; already-open folders still reuse their matching window — including ones VS Code restored on startup, which are matched by window title — while genuinely new folders displace the least recently *activated* visible window with `--reuse-window --folder-uri`, Z-order based. The Windows helper's window-reuse key is `distro + folder`, not profile; if the folder is already open in another profile, `Alt+v` focuses that window instead of launching a new one — close the existing window first.
8. Recommended: source `scripts/runtime/tmux-status-prompt-hook.sh` from your shell rc so the tmux status line reflects local `git` commands immediately instead of lagging up to 30s on the fallback poll. See [Tmux Status Prompt Hook](#tmux-status-prompt-hook) for the source line and a verification command.

### Window Transparency / Frosted Glass

Window look is chosen with an **appearance preset**: set
`WEZTERM_APPEARANCE_PRESET` to `opaque` (default) or `frosted` in
`wezterm-x/local/shared.env`. The full model — the layered
window/tmux/tab-bar transparency, why acrylic needs a low opacity, the
`front_end` pitfall, and how the two renderers stay in lockstep — lives in
[appearance-presets.md](./appearance-presets.md). Read that before changing
transparency behavior.

To tune the active preset on one machine, add an `appearance` block to
`wezterm-x/local/constants.lua` (template in `local.example/constants.lua`); it
deep-merges over the preset (applied in `wezterm-x/lua/ui.lua`):

- `window_background_opacity` (0.0–1.0) — whole-window alpha; lower is more see-through (and, with acrylic, more blur).
- `text_background_opacity` (0.0–1.0) — alpha of ANSI-colored cell backgrounds; keep `1.0` so colored segments stay readable.
- `win32_system_backdrop` — Windows 11 (22621+) blur: `'Acrylic'` | `'Mica'` | `'Tabbed'`. Ignored off Windows. Needs a low `window_background_opacity` to show; do NOT set `front_end` alongside it (OpenGL does not compose the DWM backdrop).
- `macos_window_background_blur` — macOS blur radius (integer, e.g. `20`). Ignored off macOS.
- `front_end` — `'OpenGL'` | `'WebGpu'` | `'Software'`. Escape hatch only, for a GPU that renders the default to an opaque swapchain; leave unset otherwise.

Re-run `skills/wezterm-runtime-sync/scripts/sync-runtime.sh` and reload for changes to take effect.

## File Boundaries

- `wezterm-x/workspaces.lua`: tracked shared workspace defaults
- `wezterm-x/local/workspaces.lua`: private directories and machine-local workspace overrides
- `wezterm-x/local/shared.env`: shared scalar values used by Lua and shell code (repo-machine scope)
- `wezterm-x/local/constants.lua`: machine-local structured Lua settings
- `wezterm-x/local.example/`: tracked templates for `wezterm-x/local/`
- `~/.config/shell-env.d/*.env`: user-level secrets and per-user env vars; auto-discovered by both `~/.zshrc` and `scripts/runtime/runtime-env-lib.sh::runtime_env_load_managed`. Mode 600 per file, dir mode 700.

## Env Loading Model

There is one unified env loader for managed-runtime shell scripts: `scripts/runtime/runtime-env-lib.sh`. Any agent / status / hook entry point that needs env should source it and call `runtime_env_load_managed`, which sources two layers in this order (later wins):

1. `wezterm-x/local/shared.env` — repo-machine config (synced to Windows runtime; consumed by both Lua and shell). Use for non-secret machine choices like `MANAGED_AGENT_PROFILE`, `WEZTERM_VSCODE_PROFILE`, `WEZTERM_VSCODE_MAX_WINDOWS`, `WEZTERM_DISK_VOLUME` / `WEZTERM_DISK_RESERVE_GB` (see [diagnostics.md](./diagnostics.md#host-disk-space)), and VS Code launch overrides.
2. `${SHELL_ENV_DIR:-~/.config/shell-env.d}/*.env` in lex order — user-level secrets. Drop a new file there to add a secret; no loader edits, no rc-file edits. The same dir is sourced by `~/.zshrc`, so interactive zsh and machine-spawned agents share one source of truth.

The Lua side reads `shared.env` independently via `helpers.load_optional_env_file`; that is a structural cross-language constraint — Lua cannot call into bash — and is the only second loader implementation that exists.

| Genre | Goes in | Notes |
|---|---|---|
| User-level secret (CNB, OpenAI, …) | `~/.config/shell-env.d/<name>.env` | Mode 600. One file per service. Files are auto-globbed. |
| Claude gateway profile (sub2api) | `~/.config/claude-profiles/sub2api.env` | Mode 600. **Not** auto-globbed — only `agent-launcher.sh claude-sub2api` loads it. See [Claude auth profiles](#claude-auth-profiles). |
| Repo-anchored env (`WEZTERM_REPO`, PATH for `cli/`) | `~/.config/shell-env.d/wezterm-env.env` | Template at `wezterm-x/local.example/shell-env.d/`. |
| Repo-anchored shell helpers (aliases, `cd` functions) | `~/.config/shell-env.d/wezterm-fn.env` | Same template dir. Parent-shell only; runtime-loader treats it as a no-op. |
| User-facing CLI commands | `scripts/runtime/cli/<name>` | No `.sh` suffix. Auto-PATH'd by `wezterm-env.env`. |
| Repo-machine config (Lua + shell) | `wezterm-x/local/shared.env` | Synced to Windows runtime. |
| Repo-machine shell init / functions | `wezterm-x/local/runtime-logging.sh`, `wezterm-x/local/command-panel.sh` | Sourced as bash, not as `.env`. |
| Repo-machine Lua tables | `wezterm-x/local/constants.lua`, `keybindings.lua`, `workspaces.lua` | Lua return-tables. |
| Repo-tracked config | `config/worktree-task.env` | Read literally — values may contain command strings. Never source. |

### Repo-anchored CLI surface

User-facing CLI commands belong in `scripts/runtime/cli/` with no `.sh` suffix (users type the bare word, e.g. `reminders` not `reminders.sh`). The tracked template `wezterm-x/local.example/shell-env.d/wezterm-env.env` prepends that dir to `PATH`, so once a user copies that file into `~/.config/shell-env.d/`, adding a new CLI is a single file drop into `cli/` — no PATH edits, no rc-file edits, no symlinks. The same PATH addition rides into agent-launcher subprocesses via the runtime loader, so commands installed this way are also reachable from machine-spawned agents (Claude Code, Codex CLI, etc.) without extra wiring.

Parent-shell-only helpers — `cd`-ing functions, completion hooks, aliases — belong in the sibling `wezterm-fn.env` template instead. They cannot survive a subprocess boundary, so the runtime loader silently no-ops on them (defines, returns, drops). Prefix function and alias names with `wez-` / `wezterm-` so they cannot shadow a real binary a subprocess might rely on.

For agent-CLI launch chains specifically, `scripts/runtime/agent-launcher.sh` is the single env-loading site (it calls `runtime_env_load_managed` before exec'ing the agent). All managed launch paths — workspace first-open, `Alt+g` on-demand window, `refresh-current-window`, and tab-overflow cold-spawn — terminate at this launcher. Shell paths that resolve the resume argv share `scripts/runtime/worktree/lib/resume-command.sh::resolve_managed_primary_command`. See [`architecture.md#startup-invariants`](./architecture.md#startup-invariants) for the invariant statement.

### Claude auth profiles

Managed Claude has two auth identities that share the same binary and the same `~/.claude` session store; only the **process env at launch** differs.

| Profile (`MANAGED_AGENT_PROFILE`) | Auth | Credentials |
|---|---|---|
| `claude` (default) | Claude.ai OAuth / team subscription | `~/.claude/.credentials.json` (login once). Launcher **clears** `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL` so a leaked parent env cannot override OAuth. |
| `claude_sub2api` | Anthropic-compatible gateway (sub2api, etc.) | `~/.config/claude-profiles/sub2api.env` (or `$CLAUDE_SUB2API_ENV`). Must set `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` (or `ANTHROPIC_API_KEY`). |

**Why not `shell-env.d`?** That directory is sourced for *every* managed agent. Putting gateway keys there would force API auth onto team panes as well. The sub2api file is deliberately outside the auto-glob and is only read by `agent-launcher.sh claude-sub2api`.

**One-time setup**

```bash
mkdir -p ~/.config/claude-profiles
cp wezterm-x/local.example/claude-profiles/sub2api.env \
   ~/.config/claude-profiles/sub2api.env
chmod 600 ~/.config/claude-profiles/sub2api.env
# edit BASE_URL + token
```

**Switch default for new managed panes**

```bash
# wezterm-x/local/shared.env
MANAGED_AGENT_PROFILE='claude_sub2api'   # or 'claude' to go back
```

Then open a new agent window (`Alt+g`) or refresh the current window so a new process starts. Already-running panes keep the identity they were launched with.

**One-shot from an interactive shell** (does not change `MANAGED_AGENT_PROFILE`):

```bash
claude-sub2api          # resume-or-fresh via agent-launcher
claude-sub2api -p 'hi'  # forward args to claude after loading gateway env
```

`claude-sub2api` is on PATH via the `wezterm-env.env` template (`scripts/runtime/cli/`).

**Verify**

```bash
# missing credentials → clear error, exit 1
scripts/runtime/agent-launcher.sh claude-sub2api

# after filling sub2api.env, banner should say "Loading claude-sub2api ..."
# and Claude should bill/route via the gateway (not team 5h limit)
#
# In-session check: /status should show Anthropic base URL = your gateway
# and Auth token = ANTHROPIC_AUTH_TOKEN — not a claude.ai Login row.
```

**OAuth isolation (important)**

`claude-sub2api` sets `CLAUDE_CONFIG_DIR` to
`~/.config/claude-profiles/home` (override with `CLAUDE_SUB2API_HOME`) so the
team OAuth session in `~/.claude/.credentials.json` is **not** loaded.

Without that isolation, Claude Code stays on a hybrid “API keys + Team/Max”
path. After the team 5h limit it tries Anthropic **extra usage** billing and
shows:

> You're logged in with API keys, but haven't purchased any extra usage

even when the gateway itself is healthy (`curl …/v1/messages` returns 200).
The launcher also refuses to keep a `.credentials.json` inside the isolated
home. Hooks/permissions still come from a symlink to
`~/.claude/settings.json`.

**TUI tips when on sub2api**

- Prefer a normal-context model (e.g. `sonnet` / `opus`) if the gateway does
  not implement Max “1M context / extra usage” entitlements.
- Status bar should **not** say `Claude Max` once isolation is working.
- The “claude.ai connectors are disabled…” line is expected under gateway
  auth; it is not the extra-usage failure.
## Repo-Local Runtime Wrappers

- When your automation can already resolve the repository root, prefer repo-local wrappers under `scripts/runtime/` over rebuilding helper IPC or Windows bootstrap logic.
- `scripts/runtime/agent-clipboard.sh` is the current agent-facing clipboard wrapper. It stays in WSL, ensures the Windows helper is healthy, and then writes text or an image file to the Windows clipboard.
- If that wrapper reports that the helper bootstrap is missing, sync the runtime first, then rerun the command.
- `sync-runtime.sh` writes `$HOME/.wezterm-x/agent-tools.env` on the **WSL user home**, not on the Windows-side wezterm runtime target home. Windows-side processes do not consume this file — its only readers are WSL-resident agents (Claude Code, Codex CLI, etc.) that need to discover repo-local wrappers without inferring paths.
- Read `agent_clipboard` from `$HOME/.wezterm-x/agent-tools.env` instead of inferring wrapper paths from the current task repository or AGENTS symlinks. Schema and contract: [agent-tools.env schema](#agent-toolsenv-schema) below.

### `agent-tools.env` schema

- **Location**: `$HOME/.wezterm-x/agent-tools.env` on the WSL user home that ran `sync-runtime.sh`. In `posix-local` mode the WSL home and the wezterm-runtime target home coincide; in `hybrid-wsl` they diverge (the wezterm runtime lands at `%USERPROFILE%\.wezterm-x\` while the marker stays on `/home/<user>/.wezterm-x/`).
- **Format**: UTF-8 text, one `key=value` per line. Written via temp+rename by `sync-runtime.sh::write_agent_tools_file`, so consumers either see the previous full file or the new full file — never a partial read.
- **Keys**:
  - `version` — schema version, currently `1`. Bump on incompatible key changes; consumers should refuse unknown major versions.
  - `repo_root` — absolute path to the wezterm-config clone that produced this marker. Lets external agents resolve sibling resources in the same clone (e.g. other scripts under `scripts/runtime/`).
  - `agent_clipboard` — absolute path to `scripts/runtime/agent-clipboard.sh`. Bash script; callable only from WSL. Writes text or an image file to the Windows clipboard via host-helper named-pipe IPC.
  - `open_file_in_vscode` — absolute path to `scripts/runtime/open-file-in-vscode.sh`. Bash script; callable only from WSL. Takes one file path (relative to the caller's cwd or absolute) and reveals it in VS Code, focusing/opening the file's repo window via the same host-helper pipeline as `Alt+v`. Use it to auto-open a file you generated for the user to review.
- **Sample**:

  ```ini
  version=1
  repo_root=/home/yuns/github/wezterm-config
  agent_clipboard=/home/yuns/github/wezterm-config/scripts/runtime/agent-clipboard.sh
  open_file_in_vscode=/home/yuns/github/wezterm-config/scripts/runtime/open-file-in-vscode.sh
  ```

- **Discovery contract**:
  - Existence of the file means "wezterm-config host-effects shipped this WSL home". Absent file → consumer must treat host-side wrappers as unavailable, **not** fall back to raw `clip.exe` / `pbcopy` / `xclip` / `Set-Clipboard`. The naive WSL → `clip.exe` path produces CJK mojibake (stdin reinterpreted under the system ANSI codepage, e.g. CP936/GBK on Chinese Windows). Manual `iconv -f UTF-8 -t UTF-16LE` + BOM piping can technically fix the encoding, but the raw binaries still only handle text — no image DIB/PNG dual-write, no STA threading, no helper trace_id / format negotiation — so re-implementing per call site is strictly worse than treating the capability as unavailable.
  - Before invoking a wrapper, the consumer must verify the referenced path still exists and is executable. A stale marker pointing at a deleted clone is "capability unavailable", not a fatal error.
  - Do not infer wrapper paths from anywhere else — not the current task repository, AGENTS symlinks, `which`, or environment variables. The marker is the single discovery surface.

## Windows Launch Hotkey

For `hybrid-wsl` on Windows, pin WezTerm to the taskbar together with the two apps you reach most often so the built-in `Win+N` shortcut can launch or focus them without a background hotkey daemon. Recommended layout:

- `Win+1`: WezTerm
- `Win+2`: primary browser
- `Win+3`: primary IM client (Feishu, Slack, Teams, etc.)

Pin each app, then drag the icons so WezTerm sits in slot 1, the browser in slot 2, and the IM client in slot 3. The binding survives reboots, needs no extra tooling, and stays out of the in-WezTerm keymap documented in [`keybindings.md`](./keybindings.md).

## Agent Attention Hooks

Hook install / upgrade templates, "what each hook does", verification, and provider integration live in [`agent-attention.md#hook-installation`](./agent-attention.md#hook-installation). The shared emitter lives at `scripts/runtime/agent-attention/emit.sh`; `scripts/claude-hooks/emit-agent-status.sh` remains as the Claude compatibility wrapper.

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

The same gap exists for file edits driven by Claude Code (Edit / Write / Bash `git …`) — the shell prompt is not in the loop, so the prompt hook never fires. The agent-side counterpart lives in the Claude install template at [`agent-attention.md#install--update`](./agent-attention.md#install--update): a second hook entry under `PostToolUse` and `Stop` backgrounds the same `tmux-status-refresh.sh --force --refresh-client` after every tool call and at turn end, sharing the 2s `@tmux_status_force_debounce` window with this prompt hook.

## Vim 9.2 (optional)

Use this when terminal Vim scroll feels like tearing or page-skips inside tmux, or when `:set termsync?` reports `E518` / unknown option (9.1).

1. **Confirm apt cannot help** (Ubuntu 24.04 / noble): `apt-cache policy vim` — candidate stays 9.1.x.
2. **Build a user-prefix Vim 9.2+** (example tag; pick a current `v9.2.*`):

   ```sh
   PREFIX="$HOME/.local"
   SRC="$(mktemp -d /tmp/vim-build-XXXXXX)"
   git clone --depth 1 --branch v9.2.0976 https://github.com/vim/vim.git "$SRC/vim"
   cd "$SRC/vim"
   ./configure --prefix="$PREFIX" --with-features=huge --enable-multibyte \
     --disable-gui --without-x --enable-terminal
   make -j"$(nproc)" && make install
   hash -r
   command -v vim   # expect $HOME/.local/bin/vim
   vim --version | head -3
   ```

   Keep `~/.local/bin` ahead of `/usr/bin` on `PATH` (already typical on this machine). System `/usr/bin/vim` / `vi` → `vim.basic` remain 9.1 — tools that spawn `vi` without PATH preference still get 9.1; set `EDITOR=$HOME/.local/bin/vim` for SOPS / `x-env secrets edit` if needed.
3. **Merge** [`wezterm-x/local.example/vimrc.recommended`](../wezterm-x/local.example/vimrc.recommended) into `~/.vim/vimrc`.
4. **Verify** inside tmux Vim: `:set termsync?` → `termsync`; long-line files should not fill the window with `@` after `display+=lastline`. Interaction matrix: [`tmux-ui.md#vim-in-tmux`](./tmux-ui.md#vim-in-tmux).

This is **not** a hard repo prerequisite (many flows use VS Code via `EDITOR=code --wait`). It is the supported path when you want terminal Vim redraw/scroll to match this stack’s Sync-capable tmux.

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

## Maintainer Setup

This section applies **only to maintainers** who cut releases or develop the native components (Windows host-helper / Go popup picker). Regular contributors and end users can skip it — the prerequisites above are sufficient for daily use, since native components ship as prebuilt binaries via [`host-helper-release.md`](./host-helper-release.md) and [`picker-release.md`](./picker-release.md). End users without a Go or .NET toolchain still get the fast Go picker through the release-manifest fetcher in `native/picker/build.sh` (auto mode).

- `gh` (GitHub CLI) **required** for the release flow in [`host-helper-release.md`](./host-helper-release.md). It pushes tags, watches the release workflow, merges the auto-generated manifest-update PR, and toggles the repo Actions permission described below. Install with `sudo apt install gh` on Ubuntu/Debian, `brew install gh` on macOS, or follow <https://cli.github.com/>. After install, authenticate once with `gh auth login` and verify with `gh auth status`.
- Repo `Settings → Actions → General → Workflow permissions` must have **Allow GitHub Actions to create and approve pull requests** enabled, otherwise the release workflow's `update-manifest` job fails its final step with `GitHub Actions is not permitted to create or approve pull requests`. The release archive is still published, but the manifest-update PR has to be opened manually. Enable from the CLI (one-time per repo):

  ```bash
  gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \
    -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=true
  ```

  Verify with `gh api repos/<owner>/<repo>/actions/permissions/workflow` — the response should include `"can_approve_pull_request_reviews": true`. The `default_workflow_permissions` field is unrelated; the release workflow declares its own `permissions:` block, so leave whatever value is already set.
- `go 1.21+` in the WSL/Linux side. **Required** for maintainers iterating on `native/picker/` source — `native/picker/build.sh` builds the static `native/picker/bin/picker` ELF that powers the high-frequency tmux popups: `Alt+/` (attention), `Alt+g` (worktree), `Ctrl+Shift+P` (command palette), and `Alt+t` (overflow). `wezterm-runtime-sync`'s `build-picker` step (`native/picker/build.sh`) auto-discovers `go` in `PATH` → `~/.local/go/bin/go` → `/usr/local/go/bin/go`. End users without Go are covered by the release-fetcher in the same script: with the default `WEZTERM_PICKER_INSTALL_SOURCE=auto`, a missing Go toolchain falls through to the prebuilt tarball pinned in `native/picker/release-manifest.json`, sha256-verified and extracted into `native/picker/bin/picker`; cache lives at `${WEZDECK_PICKER_CACHE:-$XDG_CACHE_HOME/wezdeck/picker}/<version>`. Force a specific source with `WEZTERM_PICKER_INSTALL_SOURCE=local|release`. Only direct Go dep is `golang.org/x/term`. Install Go with `sudo apt install golang-go` on Ubuntu 24.04+ (ships ≥ 1.22), or download from <https://go.dev/dl/> into `~/.local/go`. After install, run `wezterm-runtime-sync` once and confirm `native/picker/bin/picker` exists and the sync trace logs `step=build-picker status=completed`. **Popups are Go-only** — a failed install aborts sync; menus toast and refuse to open when the binary is missing. Emergency only: `WEZTERM_ALLOW_BASH_PICKER=1` re-enables deprecated bash pickers. Full semantics: [`picker-release.md#install-path`](./picker-release.md#install-path).
- `dotnet 8.0+` SDK on Windows **required** to build `native/host-helper/windows/...` locally and to verify the local-build install path with `WEZTERM_WINDOWS_HELPER_INSTALL_SOURCE=local` ([`host-helper-release.md#forcing-the-release-path-locally`](./host-helper-release.md#forcing-the-release-path-locally)). Not required for cutting releases — the GitHub Actions runner installs its own SDK via `actions/setup-dotnet@v4`. Install from <https://dotnet.microsoft.com/download/dotnet/8.0>, or with `winget install Microsoft.DotNet.SDK.8`. Verify with `dotnet --list-sdks` from a PowerShell prompt.

## Read Next

- Workspace semantics and config shape:
  Read [`workspaces.md`](./workspaces.md).
- Sync, reload, and verification:
  Read [`daily-workflow.md`](./daily-workflow.md).
- Runtime ownership and entry points:
  Read [`architecture.md`](./architecture.md).
- Vim scroll / `@` lines / `Shift+drag` inside tmux:
  Read [`tmux-ui.md#vim-in-tmux`](./tmux-ui.md#vim-in-tmux).
