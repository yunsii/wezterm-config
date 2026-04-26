# User-Level AGENTS

This file defines my default working rules for coding agents across projects.

Read this file first.
Load only the next relevant topic file based on the Task Routing table below.
Do not preload the whole profile.

## Scope And Precedence

This is user-level guidance, not project-level guidance.
Use it for stable defaults that apply across repositories, languages, and tools.

A rule belongs at the user level only if it would still be correct in a different project, stack, or host.
If switching projects would make it wrong, it belongs in that project's `AGENTS.md` / `CLAUDE.md` instead.

Precedence (highest wins):

1. Explicit user chat instructions.
2. Project instructions — the nearest `AGENTS.md` / `CLAUDE.md` / equivalent to the edited file.
3. This user-level profile.
4. Agent or platform built-in defaults.

When layers conflict, the higher layer wins. Do not discard a higher-layer rule on the strength of a lower-layer preference.

## Operating Model

Default loop:

1. Understand the existing system before changing it.
2. Find the narrowest owning area.
3. Make the smallest change that closes the task.
4. Verify automatically. Plans must declare how the change will be verified before execution starts; see [validation-29] and [validation-30].
5. Report what changed, how it was verified, and what remains uncertain.

Continue unless blocked.
Detailed escalation criteria live in [validation.md](./validation.md).

## Task Routing

Read this file first, then open only the matching topic file.
Read additional topic files only when the current file points to them or the task crosses that boundary.

- Testing strategy, completion criteria, human-verification thresholds → [validation.md](./validation.md)
- Structure, abstractions, module boundaries, reliability, performance → [implementation.md](./implementation.md)
- Restructuring existing code or replacing a subsystem → [refactor.md](./refactor.md)
- Whether a rule belongs in doc, script, hook, skill, or plugin → [automation.md](./automation.md)
- Choosing, sequencing, or batching tool calls → [tool-use.md](./tool-use.md)
- Creating, splitting, or maintaining agent-facing docs → [documentation.md](./documentation.md)
- Host-side side effects (app focus, browser, notifications, reveal in shell, wrapper boundary) → [platform-actions.md](./platform-actions.md)
- Writing to the system clipboard → [clipboard.md](./clipboard.md)
- Handling credentials, tokens, or any data expected to stay local → [secrets.md](./secrets.md)
- Commits, branches, merges, pushes, pull/merge requests → [vcs.md](./vcs.md)
- Final responses and progress updates → [reporting.md](./reporting.md)
- Tie-breaking between otherwise valid approaches, language and communication style → [preferences.md](./preferences.md)
- Pre-approval policy, recurrence-gated promotion, what must stay prompted → [permissions.md](./permissions.md)
- Claude Code-specific allowlist files (`settings.json` / `.claude/settings.json` / `settings.local.json`), layering, PreToolUse hooks → [permissions-claude.md](./permissions-claude.md)

Each topic file carries YAML frontmatter (`name`, `scope`, `triggers`, `tags`) for indexed discovery.
Each rule carries a stable identifier of the form `[<topic>-NN]` so feedback, memory entries, and reviewers can reference rules precisely.

## Default Posture

One-line summaries so the entrypoint stays scannable.
Full rules live in the routed topic file.

- Validation: self-verify with the lightest valid path; do not use the user as the primary tester; when a plan cannot self-validate, say why and propose an alternative.
- Refactor: understand before restructuring; keep refactor and behavior change separate.
- Implementation: prefer simple, explicit, observable, reversible; avoid speculative abstraction.
- Automation: implement over instruct when consistency matters.
- Tool use: specialized tool over shell; batch independent calls; merge read-only shell; Read before Write.
- Documentation: layered and sparse; one source of truth per rule; update alongside the behavior it describes.
- Platform actions: narrow, explicit, reversible; ask before secrets, destructive, or hard-to-undo actions; do not self-elevate privileges or bypass confirmation gates.
- Secrets: never echo into logs, commits, PR bodies, or subagent briefs; flag leaks immediately and prefer rotation over silent cleanup.
- VCS: never auto-commit / auto-push / skip hooks / force-push to main; user owns the history.
- Reporting: state what changed, how it was verified, and what remains uncertain.
- Preferences: tie-break with taste only when correctness, safety, or local convention does not already decide.
- Permissions: layer host config (user-level safe-by-default, project-tracked for repo-specific, `.local.json` is scratch); never pre-approve elevation, force ops, or arbitrary-code wrappers; after each approved permission prompt, propose promotion in English with target layer named.
- Language: reply in Simplified Chinese (简体中文); full rule in [preferences.md](./preferences.md).
