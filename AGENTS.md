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
- Diagnostics, logs, or smoke tests:
  Read [`docs/diagnostics.md`](docs/diagnostics.md).
- Ownership boundaries, runtime architecture, or entry points:
  Read [`docs/architecture.md`](docs/architecture.md).
- Preparing a commit message or deciding commit split:
  Read [`docs/commit-guidelines.md`](docs/commit-guidelines.md).

## Hard Rules

- This repository is the source of truth.
- Treat `agent-profiles/` as hosted user-level profile source, not as the project-level instruction source for this repo.
- Windows runtime files are generated from this repo by the `wezterm-runtime-sync` skill in `skills/wezterm-runtime-sync/`.
- When agents run Windows-related scripts or smoke tests from WSL, prefer the repo-local wrappers and `scripts/dev/...` entrypoints in this repository over direct `cmd.exe` invocations or ad-hoc `powershell.exe -Command ...`.
- For Windows file inspection from agents, resolve runtime paths through `scripts/runtime/windows-runtime-paths-lib.sh` and then use WSL-native tools on the `*_WSL` paths instead of `cmd.exe /c dir`, `cmd.exe /c type`, or similar console commands.
- Keep workspace definitions in `wezterm-x/workspaces.lua`, not inline in `wezterm.lua`.
- Keep private machine and project overrides in `wezterm-x/local/` and keep tracked templates in `wezterm-x/local.example/`.
- Prefer updating an existing doc in `docs/` over adding a new sibling file; keep presentations under `docs/presentations/`.
- If behavior, keybindings, workspace semantics, tmux UI, or diagnostics change, update the matching docs in the same edit.
- After runtime config changes, run the `wezterm-runtime-sync` skill.
- Do not run Git commands that can contend on the index lock in parallel.
- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
