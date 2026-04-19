# Agent Profile v1

This directory contains a versioned user-level agent profile.

## Purpose

This profile defines stable personal operating rules for coding agents across repositories.
It is stored in a repository for versioning and reuse, but it is not tied to any single project.

Use this package when a coding agent needs user-level defaults for execution style, validation discipline, refactor behavior, automation strategy, documentation structure, and reporting.

## Layout

- [en/AGENTS.md](./en/AGENTS.md): authoritative English entrypoint

Topic files under `en/` and `zh/` are mirrored one-to-one:

- [en/validation.md](./en/validation.md)
- [en/implementation.md](./en/implementation.md)
- [en/refactor.md](./en/refactor.md)
- [en/automation.md](./en/automation.md)
- [en/documentation.md](./en/documentation.md)
- [en/reporting.md](./en/reporting.md)
- [en/preferences.md](./en/preferences.md)

`en/` is the source of truth.
`zh/` contains a reference translation and is not part of the default loading path.
If wording differs, `en/` takes precedence.

## How To Attach

Default entrypoint:
- [en/AGENTS.md](./en/AGENTS.md)

Recommended compatibility mappings:
- `AGENTS.md -> agent-profiles/v1/en/AGENTS.md`
- `CLAUDE.md -> agent-profiles/v1/en/AGENTS.md`

Suggested user-level Claude setup:
- `~/.claude/CLAUDE.md -> /absolute/path/to/repo/agent-profiles/v1/en/AGENTS.md`

Prefer a single source of truth plus symlink-based compatibility entrypoints.
Avoid copying the same content into multiple files.

## How To Load

1. Read [en/AGENTS.md](./en/AGENTS.md) first.
2. Load only the next relevant topic file for the current task.
3. Do not preload the whole profile.
4. Ignore `zh/` unless bilingual reading, translation, or comparison is explicitly needed.

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

- Keep `en/` and `zh/` file names mirrored.
- Update English first.
- Sync Chinese after English changes.
- Keep the main entrypoint short.
- Move detailed rules into topic files.
- Prefer automation over documentation for rules that must execute consistently.
