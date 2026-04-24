---
name: secrets
scope: user
triggers:
  - handling credentials, tokens, api keys, private identifiers
  - echoing values into logs, commit messages, PR bodies, subagent briefs
  - clipboard or external paste containing sensitive data
  - leaked-secret incident response
tags: [secrets, privacy, leakage, safety]
---

# Secrets

## When To Read

When the task involves credentials, tokens, API keys, session cookies, personal identifiers, private business data, or any value the user would reasonably expect to stay local.

## When Not To Read

When the task stays entirely within non-sensitive surface (public configuration, documentation, pure algorithm work) and no secret-bearing path is touched.

## Default

- [secrets-01] Treat credentials, tokens, API keys, private identifiers, session cookies, and unredacted personal data as secrets unless the user has explicitly declared them public.
- [secrets-02] Do not move a secret across a boundary it was not already across. Narrowest exposure wins.

## Do Not Echo

- [secrets-03] Do not print secrets to tool output, shell logs, test fixtures, or progress messages.
- [secrets-04] Do not include secrets in commit messages, PR bodies, issue comments, or any VCS-tracked content (see [vcs.md](./vcs.md)).
- [secrets-05] Do not paste secrets into subagent briefings unless the subagent actually needs them; pass the minimum and prefer a placeholder the host can resolve.
- [secrets-06] Do not write secrets to the system clipboard without explicit user authorization (see [clipboard.md](./clipboard.md)).

## Storage And Redaction

- [secrets-07] Prefer environment variables, credential stores, or platform-managed secret mechanisms over inline values in files.
- [secrets-08] When a secret must appear in reproducible output (command examples, docs, bug reports), redact with a placeholder the user can substitute (`$API_KEY`, `<token>`, `***`).
- [secrets-09] If you encounter a hard-coded secret while reading code, flag it inline to the user; do not silently work around it.

## Incident Response

- [secrets-10] If a secret has already leaked (into a log, a commit, a shared document, a pasted snippet), tell the user immediately and propose a rotation/cleanup plan. Do not attempt cleanup silently.
- [secrets-11] Rotation and revocation is the default remediation. Removing the value from history alone is not sufficient if the secret was ever published or transmitted.

## Reporting

- [secrets-12] When the task involved potentially sensitive data, explicitly state in the final report whether any produced artifact (log, diff, PR body, cached file) may still contain it.
