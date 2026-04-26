# Design Notes: Permissions Topic

Captures the design decisions behind the `permissions` topic (added
2026-04-26) and its split into a host-agnostic core plus a Claude Code
adapter. Reference material for future maintainers — not loaded by
agents.

## Problem

The existing `tool-use.md` rules [tool-use-26] / [tool-use-27] state
that "host-specific mechanisms for pre-approving commands or reducing
permission prompts belong in host configuration, not in this profile,"
but the profile had no companion document explaining *what should*
qualify for pre-approval, *when* an agent should propose promotion,
or *what categories must always stay prompted*. The result was
case-by-case reasoning per session and an `~/.claude/settings.local.json`
that grew to ~150 entries of one-shot historical commands without a
hygiene policy.

## Layered Solution

The topic was published in two layers, materialized as two files in
`en/`:

- `en/permissions.md` — host-agnostic decision policy: pre-approval
  criteria, must-stay-prompted categories, subagent inheritance,
  reporting, and the recurrence-gate / decline-memory rules. Loaded by
  any agent on any host.
- `en/permissions-claude.md` — Claude Code adapter: layering between
  `~/.claude/settings.json` / `.claude/settings.json` /
  `.claude/settings.local.json`, hygiene rules tied to that layering,
  PreToolUse classifier hooks, and the English-phrased promotion
  proposal format. Loaded only on Claude Code targets.

Stable rule IDs were preserved across the split — IDs `[permissions-NN]`
remain globally unique and live in whichever file owns the rule. This
honors the maintenance rule from `v1/README.md` ("Do not renumber
existing rule IDs when inserting new rules").

## Why The Split Was Necessary

The first iteration was a single `permissions.md` that hardcoded
Claude Code specifics: file names (`settings.json` /
`settings.local.json`), rule syntax (`Bash(...)`, `Skill(...)`,
`WebFetch(domain:...)`), hook event names (`PreToolUse`), and skill
references (`fewer-permission-prompts`). Linking that file into
`~/.codex/permissions.md` via `link-agent-profile.sh` exposed the
mismatch: Codex agents would have read a topic referencing files and
syntax that do not exist on their host.

This violated [tool-use-26] / [tool-use-27]'s own injunction —
host-specific keys had leaked into the profile. The split restores the
separation: the profile defines policy, the adapter defines a host's
concrete realization of that policy.

## Why There Is No `permissions-codex.md`

Codex's safety model is fundamentally different: a small set of
high-cardinality knobs (`approval_policy` × `sandbox_mode` ×
`writable_roots` × `network_access`), tuned once by the operator, not
a per-pattern allowlist promoted by the agent. There is no
agent-facing decision loop equivalent to "should this Bash glob be
added to user-level `settings.json`?"

The Codex-side material that would otherwise live in a host adapter
is operator setup notes, not agent rules — those are kept at
[`../host-setup/codex.md`](../host-setup/codex.md), outside the agent
profile's loaded scope but adjacent to it for discoverability.

## File-Naming And Linking Convention

Host adapter files use the flat `<topic>-<host>.md` form (e.g.
`permissions-claude.md`) inside `en/`, rather than a `host/<host>/`
subdirectory. Reasons:

- Keeps `link-agent-profile.sh`'s glob (`<source>/*.md`) intact.
- Each adapter is a sibling of the topic it adapts — easy to discover.
- Avoids invisible directory nesting in the source layout.

`link-agent-profile.sh` was extended with a known-hosts whitelist
(`claude codex`). A file is treated as a host adapter only when its
last hyphen-separated suffix is in that whitelist — so `tool-use.md`
and `platform-actions.md` are not misclassified as adapters for
nonexistent hosts named `use` or `actions`.

Adding a new host means: create `host/permissions-<host>.md` (or
similar), add `<host>` to the whitelist, and Codex/Claude/etc. each
receive only the adapter that matches.

## Recurrence Gate And Decline Memory

The proactive-promotion rules ([permissions-80..85] in
`permissions-claude.md`, plus the host-agnostic gates
[permissions-86] and [permissions-87] in `permissions.md`) were
tightened in two stages:

1. Initial draft fired a promotion proposal after every approved
   permission prompt — too noisy in practice; one-off invocations
   would also trigger.
2. The recurrence gate ([permissions-86]) was added: a pattern must
   be approved at least twice in the same session before any
   proposal fires. The decline memory ([permissions-87]) was added
   to ensure a single decline silences that pattern for the rest of
   the session. Both reset at session start, so a user's stance can
   change across sessions without manual intervention.

Net effect: routine commands that the user approves once and never
sees again stay completely silent; only genuinely repeating patterns
surface as candidates.

## Pre-Approval Rollout

Alongside the new topic, `~/.claude/settings.json` got its first
`permissions.allow` block — 57 entries grouped into five categories:
filesystem read-only, text/diff/encoding probes, `git` read
subcommands, `gh` read subcommands, package-manager metadata, and
documentation-domain WebFetch. Project-level
`.claude/settings.json` was not touched; existing
`.claude/settings.local.json` clean-up is deferred to a future run of
the `fewer-permission-prompts` skill.

## Open Items

- A `notify` hook for Codex (referenced in
  [`../host-setup/codex.md`](../host-setup/codex.md) §6) is
  un-implemented; build when actually wanted.
- `.claude/settings.local.json` still carries one-shot historical
  entries from prior sessions; pruning is operator-triggered, not
  automatic.
- Several broad rules in the existing project allowlist (`Bash(git *)`,
  `Bash(node *)`, `Bash(bash:*)`) violate [permissions-21] /
  [permissions-30] and should be tightened — deferred pending a
  per-entry review session.
