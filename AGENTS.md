# AGENTS

This file is the project-level agent entry point.
User-level reusable agent profiles hosted under `agent-profiles/` are separate and do not override this file unless a user explicitly points an external tool at them.

## Loading Rule

Read `AGENTS.md` first, then open only the matching file under `docs/`. Read additional docs only when the current doc points to them or the task crosses that boundary.

## Task Routing

- Setup, local prerequisites, or machine-local config:
  Read [`docs/setup.md`](docs/setup.md).
- Sync, reload, verification, or day-to-day maintenance:
  Read [`docs/daily-workflow.md`](docs/daily-workflow.md).
- Workspace definitions or workspace behavior:
  Read [`docs/workspaces.md`](docs/workspaces.md).
- Keybindings:
  Read [`docs/keybindings.md`](docs/keybindings.md).
- tmux UI, tab titles, status rendering, copy-mode, or visible terminal behavior:
  Read [`docs/tmux-ui.md`](docs/tmux-ui.md).
- Terminal Vim inside tmux: scroll that feels like page-skips, windows full of
  `@` rows, `'termsync'` / DEC 2026 under tmux DA2, or `Shift+drag` jumping
  into copy-mode while editing:
  Read [`docs/tmux-ui.md#vim-in-tmux`](docs/tmux-ui.md#vim-in-tmux)
  (install / vimrc: [`docs/setup.md#vim-92-optional`](docs/setup.md#vim-92-optional)).
- Grok Build fullscreen TUI: whole-transcript flash on `Alt+o` / pane focus,
  FocusGained `terminal.clear()`, cream `#eeeeee` vs pane `bg_base`, the
  PATH focus-filter (`grok-with-focus-filter.sh --install`: `~/.grok/bin/grok`
  → wrapper, `grok.real` = ELF; required because zshrc prepends `~/.grok/bin`),
  why macOS WezTerm+tmux can look fine with the same heal (sub-frame client
  burst, not OS-exempt), why WSL→Windows still flashes even on a tiny pane,
  `scripts/dev/repro-grok-focus-flash.sh`, mouse-wheel feel under tmux
  (`scroll_lines` / `scroll_mode=wheel` / `scroll_speed` in `~/.grok/config.toml`),
  or Grok follow ▼ click dead while a stock-tmux macOS box works
  (`MouseDown1Pane` must `send-keys -M` when `alternate_on` / `mouse_any_flag`):
  Read [`docs/tmux-ui.md#grok-build-in-tmux`](docs/tmux-ui.md#grok-build-in-tmux).
- Window appearance presets (`opaque` / `frosted`), transparency /
  frosted-glass, `win32_system_backdrop`, `window_background_opacity`, the
  `WEZTERM_APPEARANCE_PRESET` selector, `render-tmux-appearance.sh`, or the
  tab-bar / pane / status background colors that make the frosted look cohere:
  Read [`docs/appearance-presets.md`](docs/appearance-presets.md).
- Choosing or revisiting the inner multiplexer (tmux vs herdr), or planning
  feature work that a tmux upgrade could absorb — the tmux 3.8 borrow list
  (OSC 133 pane events, floating / modal panes, `set-hook -B` monitors, theme
  reporting, `#{A/count:frames}`), the measured herdr 0.8.0 numbers
  (per-session server memory, session-level focus, sidebar limits, no
  `#(shell)` equivalent, no ad-hoc popup CLI), and why the 2026-08-18
  evaluation ended with tmux staying:
  Read [`docs/multiplexer-comparison.md`](docs/multiplexer-comparison.md).
- Agent-attention pipeline: Claude hook install / upgrade, attention.json
  schema and transitions, tab badges + right-status counters, focus-based
  auto-ack, the `Alt+j` / `Alt+k` / `Alt+l` / `Alt+/` keyboard entry points, or
  Codex integration:
  Read [`docs/agent-attention.md`](docs/agent-attention.md).
- Timed reminders (cron-driven tmux popups), the `reminder.sh` /
  `tmux-popup-active.sh` wrappers, or the
  `wezterm-x/local/crontab` install workflow:
  Read [`docs/reminders.md`](docs/reminders.md).
- Phone / Android remote work (OpenClaw only; Happy + Tailscale phone
  shell retired 2026-07), tmux window-size limits, Termux IME notes:
  Read [`docs/mobile-access.md`](docs/mobile-access.md).
- Headless Chrome debug instance, auto-start behavior, `Alt+b` /
  `Alt+Shift+b`, `chrome://inspect` workflow, or the right-status `CDP·…`
  badge:
  Read [`docs/browser-debug.md`](docs/browser-debug.md).
- Cutting a Windows host-helper release, updating
  `release-manifest.json`, forcing the release-install branch, or
  side-loading the release zip:
  Read [`docs/host-helper-release.md`](docs/host-helper-release.md).
- Cutting a Go picker (`native/picker/`) release, updating its
  multi-asset `release-manifest.json`, or the install-side fetcher
  (`WEZTERM_PICKER_INSTALL_SOURCE=auto|local|release`) that lets end
  users without Go consume the prebuilt tarball:
  Read [`docs/picker-release.md`](docs/picker-release.md).
- Diagnostics, logs, or smoke tests (operator surface — env knobs,
  file paths, troubleshooting); also guest-OOM hardening in all three of its
  shapes — the whole distro vanishing / restarting on a fixed interval, the
  reclaim livelock that pins every core, kills nothing, and leaves no OOM
  record, and the high-order (`order:7` / `vmbus_alloc_ring`) allocation
  failure that kills the vsock channel and makes Windows reboot the whole VM
  while swap still looks healthy (`wsl-oom-guard.sh`, the
  `wezterm-oom-protect` / `wezterm-oom-record` units, the `M·…` / `S·…`
  memory badge, the fragmentation axis with its compact-then-SIGTERM relief,
  and `install-earlyoom.sh`); also host disk space
  (host volume full, `ext4.vhdx` growing but never shrinking, why
  `--set-sparse` is a trap, `fstrim` → `wsl --shutdown` → `Optimize-VHD` /
  `compact vdisk`, build-artifact inventory, OEM preinstalls, and the
  `wsl-disk-guard.sh` sampler + `D·…` headroom badge); also the standing-memory
  baseline for agent-side processes (per-session MCP cost, the
  `chrome-devtools-mcp` unbounded-heap leak and its `uxc` containment,
  `uxc-session-reaper.sh`, and why the Claude Code and OpenClaw sides are
  deliberately asymmetric); also the IDE-side TypeScript language server
  (`tsgo` / `typescript.experimental.useTsgo`) — why `maxTsServerMemory` does
  nothing to it, how `js/ts.server.goMemLimit` set *below* the live heap trades
  ~4 Gi of memory for a permanent ~1.5-core GC burn, the RSS-flat /
  faults-near-zero signature that identifies it, why only
  `Developer: Reload Window` applies a change to that key, and why the
  uncapped `tsgo` that Claude Code spawns on its own must be left uncapped:
  Read [`docs/diagnostics.md`](docs/diagnostics.md).
- Unverified claims, deferred decisions, or "what still needs following up" on
  any of the above — dated, each with how to close it:
  Read [`docs/diagnostics.md#open-questions`](docs/diagnostics.md#open-questions).
  Record new ones there rather than only in a commit body, which is not
  reviewable day to day.
- Cross-host development environment failures involving Windows, WSL, DNS,
  VPN/proxy software, shells, or agent CLIs; also the first-triage path when
  the whole WSL distro disappears at once (distro restart vs VM reboot):
  Read [`docs/development-environment-troubleshooting.md`](docs/development-environment-troubleshooting.md).
- Adding or modifying a logger callsite, choosing a category, deciding
  log level / required fields, or moving a log file across the WSL
  boundary (author surface):
  Read [`docs/logging-conventions.md`](docs/logging-conventions.md).
- Performance work on the Alt+/ popup, the cross-FS routing rule for
  state files, the bench harnesses, or the sync-runtime hot path
  (skip-if-current gates, rsync-vs-cp tradeoff, mtime-based change
  detection):
  Read [`docs/performance.md`](docs/performance.md).
- IME candidate-window stability, DEC mode 2026 (synchronized output),
  why tmux 3.7+ is required, or agent-CLI render flicker investigation:
  Read [`docs/ime-flicker-and-sync-output.md`](docs/ime-flicker-and-sync-output.md).
- Sending a signal from a hook / picker / external helper into the
  WezTerm Lua process, picking between OSC and file transports, adding
  a new event, or migrating producers/consumers when upstream tmux or
  wezterm fix popup OSC pass-through:
  Read [`docs/event-bus.md`](docs/event-bus.md).
- Per-workspace tmux-session focus statistics, the `tab-stats-bump.sh`
  hook chain, the on-disk `<workspace>.json` schema, weight decay /
  normalization formula, or planning the top-N tab bar slots / overflow
  tab / warm preheat layer:
  Read [`docs/tab-visibility.md`](docs/tab-visibility.md).
- Ownership boundaries, runtime architecture, or entry points:
  Read [`docs/architecture.md`](docs/architecture.md).
- Env loading, secret placement, the `~/.config/shell-env.d/`
  convention, `runtime-env-lib.sh::runtime_env_load_managed`, or
  deciding whether a value belongs in `wezterm-x/local/shared.env`
  vs `~/.config/shell-env.d/`:
  Read [`docs/setup.md#env-loading-model`](docs/setup.md#env-loading-model).
- Agent-CLI launch chain, `agent-launcher.sh`, the `${WEZTERM_REPO}`
  placeholder used in `config/worktree-task.env`, or any path that
  spawns `claude` / `codex`:
  Read [`docs/architecture.md#startup-invariants`](docs/architecture.md#startup-invariants).
- Adversarial code review skill (find→refute→repro), cross-agent backend
  selection, the shared `lib/provider.sh` layer, per-stage reasoning effort,
  the no-session-resume rationale, or offline mock testing:
  Read [`docs/adversarial-review.md`](docs/adversarial-review.md).
- Multi-persona brainstorm skill (diverge→challenge→converge), persona/provider
  selection, per-stage effort, the no-resume design, or the offline mock harness:
  Read [`docs/brainstorm.md`](docs/brainstorm.md).
- Host-CLI invoke layers (one-way dependency):
  - **Single-shot:** `adversarial-review/lib/provider.sh` → `run_agent` /
    `agent_text` → plugin `__invoke` (no temp dir).
  - **Multi-shot / parallel:** `agent-fanout/lib/fanout-lib.sh`
    (`fanout_call` / `fanout_run` / `fanout_run_jobs`) + CLI `run.sh`.
  Fanout sources provider; provider never loads fanout. Do **not** hand-roll
  `claude & wait` or call `__invoke` from feature code. Offline smoke:
  `scripts/dev/agent-fanout/test.sh`. Notes:
  [`docs/adversarial-review.md`](docs/adversarial-review.md) /
  [`docs/brainstorm.md`](docs/brainstorm.md).
- Design proposal / RFC / ADR / 方案评审 (no runtime diff — **not** a dedicated
  skill): structured 设计评审 checklist and intent routing live in the
  user-level profile
  [`agent-profiles/v1/en/validation.md`](agent-profiles/v1/en/validation.md)
  (`Design proposal review`); also summarized under
  [`docs/adversarial-review.md`](docs/adversarial-review.md) (out of scope) and
  [`docs/brainstorm.md`](docs/brainstorm.md) (when alternatives are still needed).
- Host↔Claw session interop (Session Adapter Kit / `session-bridge`: list/read
  host tmux + claw sessions, gated `poke` / `host-send-keys` under lease, panic
  freeze, `bot-send` / `say-as-me` identities, attention merge, tmux side-load
  safety):
  Read [`openclaw/docs/session-bridge.md`](openclaw/docs/session-bridge.md).
- Personal OpenClaw control plane (Feishu gateway templates, main-agent
  protocol, link/smoke scripts — **not** the WezTerm/tmux execution hot path):
  Read [`openclaw/README.md`](openclaw/README.md) and
  [`openclaw/workspace/AGENTS.md`](openclaw/workspace/AGENTS.md).

## Hard Rules

- This repository is the source of truth.
- Treat `agent-profiles/` as hosted user-level profile source, not as the project-level instruction source for this repo.
- Windows runtime files are generated from this repo by `skills/wezterm-runtime-sync/scripts/sync-runtime.sh`. The `skills/wezterm-runtime-sync/` directory holds the workflow doc + scripts but is **not** a Claude Code Skill (it lives in the repo, not in `~/.claude/skills/`), so do not invoke it via the `Skill` tool — run the script directly with Bash.
- When agents run Windows-related scripts or smoke tests from WSL, prefer the repo-local wrappers and `scripts/dev/...` entrypoints in this repository over direct `cmd.exe` invocations or ad-hoc `powershell.exe -Command ...`.
- For Windows file inspection from agents, resolve runtime paths through `scripts/runtime/windows-runtime-paths-lib.sh` and then use WSL-native tools on the `*_WSL` paths instead of `cmd.exe /c dir`, `cmd.exe /c type`, or similar console commands.
- Keep workspace definitions in `wezterm-x/workspaces.lua`, not inline in `wezterm.lua`.
- Keep private machine and project overrides in `wezterm-x/local/` and keep tracked templates in `wezterm-x/local.example/`.
- User-level secrets (CNB tokens, third-party API keys, etc.) live under `~/.config/shell-env.d/<name>.env` — the canonical convention auto-discovered by both `~/.zshrc` and `scripts/runtime/runtime-env-lib.sh::runtime_env_load_managed`. Do not introduce new ad-hoc dotfile loaders that hardcode specific filenames; drop a file in `shell-env.d/` instead. Repo-machine config consumed by both Lua and shell stays in `wezterm-x/local/shared.env` (synced to Windows runtime). Full rules: [`docs/setup.md#env-loading-model`](docs/setup.md#env-loading-model).
- Every agent-CLI launch path must terminate at `scripts/runtime/agent-launcher.sh <profile>` — workspace first-open, `Alt+g` on-demand window, `refresh-current-window`, and tab-overflow cold-spawn all share this single env-loading site. Do not invoke `claude` / `codex` directly from a `tmux new-window` / `respawn-pane` call site or from a new `*_RESUME_COMMAND` in `config/worktree-task.env`. Shell paths that resolve the resume argv share `scripts/runtime/worktree/lib/resume-command.sh::resolve_managed_primary_command` (cold-spawn included — do not reimplement key lookup). The `${WEZTERM_REPO}` placeholder used in `worktree-task.env` is expanded in lockstep by `resume-command.sh` and `wezterm-x/lua/config/managed_cli.lua::parse_managed_cli_env`.
- Prefer updating an existing doc in `docs/` over adding a new sibling file; keep presentations under `docs/presentations/`.
- Design user-facing features keyboard-first: every new or changed interaction must have a keyboard path, and mouse bindings are only acceptable as fallbacks (for example cross-pane text selection or quick pane focus). Weigh key ergonomics when picking a binding — reachability, OS- / IME-level hotkey conflicts (Ctrl+Space, Alt+Shift, etc.), chord depth, and whether the action already has a keyboard home in `docs/keybindings.md`.
- `wezterm-x/commands/manifest.json` is the single source of truth for every shortcut. Adding or renaming a hotkey means: (1) add / update the manifest item with a `binding` field; (2) for wezterm-layer bindings, add the named handler to `wezterm-x/lua/ui/action_registry.lua`; (3) for tmux-chord leaves, the `binding.exec` tmux-action string is everything — no code changes elsewhere; `scripts/runtime/render-tmux-bindings.sh` regenerates `wezterm-x/tmux/chord-bindings.generated.conf` during `wezterm-runtime-sync` and `tmux.conf` loads it via `source-file -Fq`. Do not re-declare keys or actions in `keymaps.lua` or `tmux.conf` directly; both are driven by the manifest now. Missing or unregistered ids show up as `(unregistered)` in `scripts/dev/hotkey-usage-report.sh` — treat that report as the audit signal.
- Per-machine user overrides live in `wezterm-x/local/keybindings.lua` keyed by manifest id (string → new key, `false` → disable, list → per-variant). The WezTerm side applies them at reload; the tmux-chord side applies them when the renderer runs. Template: `wezterm-x/local.example/keybindings.lua`. Full rules in `docs/keybindings.md`.
- If behavior, keybindings, workspace semantics, tmux UI, or diagnostics change, update the matching docs in the same edit.
- Markdown with mermaid diagrams: after editing a mermaid code block, run `scripts/dev/check-mermaid.sh` (validates every block via `mermaid.parse` under jsdom — real grammar check, no chromium; deps cached outside the repo). Do not hand-eyeball mermaid syntax.
- After runtime config changes, run `skills/wezterm-runtime-sync/scripts/sync-runtime.sh` (Bash, not the `Skill` tool — see the note above). **Default sync stages a canary tree, auto-launches an isolated WezTerm probe, and promotes to live only if `healthy.stamp` appears** (otherwise live is left untouched). Use `--live` to skip the gate; `WEZTERM_SYNC_SKIP_CANARY_AUTO=1` to stage without probing. Full flow: [`docs/daily-workflow.md`](docs/daily-workflow.md).
- Do not run Git commands that can contend on the index lock in parallel.
- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
