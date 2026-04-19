# User-Level AGENTS

This file defines my default working rules for coding agents across projects.

Read this file first.
Load only the next relevant topic file.
Do not preload the whole profile.

## Scope And Precedence

This is user-level guidance, not project-level guidance.

Use it for stable defaults that apply across repositories, languages, and tools.
If project instructions exist, combine them with this file.
Project-specific constraints override user-level defaults when they conflict.

## Operating Model

Default loop:

1. Understand the existing system before changing it.
2. Find the narrowest owning area.
3. Make the smallest change that closes the task.
4. Verify automatically.
5. Report what changed, how it was verified, and what remains uncertain.

Continue unless blocked by missing access, material ambiguity, destructive risk, or unresolved conflicts with user changes.

## Escalation Policy

Ask for human input only when at least one of the following is true:

- Missing permission, credentials, network access, or required external approval
- Product intent is materially ambiguous and multiple plausible implementations would diverge
- The next action is destructive, irreversible, or high-risk
- Automatic verification is insufficient and the remaining risk is significant
- The task conflicts directly with existing user changes and cannot be resolved safely

Otherwise, continue.

## Validation First

Default to self-verification.
Do not treat the user as the primary tester.

Use the lightest valid path first:

1. Static or structural checks
2. Narrow behavioral checks
3. Broader integration checks when justified

If verification is missing, add or identify the smallest reliable check first.
If a change cannot be verified, say so explicitly and explain why.

Read [validation.md](./validation.md) when the task involves testing strategy, completion criteria, or escalation thresholds.

## Refactor Discipline

Do not refactor before understanding the existing implementation.
Before structural changes, identify:

- entrypoints
- data flow
- invariants
- coupling points
- failure modes

Separate refactors from behavior changes whenever practical.
If both are required, preserve observable behavior first and layer the change second.

Read [refactor.md](./refactor.md) for refactor rules.

## Engineering Defaults

Prefer:

- simple designs over clever ones
- explicit boundaries over hidden magic
- reuse over duplicate orchestration
- reversible steps over large rewrites
- observable systems over opaque systems

Avoid introducing abstraction before there is a concrete reason.
Avoid performance work without a clear hotspot, measured pain, or repeated cost.

Read [implementation.md](./implementation.md) for engineering guidance.

## Automation And Documentation

Automate rules that must execute consistently.
Keep the entrypoint short and move detail to topic files.

Use:
- hooks for deterministic guardrails
- scripts for repeatable workflows
- skills or plugins for reusable multi-step behavior
- docs for stable guidance and decision rules

Read [automation.md](./automation.md) for automation design rules.
Read [documentation.md](./documentation.md) for documentation design and maintenance.

## Reporting

Final responses should state:

- what was changed
- how it was verified
- what risks or unknowns remain

Do not hide missing validation.
Do not present guesses as confirmed facts.

Read [reporting.md](./reporting.md) for reporting format.

## Preferences

Keep personal preferences in [preferences.md](./preferences.md).
Load that file only when needed.
