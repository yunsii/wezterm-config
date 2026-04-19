# Commit Guidelines

Use this doc only when you are preparing a commit or reviewing commit readiness.

## Goal

Use a commit format that is:

- easy to scan in `git log`
- specific enough to explain intent
- small enough for review and later rollback

This repo uses a lightweight Conventional Commits style with repo-specific scopes.

## Title Shape

Preferred title format:

```text
<type>(<scope>): <description>
```

Scope is optional when it does not add useful information:

```text
<type>: <description>
```

## Allowed Types

- `feat`: new behavior or capability
- `fix`: bug fix or behavior correction
- `docs`: documentation-only changes
- `refactor`: code restructuring without intended behavior change
- `perf`: performance improvement
- `test`: test additions or test-only changes
- `chore`: maintenance, tooling, or housekeeping that does not fit the types above

## Scope Rules

Use the narrowest stable scope that explains the change area.

Portable examples:

- `api`
- `auth`
- `ui`
- `docs`
- `scripts`

If a file-oriented scope is clearer, use that instead, such as:

- `server.ts`
- `build.sh`
- `login-form`
- `deploy`

## Repo Scopes

For this repository, the most useful stable scopes are:

- `workspaces`
- `wezterm`
- `tmux`
- `titles`
- `ui`
- `scripts`
- `docs`
- `agents`

If a repo-specific file-oriented scope is clearer, use that instead, such as:

- `workspaces.lua`
- `tmux.conf`
- `open-project-session`
- `run-managed-command`

## Title Rules

- Keep the title to one line.
- Use lowercase after the prefix unless capitalization is required by a proper name or acronym.
- Use imperative phrasing.
- Do not end the title with a period.
- Keep the title concise; around 50 characters is the soft limit.

Good examples:

- `docs(workspaces): clarify local override boundaries`
- `fix(tmux): avoid stale status refresh`
- `feat(ui): add compact table density`

Avoid:

- `Update stuff`
- `Fix bug`
- `docs: Clarify Commit Rules.`

## Body Rules

- Separate title and body with one blank line.
- Add a body when the reason is not obvious from the diff or title.
- Focus on why and constraints, not a line-by-line diff narration.
- Use 2-4 short lines in most cases.

Suggested body structure:

1. State the problem or current limitation.
2. Explain why this approach is the right fix.
3. Note important side effects, constraints, or follow-up implications if needed.

## AI Collaboration Metadata

When AI-assisted development details add review value, append an `AI Collaboration:` block after the main body.

Prefer adding the block when debugging was non-trivial, environment constraints mattered, or meaningful human course-corrections changed the implementation plan more than once.

Preferred shape:

```text
<type>(<scope>): <description>

<problem / motivation>
<approach / rationale>
<important side effects if any>

AI Collaboration:
- human-adjustments: 3 (excluding escalation-only interactions)
- hard-parts: missed an edge case in tenant ID normalization
- hard-parts: required repeated layout debugging before the mobile breakpoint stabilized
- ai-complexity: medium
- tools-used: mcp.chrome_devtools, deepwiki-mcp-cli
- skills-used: vercel-react-best-practices
```

- Keep the title and main body readable without the AI block.
- Use the AI block to capture process context, not a full debug diary.
- Omit fields that do not add signal for the current commit.
- Keep the AI block flat: use single-level bullets only; do not nest bullets under fields such as `hard-parts`.
- Prefer concrete summaries over vague notes like `debugged a lot`.
- Do not include raw escalation logs or approval history.

Common fields: `human-adjustments`, `hard-parts`, `ai-complexity`, `tools-used`, `skills-used`.
Record only tools or skills that materially influenced the result, and keep the block short enough to scan in `git log --format=fuller`.

Complexity guidance:

- `low`: narrow change, few constraints, little or no debugging
- `medium`: multiple files or non-obvious constraints, with meaningful validation or iteration
- `high`: cross-cutting change, strong constraints, or repeated human correction and debugging

## Commit Splitting

- Split unrelated changes into separate commits.
- Split large changes when the title or body becomes hard to explain cleanly.
- Keep documentation-only changes separate when they are independent.
- If a user-visible behavior change and its required doc update are part of one logical change, they may stay in the same commit.

## Breaking Changes

Use breaking-change markers only when the repo behavior or documented workflow changes incompatibly.
Use either `feat(scope)!: ...` in the title or a `BREAKING CHANGE:` footer in the body.

Examples:

```text
feat(api)!: rename webhook event fields
```

```text
feat: change plugin bootstrap flow

BREAKING CHANGE: plugin instances now require an explicit project ID.
```

## Repo-Specific Rules

- Match the current repo history, which already uses `feat:`, `docs:`, and similar prefixes.
- Prefer `docs: ...` for repository documentation changes.
- Only add a scope when it clarifies the owning area, for example `docs(workspaces): ...`, `docs(diagnostics): ...`, or `docs(readme): ...`.
- For mixed documentation work across multiple topic docs, prefer plain `docs: ...` unless one topic is clearly primary.
- Do not run Git commands that can contend on the index lock in parallel; stage, inspect, and commit in sequence.
- Before committing runtime changes, confirm required sync and validation steps in [`daily-workflow.md`](./daily-workflow.md).
- Preview the full commit message and get human confirmation before running `git commit`.
- Use [`scripts/dev/commit-with-ai-context.sh`](../scripts/dev/commit-with-ai-context.sh) when the commit should include AI collaboration metadata.
- For agent-driven commits that need separate human confirmation before a privileged `git commit`, first run `scripts/dev/commit-with-ai-context.sh --print-only --write-message-file auto`. The script prints the reusable message file path; after confirmation run `git commit -F <that-path>`.
