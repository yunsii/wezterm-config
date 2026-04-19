# AGENTS

This file is the agent-facing entry point.
It defines project-level rules for this repository.
User-level reusable agent profiles hosted under `agent-profiles/` are separate and do not override this file unless a user explicitly points an external tool at them.

## Progressive Disclosure

Do not load all docs by default.

Agent workflow:

1. Read `AGENTS.md`.
2. Identify the task category.
3. Open only the matching file under `docs/agents/`.
4. Open a user doc under `docs/user/` only if the change affects user-visible behavior, setup, shortcuts, or workflow.
5. Read additional docs only when the current doc explicitly points to them or the task cannot be completed safely without them.

If the task is narrow, keep the loaded context narrow.

## Hard Rules

- This repository is the source of truth.
- Treat `agent-profiles/` as hosted user-level profile source, not as the project-level instruction source for this repo.
- Windows runtime files are generated from this repo by the `wezterm-runtime-sync` skill in `skills/wezterm-runtime-sync/`.
- Keep workspace definitions in `wezterm-x/workspaces.lua`, not inline in `wezterm.lua`.
- Keep private machine and project overrides in `wezterm-x/local/` and keep tracked templates in `wezterm-x/local.example/`.
- If user-visible behavior changes, update the matching user doc in `/docs/user/` in the same edit.
- If keybindings change, update [`docs/user/keybindings.md`](docs/user/keybindings.md).
- If workspace semantics change, update [`docs/user/workspaces.md`](docs/user/workspaces.md).
- After runtime config changes, run the `wezterm-runtime-sync` skill.
- Do not run Git commands that can contend on the index lock in parallel.
- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.

## Agent Docs

- [`docs/agents/routing.md`](docs/agents/routing.md): task-to-doc routing and load order
- [`docs/agents/repo-structure.md`](docs/agents/repo-structure.md): ownership boundaries and entry points
- [`docs/agents/workspace-rules.md`](docs/agents/workspace-rules.md): workspace model and editing constraints
- [`docs/agents/runtime-invariants.md`](docs/agents/runtime-invariants.md): tmux, agent CLI, and UI invariants
- [`docs/agents/validation.md`](docs/agents/validation.md): sync, reload, and verification rules
- [`docs/agents/commit-guidelines.md`](docs/agents/commit-guidelines.md): commit format, scopes, and message quality rules
