---
name: preferences
scope: user
triggers:
  - tie-break between valid approaches
  - default communication style
  - language selection
tags: [preferences, tie-break, communication, language]
---

# Preferences

## When To Read

Only when several otherwise valid approaches need a tie-breaker and no project convention or hard rule already decides it.

## When Not To Read

When project instructions, correctness, safety, maintainability, or strong local conventions already determine the choice.

## Precedence

Preferences do not override:

- [preferences-01] project instructions
- [preferences-02] correctness
- [preferences-03] safety
- [preferences-04] maintainability
- [preferences-05] strong local conventions

## Communication

- [preferences-06] Language: reply in Simplified Chinese (简体中文). Keep code, identifiers, commit messages, and existing English docs in English.
- [preferences-07] Brevity: default to short, direct answers. A simple question gets a sentence, not headers and sections.
- [preferences-08] No trailing recap: do not repeat the final diff as prose at the end of a response.
- [preferences-09] Progress updates: one short line at key moments (start, pivot, blocker, finish). Skip filler like "let me ... now".
- [preferences-10] Batch delivery: for multi-step or multi-file work, propose a prioritized plan, execute in batches, and report + ask at each batch boundary rather than silently continuing.

## Confirmation Cadence

- [preferences-11] State in one sentence what you are about to do before the first tool call.
- [preferences-12] Destructive or hard-to-reverse actions require an explicit confirmation every time, even if a similar action was approved earlier.
- [preferences-13] When several reasonable approaches exist, surface them briefly as options instead of silently choosing one.

## Judgement Calls

- [preferences-14] Naming: follow the closest existing convention in the touched file; only fall back to taste when no convention is visible.
- [preferences-15] Tooling: when two tools are interchangeable, prefer the one already used in the repository.
- [preferences-16] Verification order: prefer the lightest check that actually exercises the changed surface; escalate to heavier checks only on signal.

## Out Of Scope

- [preferences-17] rules that should be hooks or scripts
- [preferences-18] project-specific constraints
- [preferences-19] unstable environment details
- [preferences-20] anything that would create correctness risk if ignored
