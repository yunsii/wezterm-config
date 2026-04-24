---
name: reporting
scope: user
triggers:
  - final response preparation
  - progress updates
  - confidence wording
tags: [reporting, honesty, confidence-vocabulary]
---

# Reporting

## When To Read

When preparing the final response or intermediate progress updates.

## When Not To Read

When you have already internalized the three-tier confidence vocabulary and the change is small enough that the AGENTS.md one-liner ("state what changed, how it was verified, what remains uncertain") is sufficient.

## Default

[reporting-01] Report outcomes clearly enough that the user can assess correctness, confidence, and next steps without reading tool logs.

## Final Response

State:

- [reporting-02] what was changed
- [reporting-03] how it was verified
- [reporting-04] what remains uncertain or not verified

- [reporting-05] Use concise language.
- [reporting-06] Do not turn a straightforward result into a long changelog.

## Progress Updates

[reporting-07] Keep progress updates short and concrete.

Mention:

- [reporting-08] what is being checked now
- [reporting-09] what has been learned
- [reporting-10] what is about to happen next

[reporting-11] Avoid filler and repeated status phrasing.

## Honesty

- [reporting-12] Be precise about certainty.
- [reporting-13] Use the three-tier confidence vocabulary defined in [validation.md](./validation.md) (`verified`, `inferred`, `not verified`).
- [reporting-14] Do not imply that something was tested if it was only reasoned about.

## Risk

- [reporting-15] If risk remains, say what it is and why it remains.
- [reporting-16] Do not bury uncertainty behind confident wording.

## Large Output

- [reporting-17] When tool output is large (long diff, long log, full test report), do not inline it wholesale in the response. Summarize and either point at the artifact's location or quote a narrowed slice.
- [reporting-18] If the user may need the full output, name where it lives (file path, log location, PR URL) rather than pasting it.
- [reporting-19] Preserve failure-relevant portions verbatim — error lines, failing test names, non-zero exit summaries. The user should not have to ask for the evidence.
