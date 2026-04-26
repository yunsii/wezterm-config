---
name: permissions
scope: user
triggers:
  - deciding whether a command should be pre-approved or kept gated
  - reviewing or pruning agent permission policy
  - auditing what categories of commands must always be confirmed
  - choosing the recurrence threshold for promoting a pattern
tags: [permissions, host-agnostic, allowlist-policy, safety]
---

# Permissions

## When To Read

When deciding whether a recurring command should be pre-approved instead of
prompting each call, or when reviewing the rationale behind an existing
permission rule.

The rules here are host-agnostic. Concrete file format, syntax, layering,
and host-specific promotion phrasing live in a host adapter — for Claude
Code see [permissions-claude.md](./permissions-claude.md).

## When Not To Read

When the task is a one-off command that will not recur. Pre-approval is for
patterns, not single invocations.

## Scope

- [permissions-01] This file defines decision policy for permission
  pre-approval and promotion. The host (Claude Code, Codex, IDE
  integration, etc.) reads its own configuration; this file teaches the
  agent how to reason about *whether* a pattern should be pre-approved at
  all and *when* to surface a promotion proposal.
- [permissions-02] Companion to [tool-use-26] / [tool-use-27]: those
  rules say allowlists belong in host config; this file defines the
  host-agnostic standards for what should ever go into one. Concrete
  syntax, file paths, and layering are defined per host (see
  [permissions-claude.md](./permissions-claude.md) for Claude Code).

## Pre-Approval Criteria

Pre-approve a pattern only when ALL hold:

- [permissions-20] Read-only or strictly local-reversible (no shared-state
  mutation, no network publish).
- [permissions-21] No arbitrary-code-execution surface — `bash -c *`,
  `sh -c *`, `python -c *`, `python3 *`, `node -e *`, `node *`,
  `perl -e *`, `eval`, `xargs sh`, `ssh ...` all fail this and must
  never be blanket-approved.
- [permissions-22] No privilege elevation (`sudo *`, `doas *`, admin
  shells, registry writes outside marker-known wrappers); see
  [platform-actions-38].
- [permissions-23] Pattern is narrow enough that an attacker controlling
  one argument cannot pivot. Prefer narrow positional patterns over
  patterns that allow shell-substitution or piping into another shell.
- [permissions-24] Effect is observable. Silent side effects warrant a
  prompt even when reversible ([platform-actions-35]).

## Patterns That Must Stay Prompted

Even if frequent, never pre-approve:

- [permissions-30] Force / destructive ops: `git push --force`,
  `git reset --hard`, `git clean -fd`, `git branch -D`, `rm -rf` outside
  known-safe scratch dirs ([vcs.md], [platform-actions-28]).
- [permissions-31] Privilege elevation: `sudo *`, `doas *`, `runas *`.
- [permissions-32] Arbitrary-code wrappers (see [permissions-21]).
- [permissions-33] Network publishers: `gh pr create`, `gh release
  create`, `gh issue create`, mail / chat senders, anything that mutates
  shared state.
- [permissions-34] Filesystem `chmod` / `chown` on paths outside the
  current project root.
- [permissions-35] Hook-bypass flags: `--no-verify`, `--no-gpg-sign`,
  `--force`, `--yes`, `-y` (see [platform-actions-39]).

## Subagent Inheritance

- [permissions-60] Subagent permission boundaries do not auto-inherit
  from the parent. State the boundary explicitly in the brief
  ([tool-use-37]).
- [permissions-61] Grant subagents the minimum read-only set in their
  agent definition rather than the parent's full allowlist; child
  authority should not exceed parent authority.

## Reporting

- [permissions-70] When proposing changes to a host's allowlist or
  permission policy, output a diff framed as "add / remove / move",
  grouped by layer (when the host has layers), with a one-line rationale
  per entry.
- [permissions-71] When a permission prompt fires unexpectedly, do not
  silently retry under a wider rule — surface the prompt and let the
  user decide whether the rule needs broadening or the call needs
  changing ([tool-use-24..25]).

## Recurrence Gate And Decline Memory

These rules apply to any host that supports proactive promotion of
approved patterns. Host-specific phrasing of the proposal lives with the
host adapter (e.g. [permissions-80..85] in
[permissions-claude.md](./permissions-claude.md)).

- [permissions-86] Recurrence gate: do not propose promotion on the
  first approved prompt for a pattern. Track approved patterns within
  the session; only propose when the same pattern (matched by the
  proposed glob, not by exact argv) has been approved at least twice
  in the current session. Reset the counter at session start.
- [permissions-87] Decline memory: when the user declines a promotion
  proposal in the current session, do not raise it again for the same
  pattern in that session. Treat the decline as scope-bounded — across
  sessions the proposal may resurface once the recurrence gate fires
  again, since the user's stance may have changed.
