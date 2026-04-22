---
name: validation
scope: user
triggers:
  - completion criteria
  - testing strategy
  - manual verification threshold
  - rollout confidence
  - failure handling
tags: [quality, testing, escalation, evidence]
---

# Validation

## When To Read

When the task involves correctness, completion criteria, testing strategy, rollout confidence, or whether to ask the user to verify something manually.

## When Not To Read

When the change has no observable behavior surface and no validation decision is in scope. The one-liner in AGENTS.md is enough for those cases.

## Default

Complete tasks with machine-verifiable confidence and minimal human interruption.
Human review is a fallback, not a default step.

## Complete When

A task is complete when all of the following are true:

- [validation-01] the requested change is implemented
- [validation-02] the relevant system still behaves as expected
- [validation-03] the strongest practical automatic verification available has been run
- [validation-04] any unverified risks are stated clearly

## Validation Order

Use the lightest useful path first:

- [validation-05] Read and reason about the current implementation boundaries
- [validation-06] Run static validation if available
- [validation-07] Run the narrowest behavior-focused validation that covers the change
- [validation-08] Expand to integration or end-to-end validation only when the change justifies it

[validation-09] Do not skip directly to heavy validation when a narrower check would establish correctness.

## Default Rule

- [validation-10] Do not ask the user to manually verify something if the agent can verify it directly, script it, or narrow the uncertainty further.
- [validation-11] Prefer adding the smallest durable check over asking for manual confirmation.

## Escalate Only When

Human intervention is acceptable only when:

- [validation-12] access or credentials are required
- [validation-13] the environment is unavailable to the agent
- [validation-14] the result depends on subjective product judgment
- [validation-15] hardware, UI, or external systems cannot be exercised automatically
- [validation-16] the remaining uncertainty cannot be reduced further without the user

## Missing Tests

If no test exists, do not automatically stop. Choose one of these paths:

- [validation-17] add the smallest focused test if the repo supports tests
- [validation-18] run an equivalent script or command if a test would be disproportionate
- [validation-19] document the exact unverified surface if neither is practical

## Failure Handling

When validation fails:

- [validation-20] identify whether the failure is in the change, the environment, or pre-existing breakage
- [validation-21] narrow the failure surface
- [validation-22] retry only when there is a concrete reason
- [validation-23] report pre-existing failures separately from new regressions

[validation-24] Treat pre-existing breakage and new regressions as different outcomes.

## Confidence Language

Use precise language:

- [validation-25] `verified` when actually checked
- [validation-26] `inferred` when concluded from code or evidence
- [validation-27] `not verified` when no direct validation was possible

[validation-28] Do not blur these categories.

## Examples

Good — applies [validation-07] and [validation-10]: narrow automated check, no human in the loop, precise confidence language.

```
$ pytest tests/test_cache.py::test_eviction_under_pressure -q
.                                                                  [100%]
1 passed in 0.42s
```

> Verified the regression with one focused test (`test_eviction_under_pressure`). Ran `tsc --noEmit` as static check. No remaining unverified surface.

Bad — violates [validation-10]: delegates reducible uncertainty back to the user.

```
I pushed the fix. Could you run the app and confirm the cache eviction
works under load? Let me know if anything looks off.
```

The agent could have written a targeted test or script; asking the user is a fallback, not a first move.
