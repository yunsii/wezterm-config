# Agent Profile v1

This directory contains a versioned user-level agent profile.

## Purpose

This profile defines stable personal operating rules for coding agents across repositories.
It is stored in a repository for versioning and reuse, but it is not tied to any single project.

Use this package when a coding agent needs user-level defaults for execution style, validation discipline, refactor behavior, automation strategy, documentation structure, and reporting.

## Layout

- [en/AGENTS.md](./en/AGENTS.md): entrypoint

Topic files under `en/`:

- [en/validation.md](./en/validation.md)
- [en/implementation.md](./en/implementation.md)
- [en/refactor.md](./en/refactor.md)
- [en/automation.md](./en/automation.md)
- [en/tool-use.md](./en/tool-use.md)
- [en/documentation.md](./en/documentation.md)
- [en/platform-actions.md](./en/platform-actions.md)
- [en/clipboard.md](./en/clipboard.md)
- [en/vcs.md](./en/vcs.md)
- [en/reporting.md](./en/reporting.md)
- [en/preferences.md](./en/preferences.md)
- [en/permissions.md](./en/permissions.md)

Host adapter files (linked only into the matching host's target by
`scripts/dev/link-agent-profile.sh`):

- [en/permissions-claude.md](./en/permissions-claude.md)

## Design Notes

Per-topic design rationale lives under `notes/` and is not loaded by
agents — reference material for maintainers.

- [notes/permissions-design.md](./notes/permissions-design.md) — why
  the `permissions` topic was added, why it was split into a
  host-agnostic core plus a Claude Code adapter, why no
  `permissions-codex.md` exists, and the recurrence-gate /
  decline-memory rationale.

## Host Setup

Operator-facing recipes for configuring an agent host. Not loaded by
agents; consult when setting up a CLI tool or rotating machines.

- [host-setup/codex.md](./host-setup/codex.md) — Codex CLI
  (`~/.codex/config.toml`) tuning: approval policy × sandbox mode,
  profiles, writable roots, env policy, MCP mirroring, notify hook.

Each topic file carries YAML frontmatter (`name`, `scope`, `triggers`, `tags`) so agents or tools can index and load on demand.
Each rule carries a stable identifier of the form `[<topic>-NN]` so feedback, memory entries, and reviewers can reference rules precisely.

## How To Attach

Default entrypoint:
- [en/AGENTS.md](./en/AGENTS.md)

Recommended user-level integrations (entrypoint plus one symlink per topic):
- `~/.codex/AGENTS.md -> /absolute/path/to/repo/agent-profiles/v1/en/AGENTS.md`
- `~/.codex/<topic>.md -> /absolute/path/to/repo/agent-profiles/v1/en/<topic>.md` (one per topic file)
- `~/.claude/CLAUDE.md -> /absolute/path/to/repo/agent-profiles/v1/en/AGENTS.md`
- `~/.claude/<topic>.md -> /absolute/path/to/repo/agent-profiles/v1/en/<topic>.md` (one per topic file)

The topic mirrors are required because `AGENTS.md` routes to topic files via relative links (`./validation.md`, …) that must resolve alongside the entrypoint in the target directory.
This repository provides `scripts/dev/link-agent-profile.sh` to create or refresh these links idempotently for any target directory (`~/.claude/`, `~/.codex/`) that exists on the host.

Optional repository compatibility mappings:
- `AGENTS.md -> agent-profiles/v1/en/AGENTS.md`
- `CLAUDE.md -> agent-profiles/v1/en/AGENTS.md`

Prefer a single source of truth plus symlink-based compatibility entrypoints.
Avoid copying the same content into multiple files.

## How To Load

1. Read [en/AGENTS.md](./en/AGENTS.md) first.
2. Load only the next relevant topic file for the current task.
3. Do not preload the whole profile.

## Link Conventions

Use Markdown links for document navigation.
Use `source -> target` notation only for symlink, alias, or entrypoint mapping.

Examples:
- [en/AGENTS.md](./en/AGENTS.md)
- `AGENTS.md -> agent-profiles/v1/en/AGENTS.md`

## Versioning

- `v1` is the current stable profile version.
- Non-breaking refinements stay within `v1`.
- Structural redesigns should be published as `v2`.

## Maintenance

- Keep the main entrypoint short.
- Move detailed rules into topic files.
- Prefer automation over documentation for rules that must execute consistently.
- Do not renumber existing rule IDs when inserting new rules; append or use suffixes (`-03a`) to keep identifiers stable.
