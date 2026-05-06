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
- [repo-bootstrap-02] Start with the smallest doc that captures rules you have already seen go wrong; do not pre-write rules for hypothetical mistakes. (GitHub's 2026 study across ~2,500 repos found auto-generated context files cut agent success rates and added ~20% inference cost; human-written ones helped by only ~+4% and only when minimal. Excess context is not free.)
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

The first version is a single `AGENTS.md`, ≤ ~80 lines, growing toward but not past the empirical sweet spot of ~100–150 lines. It should contain only:

- [repo-bootstrap-13] One-paragraph context: what this repo is and what it produces.
- [repo-bootstrap-14] A short `Hard Rules` block — invariants the agent must not break (sync steps, generated files, source-of-truth files, forbidden tools).
- [repo-bootstrap-15] A short `Task Routing` block, even if every entry currently points back to the same file. Stubs reserve the slot for later.
- [repo-bootstrap-16] No narrative history, no roadmap, no per-feature design notes. Those belong in code, commits, or `docs/`.

[repo-bootstrap-17] Hard rules in the first version should be ones you have already seen broken, not preventive guesses.

As the doc grows, the six coverage areas the GitHub study found correlated with strong agent performance are: build/run commands, testing gates, project structure, code style anchors, git workflow, and permission boundaries. Add each only when a real task surfaced its absence.

## Writing Style For Rules

How a rule reads matters as much as whether it exists. Agents follow text faithfully; vague text broadens exploration without improving outcomes.

- [repo-bootstrap-18] Pair every prohibition with a concrete alternative. "Don't instantiate HTTP clients directly — use `lib/http.apiClient` with retry middleware" lands; "don't reinvent HTTP" does not. Warning-only rules consistently underperformed in the GitHub study.
- [repo-bootstrap-19] Prefer one real command or code snippet over a paragraph describing style. "Run `pnpm test -- --run path/to/file`" beats "use the project's test runner".
- [repo-bootstrap-20] Write rules as imperatives with a `Why:` clause when the reason is non-obvious; skip the clause when the rule is self-justifying. Background prose belongs in the body, not inside a numbered rule.

## Relation To README.md

`README.md` and `AGENTS.md` have different audiences and must not blur:

- [repo-bootstrap-21] `README.md` is for humans approaching the project: what it is, why it exists, how to install/run/use, where the docs live. `AGENTS.md` is for agents executing tasks: invariants, routing, what not to do. The split is also empirical: agent harnesses auto-load `AGENTS.md` near 100% of the time; non-root `README.md` files only get read in ~80% of sessions even when the agent is working in that directory, and discovery falls off sharply below the root. So agent rules live in `AGENTS.md`, not `README.md`.

### Both Exist

- [repo-bootstrap-22] If `README.md` already states a fact (build command, dependency list, repo purpose), do not restate it in `AGENTS.md`. Link to the README section or — better — cite the source-of-truth file (`package.json`, `Makefile`) directly.
- [repo-bootstrap-23] When `README.md` and `AGENTS.md` would otherwise duplicate, keep the human-facing copy in `README.md` and the agent-facing rule in `AGENTS.md`; cross-reference only when the human prose carries decision-relevant nuance the agent must respect.

### README Exists, No AGENTS — Refactor Split

- [repo-bootstrap-24] Treat this as an extraction refactor, not a fresh write. Scan the existing `README.md` for content that is actually agent-facing — invariants, "always run X", "never edit Y", routing into deeper docs, generated-file warnings — and lift those into a new `AGENTS.md`.
- [repo-bootstrap-25] Leave human-facing material in `README.md`: project pitch, screenshots, badges, install/run prose, contribution etiquette. Moving them into `AGENTS.md` raises scan cost without changing any agent decision.
- [repo-bootstrap-26] After the split, both files must still stand alone — `README.md` for a new human contributor, `AGENTS.md` for a fresh agent. If extraction would leave `README.md` hollow, the rule was probably not agent-facing to begin with; keep it where it was.
- [repo-bootstrap-27] Replace the lifted prose in `README.md` with a single pointer line ("Agents working on this repo: read `AGENTS.md`"). Do not paraphrase the rule into both files.

### AGENTS Exists, No README

- [repo-bootstrap-28] Add a minimal `README.md` before the repo is published or shared: one paragraph (what / why), install/run, and a link to `AGENTS.md`. Hosts like GitHub render `README.md` by default; its absence makes the project look unmaintained.
- [repo-bootstrap-29] Do not push `AGENTS.md` rules up into `README.md` to fill it. Agent invariants belong with the agent doc; the README's job is orientation for a human who has never seen this repo.
- [repo-bootstrap-30] If the repo is genuinely private and single-tool (only ever read by one agent in one workflow), a missing README is acceptable — but flag it to the user rather than deciding silently.

### Neither Exists (Greenfield)

- [repo-bootstrap-31] If any human will land on the repo (open source, team share, public mirror), write a minimal `README.md` first. Defer `AGENTS.md` until a §Trigger To Bootstrap condition actually fires; an empty conventional repo is self-documenting for agents.
- [repo-bootstrap-32] If the repo is single-author and short-lived (one-off script, spike, throwaway), neither file is required. A top-of-file comment plus commit messages carries more signal than a stub `README.md` / `AGENTS.md` pair would.
- [repo-bootstrap-33] When in doubt, write the README first and the AGENTS doc later. README absence is a discoverability bug; AGENTS absence is at worst a "the agent has to read code" cost — recoverable.

### Discovery Pointers

- [repo-bootstrap-34] In `README.md`, add one line so human contributors discover the agent doc: "Agents working on this repo: read `AGENTS.md`." Place it near the top, not in a deep contributing section.
- [repo-bootstrap-35] In `AGENTS.md`, reference `README.md` only when the README contains rules an agent must follow; otherwise the routing table is the source of truth and pointing back at the README adds noise.

## Progressive Disclosure In The First Doc

Even a single-file `AGENTS.md` should obey [documentation-08]–[documentation-13]: load the minimum context per task. Apply the layering pattern from day one so growth is cheap:

- [repo-bootstrap-36] Lead with `Hard Rules` and `Task Routing` so an agent can decide what to read next without scanning the whole file.
- [repo-bootstrap-37] Keep section bodies short and self-contained; do not require reading section A to understand section B.
- [repo-bootstrap-38] When a section starts requiring "see also" jumps to other sections in the same file, that is the signal it is ready to become a topic file under `docs/` — not a signal to inline more cross-references.
- [repo-bootstrap-39] Use stable rule ids (`[topic-NN]` style) once a section has more than 2–3 rules, so feedback and memory entries can target rules precisely without quoting prose.

## Distilling Scaffolder Output

Tools like Claude Code's `/init` produce a fact dump (commands, directories, style). Treat that output as raw material, not as the finished doc:

- [repo-bootstrap-40] Keep facts that are non-obvious or non-discoverable; drop facts already visible in `package.json` / `Cargo.toml` / `pyproject.toml` / `README.md`.
- [repo-bootstrap-41] Convert long command lists into rules ("run X after Y") only when the ordering matters; otherwise leave them in the build config.
- [repo-bootstrap-42] Strip vague style advice ("write clean code", "follow conventions") — it is noise that displaces real rules.
- [repo-bootstrap-43] Promote anything that sounds like an invariant into `Hard Rules`; everything else stays in the body or is cut.

## When To Split Into Topic Files

[repo-bootstrap-44] Stay single-file as long as the whole doc fits on one screen.

Split when at least one holds:

- [repo-bootstrap-45] A single decision domain has accumulated more than ~3 rules and they share no readers with the rest of the doc.
- [repo-bootstrap-46] The entrypoint has grown past ~150 lines (the upper end of the empirical sweet spot) and skimming it costs more than routing to a sub-file would.
- [repo-bootstrap-47] Two domains have started to interleave in the entrypoint, making rule lookup ambiguous.

There are two valid layering styles; pick one and stay consistent:

- [repo-bootstrap-48] **Nested AGENTS.md** — drop additional `AGENTS.md` files into subdirectories. Agent harnesses walk up from the file being edited and load the nearest one, so each subtree gets local rules without bloating the root. This is the cross-tool convention and gives 100% auto-discovery.
- [repo-bootstrap-49] **Routed topic files** — keep one root `AGENTS.md` with a `Task Routing` table that points at `docs/<topic>.md` files. The agent loads the entrypoint and the matching topic only. Better for shared rules across the whole repo and for hand-tuned reading order; weaker auto-discovery (the agent has to follow the route, not the directory).

[repo-bootstrap-50] When splitting, follow [documentation-29]: split by decision domain, not by audience or chronology. The entrypoint then routes; it does not restate.

## User-Level Vs Project-Level

Before adding a rule to the project-level doc, check whether it would still be correct in a different project:

- [repo-bootstrap-51] If yes, it belongs in the user-level profile, not here.
- [repo-bootstrap-52] If it depends on this repo's tools, layout, or conventions, keep it project-level.
- [repo-bootstrap-53] Do not duplicate user-level rules into the project doc — duplication ages badly and the user layer already loads first.

## Avoid

- [repo-bootstrap-54] Writing the doc before you have evidence of what agents get wrong here.
- [repo-bootstrap-55] Copy-pasting another repo's `AGENTS.md` wholesale; rules without local justification become dead weight.
- [repo-bootstrap-56] Pre-creating empty topic files "for future use" — empty files dilute the routing signal.
- [repo-bootstrap-57] Mixing agent-facing rules with human onboarding prose; keep onboarding in `README.md` and link from there.
- [repo-bootstrap-58] Restating user-level defaults to "make the doc complete" — completeness is not the goal, decision cost is.
