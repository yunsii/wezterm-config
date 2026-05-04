---
name: repo-bootstrap
scope: user
triggers:
  - initializing AGENTS.md / CLAUDE.md in a new or undocumented repo
  - distilling output from `/init`-style scaffolders
  - deciding when to split a single agent doc into layered topic files
tags: [bootstrap, documentation, layering, AGENTS.md]
---

# Repo Bootstrap

## When To Read

When a repository has no `AGENTS.md` / `CLAUDE.md` (or only an auto-generated stub) and you are about to write the first version, or when you are deciding whether an existing single-file doc should be split into a layered profile.

## When Not To Read

When the repo already has a working agent doc and the task is only to add or revise an existing rule. Use [documentation.md](./documentation.md) for that.

## Default

- [repo-bootstrap-01] An agent doc exists to reduce decision cost for the next contributor (human or agent), not to advertise the project.
- [repo-bootstrap-02] Start with the smallest doc that captures rules you have already seen go wrong; do not pre-write rules for hypothetical mistakes.
- [repo-bootstrap-03] A missing agent doc is preferable to a wrong one — agents will read it as ground truth.

## Trigger To Bootstrap

Write the first agent doc when at least one of these holds:

- [repo-bootstrap-04] An agent has already made the same project-specific mistake twice (wrong directory, wrong tool, wrong commit style, missing sync step).
- [repo-bootstrap-05] The repo has non-obvious build / sync / generate steps that are not discoverable from `package.json` / `Makefile` / `README.md`.
- [repo-bootstrap-06] Multiple humans or multiple agent tools (Claude Code, Codex, Cursor, etc.) will collaborate on the repo.
- [repo-bootstrap-07] There are hard rules ("never do X", "always run Y after Z") that cannot be inferred from reading code.

[repo-bootstrap-08] If none of the above hold, do not bootstrap yet. An empty repo with conventional structure is self-documenting.

## File Layout

- [repo-bootstrap-09] The real file is `AGENTS.md`. `CLAUDE.md` is a relative symlink pointing at it (`ln -s AGENTS.md CLAUDE.md`).
- [repo-bootstrap-10] Reason: `AGENTS.md` is the cross-tool standard (Codex, Cursor, and Claude Code all read it); `CLAUDE.md` exists only so older Claude Code paths still resolve. One source of truth, no drift.
- [repo-bootstrap-11] Do not commit two parallel files with the same content. If `CLAUDE.md` is already a real file in the repo, convert it: `mv CLAUDE.md AGENTS.md && ln -s AGENTS.md CLAUDE.md`.
- [repo-bootstrap-12] On hosts where symlinks are unreliable (some Windows checkouts without `core.symlinks=true`), keep only `AGENTS.md` and skip the symlink rather than maintaining two files.

## First-Version Shape

The first version is a single `AGENTS.md`, ≤ ~80 lines. It should contain only:

- [repo-bootstrap-13] One-paragraph context: what this repo is and what it produces.
- [repo-bootstrap-14] A short `Hard Rules` block — invariants the agent must not break (sync steps, generated files, source-of-truth files, forbidden tools).
- [repo-bootstrap-15] A short `Task Routing` block, even if every entry currently points back to the same file. Stubs reserve the slot for later.
- [repo-bootstrap-16] No narrative history, no roadmap, no per-feature design notes. Those belong in code, commits, or `docs/`.

[repo-bootstrap-17] Hard rules in the first version should be ones you have already seen broken, not preventive guesses.

## Distilling Scaffolder Output

Tools like Claude Code's `/init` produce a fact dump (commands, directories, style). Treat that output as raw material, not as the finished doc:

- [repo-bootstrap-18] Keep facts that are non-obvious or non-discoverable; drop facts already visible in `package.json` / `Cargo.toml` / `pyproject.toml` / `README.md`.
- [repo-bootstrap-19] Convert long command lists into rules ("run X after Y") only when the ordering matters; otherwise leave them in the build config.
- [repo-bootstrap-20] Strip vague style advice ("write clean code", "follow conventions") — it is noise that displaces real rules.
- [repo-bootstrap-21] Promote anything that sounds like an invariant into `Hard Rules`; everything else stays in the body or is cut.

## When To Split Into Topic Files

[repo-bootstrap-22] Stay single-file as long as the whole doc fits on one screen.

Split into a `docs/<topic>.md` (or equivalent) layered profile when at least one holds:

- [repo-bootstrap-23] A single decision domain has accumulated more than ~3 rules and they share no readers with the rest of the doc.
- [repo-bootstrap-24] The entrypoint has grown past ~120 lines and skimming it costs more than routing to a sub-file would.
- [repo-bootstrap-25] Two domains have started to interleave in the entrypoint, making rule lookup ambiguous.

[repo-bootstrap-26] When splitting, follow [documentation-29]: split by decision domain, not by audience or chronology. The entrypoint then routes; it does not restate.

## User-Level Vs Project-Level

Before adding a rule to the project-level doc, check whether it would still be correct in a different project:

- [repo-bootstrap-27] If yes, it belongs in the user-level profile, not here.
- [repo-bootstrap-28] If it depends on this repo's tools, layout, or conventions, keep it project-level.
- [repo-bootstrap-29] Do not duplicate user-level rules into the project doc — duplication ages badly and the user layer already loads first.

## Avoid

- [repo-bootstrap-30] Writing the doc before you have evidence of what agents get wrong here.
- [repo-bootstrap-31] Copy-pasting another repo's `AGENTS.md` wholesale; rules without local justification become dead weight.
- [repo-bootstrap-32] Pre-creating empty topic files "for future use" — empty files dilute the routing signal.
- [repo-bootstrap-33] Mixing agent-facing rules with human onboarding prose; keep onboarding in `README.md` and link from there.
- [repo-bootstrap-34] Restating user-level defaults to "make the doc complete" — completeness is not the goal, decision cost is.
