---
name: permissions-claude
scope: user
applies-to: claude-code
triggers:
  - editing ~/.claude/settings.json or .claude/settings.json or .claude/settings.local.json
  - choosing which Claude Code permission layer a new entry belongs in
  - writing or auditing PreToolUse classifier hooks
  - phrasing a Claude-side promotion proposal
tags: [permissions, host-config, claude-code, allowlist]
---

# Permissions — Claude Code Adapter

## When To Read

When the task touches Claude Code's permission configuration concretely:
adding to / removing from / moving entries between `settings.json` files,
writing PreToolUse classifier hooks, or proposing promotion of a just-
approved pattern.

For host-agnostic standards (what *qualifies* as pre-approvable, what
must stay prompted, recurrence gate, decline memory) read
[permissions.md](./permissions.md) first; this file only adds Claude
Code-specific concretizations.

## When Not To Read

When working in any other host (Codex, IDE integration). The host-agnostic
rules in [permissions.md](./permissions.md) still apply.

## Layering

Claude Code reads three layers, highest precedence first; this file
defines where each rule belongs.

- [permissions-10] User-level `~/.claude/settings.json` carries
  stack-agnostic, machine-stable rules: read-only investigation verbs,
  generic `git` read subcommands, common documentation domains. Anything
  that would still be safe in a different repo belongs here.
- [permissions-11] Project-tracked `.claude/settings.json` carries rules
  specific to the repository that any teammate or fresh checkout needs:
  project script paths, project-specific tooling.
- [permissions-12] Project-local `.claude/settings.local.json` is for
  the current operator's transient experiments. Treat it as scratch —
  entries here should either be promoted up a layer or garbage-collected.
- [permissions-13] When the same rule appears at two layers, delete the
  lower one. Duplicates rot independently.
- [permissions-14] When proposing a new entry, name the layer explicitly
  ("add to user-level" / "add to project-tracked") and justify the choice
  against [permissions-10..12].

## Hygiene

- [permissions-40] One-shot commands that drifted into
  `settings.local.json` during a session are noise, not security. Sweep
  them out periodically or run the host's own pruning skill (e.g.
  `fewer-permission-prompts`).
- [permissions-41] Before adding an entry, search the existing allowlist
  for an overlapping or wider rule; consolidate instead of stacking.
- [permissions-42] Group entries by domain (`git`, `tmux`, `wezterm`,
  `web`, `mcp__*`) within each layer for readability.
- [permissions-43] When elevating an entry from `.local.json` to tracked
  `.claude/settings.json`, the rule should be reviewable in a diff —
  name explicit paths, not regex soup.
- [permissions-44] Tag user-level entries that have a clear safety
  rationale ("read-only investigation", "documentation domain") in the
  proposal message; this is the audit trail [permissions-43] expects.

## Hooks Over Allowlist

- [permissions-50] When the same shape recurs across many specific
  arguments (e.g. "any read-only `tmux ...` query"), prefer a PreToolUse
  classifier hook that approves by regex over an exploding allowlist.
- [permissions-51] Hooks must be dry-runnable and visibly logged
  ([automation-25..30]); a wrong regex in a hook is harder to spot than
  a wrong glob in JSON.
- [permissions-52] A hook that pre-approves must still respect
  [permissions-20..24]; hook scope is not an excuse to widen the
  pre-approval criteria.

## Proactive Promotion

These rules concretize [permissions-86] / [permissions-87] from
[permissions.md](./permissions.md) for Claude Code.

- [permissions-80] When a Bash / Skill / Web call triggers a host
  permission prompt and the user approves it, agent should — at the end
  of the same turn — assess whether the pattern qualifies under
  [permissions-20..24] and has appeared at least twice in the current
  session ([permissions-86]). A single approval is treated as a
  one-shot.
- [permissions-81] If yes, propose promotion in one English line that
  names BOTH the pattern AND the target layer, with a one-clause
  rationale:

      "Promote `<pattern>` to <layer>? (reason: <why this layer>)"

  Always phrase the prompt-to-promote in English regardless of the
  surrounding conversation language. Pick the layer per
  [permissions-10..12]:

  - **user-level** `~/.claude/settings.json` — when the pattern is
    stack-agnostic and would still be safe in any other repo
    (e.g. `rg`, `git status*`, doc-domain WebFetch).
  - **project-tracked** `.claude/settings.json` — when the pattern
    references this repo's scripts, tools, or paths and any teammate
    on a fresh checkout would need it (e.g. `scripts/dev/foo.sh`,
    project-specific binary paths).
  - **project-local** `.claude/settings.local.json` — only when the
    pattern is operator-specific transient experimentation; default
    answer is to NOT propose this layer (treat `.local.json` as
    scratch, [permissions-12]).

- [permissions-82] If the pattern could fit either user-level or
  project-tracked, prefer user-level — narrower-scope rules are easier
  to add later than to retract. State the alternative in the proposal
  ("user-level; or project-tracked if you want it scoped to this repo").
- [permissions-83] Do not edit any settings.json without explicit
  confirmation. Promotion is a user-authorized step, not an agent
  decision ([automation-30], [platform-actions-41]).
- [permissions-84] Skip the prompt-to-promote when: the call is
  one-shot (specific absolute path, ad-hoc one-line grep), the pattern
  fails any of [permissions-30..35], or the user has indicated this
  turn is exploratory.
- [permissions-85] When proposing, also check whether an existing
  allowlist entry already covers a wider pattern ([permissions-41]).
  If so, surface it instead of stacking — "Already covered by
  `<wider>`, no new entry needed" beats a redundant entry.
