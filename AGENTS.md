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
- Agent-attention pipeline: Claude hook install / upgrade, attention.json
  schema and transitions, tab badges + right-status counters, focus-based
  auto-ack, the `Alt+,` / `Alt+.` / `Alt+/` keyboard entry points, or
  Codex integration:
  Read [`docs/agent-attention.md`](docs/agent-attention.md).
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
  file paths, troubleshooting):
  Read [`docs/diagnostics.md`](docs/diagnostics.md).
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
  why tmux 3.6+ is required, or agent-CLI render flicker investigation:
  Read [`docs/ime-flicker-and-sync-output.md`](docs/ime-flicker-and-sync-output.md).
- Sending a signal from a hook / picker / external helper into the
  WezTerm Lua process, picking between OSC and file transports, adding
  a new event, or migrating producers/consumers when upstream tmux or
  wezterm fix popup OSC pass-through:
  Read [`docs/event-bus.md`](docs/event-bus.md).
- Ownership boundaries, runtime architecture, or entry points:
  Read [`docs/architecture.md`](docs/architecture.md).
- Preparing a commit message or deciding commit split:
  Read [`docs/commit-guidelines.md`](docs/commit-guidelines.md).

## Hard Rules

- This repository is the source of truth.
- Treat `agent-profiles/` as hosted user-level profile source, not as the project-level instruction source for this repo.
- Windows runtime files are generated from this repo by `skills/wezterm-runtime-sync/scripts/sync-runtime.sh`. The `skills/wezterm-runtime-sync/` directory holds the workflow doc + scripts but is **not** a Claude Code Skill (it lives in the repo, not in `~/.claude/skills/`), so do not invoke it via the `Skill` tool — run the script directly with Bash.
- When agents run Windows-related scripts or smoke tests from WSL, prefer the repo-local wrappers and `scripts/dev/...` entrypoints in this repository over direct `cmd.exe` invocations or ad-hoc `powershell.exe -Command ...`.
- For Windows file inspection from agents, resolve runtime paths through `scripts/runtime/windows-runtime-paths-lib.sh` and then use WSL-native tools on the `*_WSL` paths instead of `cmd.exe /c dir`, `cmd.exe /c type`, or similar console commands.
- Keep workspace definitions in `wezterm-x/workspaces.lua`, not inline in `wezterm.lua`.
- Keep private machine and project overrides in `wezterm-x/local/` and keep tracked templates in `wezterm-x/local.example/`.
- Prefer updating an existing doc in `docs/` over adding a new sibling file; keep presentations under `docs/presentations/`.
- Design user-facing features keyboard-first: every new or changed interaction must have a keyboard path, and mouse bindings are only acceptable as fallbacks (for example cross-pane text selection or quick pane focus). Weigh key ergonomics when picking a binding — reachability, OS- / IME-level hotkey conflicts (Ctrl+Space, Alt+Shift, etc.), chord depth, and whether the action already has a keyboard home in `docs/keybindings.md`.
- `wezterm-x/commands/manifest.json` is the single source of truth for every shortcut. Adding or renaming a hotkey means: (1) add / update the manifest item with a `binding` field; (2) for wezterm-layer bindings, add the named handler to `wezterm-x/lua/ui/action_registry.lua`; (3) for tmux-chord leaves, the `binding.exec` tmux-action string is everything — no code changes elsewhere; `scripts/runtime/render-tmux-bindings.sh` regenerates `wezterm-x/tmux/chord-bindings.generated.conf` during `wezterm-runtime-sync` and `tmux.conf` loads it via `source-file -q`. Do not re-declare keys or actions in `keymaps.lua` or `tmux.conf` directly; both are driven by the manifest now. Missing or unregistered ids show up as `(unregistered)` in `scripts/dev/hotkey-usage-report.sh` — treat that report as the audit signal.
- Per-machine user overrides live in `wezterm-x/local/keybindings.lua` keyed by manifest id (string → new key, `false` → disable, list → per-variant). The WezTerm side applies them at reload; the tmux-chord side applies them when the renderer runs. Template: `wezterm-x/local.example/keybindings.lua`. Full rules in `docs/keybindings.md`.
- If behavior, keybindings, workspace semantics, tmux UI, or diagnostics change, update the matching docs in the same edit.
- After runtime config changes, run `skills/wezterm-runtime-sync/scripts/sync-runtime.sh` (Bash, not the `Skill` tool — see the note above).
- Do not run Git commands that can contend on the index lock in parallel.
- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
