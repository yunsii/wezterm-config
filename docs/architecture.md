# Architecture

Use this doc when you need ownership boundaries, entry points, or runtime design constraints.

## Source Of Truth

- This repository is the source of truth.
- Windows runtime files are generated from this repo by the `wezterm-runtime-sync` skill in `skills/wezterm-runtime-sync/`.
- Live targets include `%USERPROFILE%\.wezterm.lua`, `%USERPROFILE%\.wezterm-x\...`, and `%USERPROFILE%\.wezterm-native\...`.

## Interaction Layers

This config nests two terminal multiplexers — WezTerm outside, tmux inside a single pane of each managed project tab — and several concept names collide between the two layers. Keep the ownership split below in mind when routing a new binding, script, or diagnostic.

### Nested structure

```
WezTerm process
  └─ OS window
     └─ Workspace  (default / work / config / ...)
        └─ Tab
           └─ WezTerm pane
              └─ tmux  (inside a managed project tab)
                 └─ tmux session  (one per repo family)
                    └─ tmux window  (one per linked git worktree)
                       └─ tmux pane  (left agent / right shell layout)
```

### Semantic mapping in this repo

- **WezTerm tab** = one project / repo family. A managed project tab typically runs exactly one tmux session.
- **tmux window** = one git worktree inside that repo family. `Alt+g` / `Alt+Shift+g` create or select tmux windows; see [`workspaces.md`](./workspaces.md).
- **tmux pane** = the intra-worktree split (usually left agent / right shell).
- **WezTerm pane** outside tmux only appears in the `default` workspace or while a managed tab is still bootstrapping.

### Ownership rule

- Cross-tab and cross-workspace navigation lives on the WezTerm layer (`Alt+n` / `Alt+Shift+n` / `Alt+1..9` for tabs; `Alt+d` / `Alt+w` / `Alt+c` / `Alt+p` for workspaces). The key → action wiring is driven by `wezterm-x/commands/manifest.json` + `wezterm-x/lua/ui/action_registry.lua` (handler closures) + `wezterm-x/lua/ui/keymaps.lua` (builds `config.keys` by iterating the manifest and dispatching through the registry).
- `tmux.conf` owns pane splits, copy-mode, mouse handling, worktree-window switching, and status-line rendering. Its chord key tables (`command-chord`, `worktree-chord`) are **generated** from the same `manifest.json` by `scripts/runtime/render-tmux-bindings.sh` into `wezterm-x/tmux/chord-bindings.generated.conf` (gitignored), which `tmux.conf` loads via `source-file -q`. The renderer runs during `wezterm-runtime-sync`.
- WezTerm keys that mutate tmux state (`Alt+v` / `Alt+g` / `Alt+Shift+g` / `Alt+/` / `Alt+o` / `Ctrl+k` / `Ctrl+Shift+P`) resolve through the registry on the WezTerm side; they forward into the active tmux-backed pane via short escape sequences (`\x1bv`, `\x1b/`, `\x0b`, etc.) so tmux owns the execution. The tmux `bind-key -n M-v / M-g / M-/ / User0-2` lines that receive those bytes are transport infrastructure and stay inline in `tmux.conf`, not user-customizable.
- Per-machine keybinding overrides live in `wezterm-x/local/keybindings.lua`, addressed by manifest `id`. The WezTerm path consumes them directly at reload (`wezterm-x/lua/ui/keybinding_overrides.lua`); the tmux-chord path consumes the same file at sync time via the bash renderer. Both sides share one source of truth and one override file.
- Agent attention is layered: hooks (`scripts/claude-hooks/emit-agent-status.sh`) write a shared JSON file via `scripts/runtime/attention-state-lib.sh` and nudge WezTerm with an OSC 1337 `attention_tick`; `wezterm-x/lua/attention.lua` reads it on every tick and renders tab badges + right-status counter (render-only; no pane walking, no user_var state). Jump path splits by entry point: `Alt+,` / `Alt+.` are Lua-driven `--direct` calls; `Alt+/` is forwarded into tmux and runs the popup picker. Full pipeline (state schema, transitions, rendering, focus-based auto-ack, keyboard, hooks): [`agent-attention.md`](./agent-attention.md).

### Naming guidance for code and docs

- "Window" is ambiguous. Use **WezTerm OS window**, **tmux window**, or **workspace** — never bare "window" in a sentence that crosses layers.
- "Pane" is also overloaded. Use **WezTerm pane** vs **tmux pane** when the layer matters.
- "Tab" is unambiguous — it only exists in WezTerm.
- In `wezterm-x/commands/manifest.json`, `context: tmux-backed` implies the command only makes sense when the focused WezTerm pane is running tmux; `layer: wezterm | tmux | tmux-chord` identifies which keymap owns the binding.

## Command Manifest

`wezterm-x/commands/manifest.json` is the single source of truth for invocable commands across the WezTerm keymap, the tmux chord tables, the tmux-owned command palette, and the `docs/keybindings.md` reference. Consumers (WezTerm keymap builder, tmux chord renderer, palette reader, hotkey usage report) resolve commands by `id` and must not re-declare keys, actions, or palette entries outside the manifest.

Entry schema:

- `id` string. Stable dotted identifier used as the cross-reference handler registries and codegen keys resolve to.
- `label` string. Short human-facing title shown in palette and docs.
- `description` string. One-line explainer reused by the palette popup and docs.
- `scope` string. Docs/UI grouping. One of: `workspaces`, `project-navigation`, `commands-and-splits`, `window-and-pane-navigation`, `clipboard`, `session-maintenance`.
- `context` string. Where the command is usable. One of: `any`, `tmux-backed`, `hybrid-wsl`.
- `binding` object, optional. Declares how the command executes. Two shapes:
  - WezTerm layer: `{ "handler": "<name>", "args": <optional static args> }`. `handler` is the key into `wezterm-x/lua/ui/action_registry.lua`; the handler function receives optional static `args` (from manifest) and per-hotkey `args` (e.g. `Alt+N` passes `N`) and returns a wezterm action.
  - tmux-chord layer: `{ "kind": "tmux-chord-leaf", "table": "command-chord" | "worktree-chord", "exec": "<tmux action chain>", "switch_first": <optional bool> }`. `exec` is a raw tmux action string (may embed `#{...}` interpolations); the renderer wraps it with chord-hint clear + usage-bump + a `switch-client -T root` that defaults to running after `exec` (`switch_first: true` moves it before `exec` for modal actions like `command-prompt`).
- `args_schema` object, optional. For parametrized ids (`tab.select-by-index`): `{ "kind": "integer" | "string" | "object", "range"?, "enum"?, "shape"? }`. Consumed by the override loader to validate user-supplied args.
- `hotkeys` array. Zero or more bindings; each item has `keys` (e.g. `Alt+v`, `Ctrl+k v`), `layer` (`wezterm` or `tmux-chord`), and optional `args` (for parametrized ids).
- `hotkey_display` string, optional. Render-only override for the palette hotkey column; when present, replaces the comma-joined `hotkeys[].keys` text (e.g. `Alt+1..9` instead of `Alt+1,Alt+2,...,Alt+9`). Does not affect codegen — the real bindings still come from `hotkeys[]`.
- `palette` object, optional. Present only when the command should appear in the tmux command palette. Either `display_only: true` (the entry is rendered for search/discovery and running it prints a toast asking the user to use the hotkey), or a real entry with `accelerator` (single-char hint), `command` (argv array executed by `tmux-command-run.sh`; elements may contain the `{repo_root}` placeholder which is replaced with the current repository root at register time), and optional `confirm_message`, `success_message`, `failure_message`.

Invariants:

- `id` is unique across the manifest.
- `hotkeys[].keys` is unique across the manifest (for the default key; user overrides may introduce temporary shadows until resolved).
- Every wezterm-layer `binding.handler` must be registered in `action_registry.lua`, and every tmux-chord `binding` must carry `table` + `exec`.
- `palette.accelerator` is unique within a given runtime-mode visibility set.
- `context = hybrid-wsl` entries only run when the active runtime mode matches.

Adding a new shortcut means: (1) new item in `manifest.json` with `binding`; (2) for wezterm-layer, new handler function in `action_registry.lua`; (3) for tmux-chord leaves, the `exec` string covers everything — no code changes elsewhere. Rerun `wezterm-runtime-sync` after edits so the tmux chord table regenerates.

## Entry Points

- `wezterm.lua`: top-level WezTerm config and keybindings
- `wezterm-x/workspaces.lua`: managed workspace definitions
- `wezterm-x/commands/manifest.json`: single source of truth for invocable commands (see `Command Manifest`)
- `wezterm-x/lua/logger.lua`: WezTerm-side structured diagnostics helper
- Agent-attention pipeline (`wezterm-x/lua/attention.lua`, `scripts/runtime/attention-{state-lib,jump}.sh`, `scripts/claude-hooks/emit-agent-status.sh`, `scripts/runtime/tmux-{attention,focus}-*.sh`, `scripts/runtime/tmux-attention-{menu,picker}.sh`): see [`agent-attention.md`](./agent-attention.md) for the per-file ownership.
- `scripts/runtime/tmux-worktree-menu.sh` + `tmux-worktree-picker.sh`: tmux-popup picker for `Alt+g`. The menu wrapper prefetches the worktree list into a TSV file before opening `tmux display-popup -E` so the popup paints content on the first frame; the picker dispatches via `tmux run-shell -b tmux-worktree-open.sh` and exits immediately so the popup closes before window creation finishes. Performance contract: [`performance.md`](./performance.md).
- `wezterm-x/local/`: gitignored machine-local overrides copied by the sync skill when present
- `config/worktree-task.env`: tracked repo profile for the `worktree-task` runtime; sync-time mirrored to `<runtime_dir>/repo-worktree-task.env` so Windows-side wezterm.exe Lua can read it (the WSL path in `repo-root.txt` is unreachable from Win32 file APIs). `wezterm-x/lua/constants.lua` reads the local copy first; the env file is the single source of truth for `<base>` / `<base>_resume` profile commands.
- `skills/wezterm-runtime-sync/`: runtime sync workflow, prompt rendering, and prompt regression scripts
- `scripts/runtime/worktree/`: linked worktree task runtime — `worktree-task` CLI, `open-task-window` (Ctrl+k g d/t/h create entry), `reclaim-current-window` (Ctrl+k g r reclaim entry), core libraries under `lib/`, built-in providers under `providers/`
- `scripts/runtime/open-project-session.sh`: tmux bootstrap for managed project tabs
- `scripts/runtime/primary-pane-wrapper.sh`: traps INT/HUP/TERM around the managed agent and execs the login shell on exit so the primary pane survives agent death
- `scripts/runtime/run-managed-command.sh`: managed startup command launcher
- `scripts/runtime/agent-clipboard.sh`: repo-local WSL wrapper that writes text or image files to the Windows clipboard through the host helper
- `scripts/runtime/runtime-log-lib.sh`: shared runtime logging helper
- `wezterm-x/scripts/`: thin runtime bootstrap and install scripts plus remaining cross-platform shell helpers copied by the sync skill
- `native/host-helper/windows/src/HelperManager/`: Windows `helper-manager.exe` server project
- `native/host-helper/windows/src/HelperCtl/`: Windows `helperctl.exe` console client project
- `native/host-helper/windows/src/Shared/`: shared Windows host-helper protocol, transport, and support models
- `native/host-helper/windows/scripts/`: Windows host-helper release packaging scripts used by GitHub Actions
- `tmux.conf`: tmux layout and status rendering
- `agent-profiles/`: hosted source for versioned user-level agent profiles; not the project-level instruction source for this repo

## Startup Invariants

- Managed project tabs bootstrap through `scripts/runtime/open-project-session.sh`.
- Linked task worktree windows bootstrap through the built-in tmux provider under `scripts/runtime/worktree/providers/tmux-agent.sh`.
- The built-in task-worktree tmux provider derives repo-family session reuse and task-window ownership from live git context, not from stored tmux metadata.
- `open-project-session.sh` launches managed commands inside an interactive login shell so the environment matches the right-side shell pane.
- The managed command runs under `primary-pane-wrapper.sh`, which traps INT/HUP/TERM and execs the user's login shell after the agent returns. Logs each transition under `category=primary_pane` so pane deaths can be diagnosed post-mortem.
- `run-managed-command.sh` is a thin wrapper that logs and execs the command.
- Managed launcher profiles live in `wezterm-x/lua/constants.lua` and resolve to concrete startup commands before tmux session creation.
- The tmux layout is the stable execution layer: left pane runs the configured primary command and right pane remains a shell in the same directory.
- One-shot task prompts belong only to the newly created task worktree window; they must not overwrite the repo-family session's stored default startup command.

## Windows Host

- In `hybrid-wsl`, WezTerm Lua is only responsible for request generation, helper bootstrap, and request-side diagnostics.
- `%LOCALAPPDATA%\wezterm-runtime\` is the Windows runtime state root. It keeps `logs/`, `state/`, `cache/`, and `bin/` in one place.
- `%LOCALAPPDATA%\wezterm-runtime\bin\helper-manager.exe` is the active Windows host control plane.
- `%LOCALAPPDATA%\wezterm-runtime\bin\helperctl.exe` is the thin console IPC client that WezTerm Lua, tmux-side scripts, and smoke tests invoke when they need a request or response.
- Repo-local high-level wrappers (`scripts/runtime/agent-clipboard.sh` and friends) and the `~/.wezterm-x/agent-tools.env` discovery marker are documented in [`setup.md#repo-local-runtime-wrappers`](./setup.md#repo-local-runtime-wrappers); agent-facing automation should prefer those wrappers over raw `helperctl.exe` IPC.
- `%USERPROFILE%\.wezterm-native\host-helper\windows\` is the published source tree that sync installs from; `%LOCALAPPDATA%\wezterm-runtime\bin\` is the stable installed binary location that the runtime actually launches.
- `native/host-helper/windows/release-manifest.json` is the version-pinned release fallback declaration. When Windows `dotnet` is available, the installer publishes from the synced native source tree; otherwise it downloads and verifies the manifest-selected GitHub release asset before replacing `%LOCALAPPDATA%\wezterm-runtime\bin\`. Cutting a release / updating the manifest / side-loading: [`host-helper-release.md`](./host-helper-release.md).
- `wezterm-x/scripts/` is intentionally thin on Windows. It keeps the helper installer, launcher, and bootstrap pieces, but the old Windows request handlers and worker-plugin chain are no longer part of the active design.

### Communication Overview

Three independent channels cross the WSL ⇄ Windows boundary; everything else in the codebase is a layer on top of these three:

1. **Named-pipe IPC** for synchronous requests (`Alt+v` / `Alt+b` / `Ctrl+v` etc.). WSL bash spawns `helperctl.exe`, which talks to `helper-manager.exe` over `\\.\pipe\wezterm-host-helper-v1` and gets a typed response back. Latency budget: ~50-150 ms.
2. **OSC 1337 escape codes** for async nudges (attention ticks, IME-state pushes). The agent CLI or hook script writes the OSC byte sequence to its tty; tmux DCS-wraps it; `wezterm.exe` consumes it and re-renders within one frame. Latency: under one paint frame (~16 ms).
3. **Shared NTFS state files under `/mnt/c`** for poll-style reads where both sides need the data at their own cadence. WSL processes write (hooks, jump scripts), Windows processes read on every tick (Lua status update, helper liveness watcher). Cross-FS routing rule lives in [`performance.md`](./performance.md).

```mermaid
flowchart LR
  subgraph WSL["WSL · Linux processes"]
    direction TB
    W_LUA["WezTerm Lua handlers<br/>(spawned via wsl.exe)"]
    W_HOOK["Claude hook<br/>emit-agent-status.sh"]
    W_AGENT["agent CLI<br/>claude / codex"]
    W_BASH["picker / menu / jump<br/>(bash + Go)"]
  end

  subgraph FS["/mnt/c · shared NTFS state"]
    direction TB
    F_ATT[("attention.json")]
    F_LIVE[("live-panes.json")]
    F_FOCUS[("tmux-focus/*.txt")]
    F_CHROME[("chrome-debug/state.json")]
    F_HELPER[("helper-install-state.json")]
  end

  subgraph WIN["Windows · host processes"]
    direction TB
    H_WEZ["wezterm.exe<br/>(GUI + Lua tick)"]
    H_CTL["helperctl.exe<br/>(IPC client)"]
    H_MGR["helper-manager.exe<br/>(control plane)"]
    H_CHR["Chrome<br/>(headless / visible)"]
    H_VSC["VS Code"]
  end

  W_BASH ==>|"cmd.exe shim"| H_CTL
  H_CTL ==>|"named pipe"| H_MGR
  H_MGR --> H_CHR
  H_MGR --> H_VSC

  W_AGENT -.->|"OSC 1337<br/>via tmux DCS"| H_WEZ
  W_HOOK  -.->|"OSC tick"| H_WEZ
  W_LUA   -.->|"wsl.exe args"| H_WEZ

  W_HOOK -- write --> F_ATT
  W_BASH -- read --> F_ATT
  W_LUA  -- "write on Alt+/" --> F_LIVE
  W_BASH -- read --> F_LIVE
  W_BASH -- write --> F_FOCUS
  H_WEZ  -- "tick read" --> F_ATT
  H_WEZ  -- "tick read" --> F_LIVE
  H_WEZ  -- "tick read" --> F_FOCUS
  H_MGR  -- write --> F_CHROME
  H_MGR  -- write --> F_HELPER
  H_WEZ  -- "tick read" --> F_CHROME

  classDef pipe stroke:#1f6feb,stroke-width:2px
  classDef osc  stroke:#9a6700,stroke-width:2px,stroke-dasharray:5 3
```

Edge legend: bold solid arrows = synchronous named-pipe IPC; dashed arrows = OSC 1337 nudges; thin solid arrows = file reads/writes against `/mnt/c` (the routing rule and per-file rationale live in [`performance.md`](./performance.md)).

### Request Flow

The named-pipe channel above, zoomed in to one Alt+v / Alt+b / Ctrl+v press:

```mermaid
flowchart LR
  A["WezTerm Lua<br/>Alt+v / Alt+b / Ctrl+v"] --> B["runtime.lua<br/>build request + trace_id"]
  B --> C["helperctl.exe<br/>request client"]
  C --> D["Named Pipe<br/>\\\\.\\pipe\\wezterm-host-helper-v1"]
  D --> E["helper-manager.exe<br/>single native control plane"]
  E --> F["Reuse policy<br/>window-cache.json + process/window scan"]
  E --> G["Clipboard service<br/>single STA thread + live read/write"]
  F --> H["Activate existing window<br/>or launch target app"]
  G --> I["return text<br/>or exported image path"]
  H --> J["typed response envelope<br/>domain / action / result_type / result"]
  I --> J
  J --> B
  B --> K["WezTerm action<br/>focus app or paste result"]
```

### Constraints

- The hot path should stay on one chain: `Lua -> helperctl.exe -> named pipe -> helper-manager.exe -> response`.
- `helper-manager.exe` is the single decision point for VS Code directory normalization, Chrome debug instance reuse, clipboard text or image decisions, and foreground-window IME state queries.
- Response types stay explicit: current-window reuse returns `result_type=window_ref`, clipboard reads return `clipboard_text` or `clipboard_image`, IME queries return `ime_state` with flat `mode` / `lang` / `reason` fields.
- Reuse logic depends on persisted cache, process command-line matching, visible window scanning, and foreground binding compensation.
- Clipboard reads and writes must stay in an STA-aware path so Windows data formats remain stable.

## Posix Host

- `posix-local` does not have a native host helper yet.
- When `posix-local` gets a host helper, it should follow the same split as Windows: WezTerm Lua remains a request producer, while a stable per-user native agent owns focus or open logic, clipboard monitoring, reuse policy evaluation, and structured decision logging.
- The preferred install shape is a stable per-user binary outside the synced runtime tree, with platform-specific source under `native/host-helper/<platform>/` and a thin bootstrap or installer layer under `wezterm-x/scripts/`.

## Worktree Task

The `worktree-task` runtime creates linked worktrees under the repository parent's `.worktrees/<repo>/` directory and opens them as additional tmux windows in the same repo-family session. Architectural ownership only:

- Tracked profile lives at `config/worktree-task.env`; machine-local agent selection lives at `wezterm-x/local/shared.env` (`MANAGED_AGENT_PROFILE`).
- `WEZTERM_CONFIG_REPO` is required; recover with `scripts/runtime/worktree/worktree-task configure --repo /absolute/path`.
- The built-in `tmux-agent` provider executes the agent CLI inside the resolved login shell so PATH and rc files match the user's normal terminal.
- Runtime launch uses a temporary prompt file only long enough to start the new pane; no prompt archive is kept.

Lifecycle prefixes (`dev-` / `task-` / `hotfix-`), reclaim safety rules, branch-naming policy, base-ref strategy, and `Ctrl+k g {d,t,h,r}` quick-create wiring: see [`workspaces.md#task-worktree-lifecycle-model`](./workspaces.md#task-worktree-lifecycle-model).
