# Docs

Use this doc when you need the shortest possible map of the repository docs.

## Read Next

- First-time setup or machine-local config:
  Read [`setup.md`](./setup.md).
- Daily edit, sync, reload, and verification:
  Read [`daily-workflow.md`](./daily-workflow.md).
- Workspace model and config boundaries:
  Read [`workspaces.md`](./workspaces.md).
- Shortcut reference:
  Read [`keybindings.md`](./keybindings.md).
- Tabs, status lines, and selection behavior:
  Read [`tmux-ui.md`](./tmux-ui.md).
- Agent-attention pipeline (Claude hooks, state file, badges, `Alt+,` / `Alt+.` / `Alt+/`):
  Read [`agent-attention.md`](./agent-attention.md).
- Headless Chrome debug instance, `Alt+b` / `Alt+Shift+b`, `chrome://inspect` workflow, `CDP·…` badge:
  Read [`browser-debug.md`](./browser-debug.md).
- Cutting a Windows host-helper release, updating `release-manifest.json`, side-loading the release zip:
  Read [`host-helper-release.md`](./host-helper-release.md).
- Logs, diagnostics, and smoke tests:
  Read [`diagnostics.md`](./diagnostics.md).
- Entry points, ownership, and runtime design:
  Read [`architecture.md`](./architecture.md).
- Alt+/ popup hot path, bench harnesses, cross-FS routing rule:
  Read [`performance.md`](./performance.md).
- Why tmux 3.6+ is required, IME flicker, DEC mode 2026 investigation:
  Read [`ime-flicker-and-sync-output.md`](./ime-flicker-and-sync-output.md).
- Commit message format and split guidance:
  Read [`commit-guidelines.md`](./commit-guidelines.md).

## Doc Rules

- Keep one topic in one primary file. Link to it instead of restating the same rule elsewhere.
- Prefer editing an existing topic doc over adding a new sibling file.
- Keep setup, workflow, UI behavior, diagnostics, and architecture separate.
- Put presentations, outlines, and non-reference material under [`presentations/`](./presentations/).
