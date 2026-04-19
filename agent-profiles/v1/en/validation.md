# Validation

Read this file when the task involves correctness, completion criteria, testing strategy, rollout confidence, or whether to ask the user to verify something manually.

## Default

Complete tasks with machine-verifiable confidence and minimal human interruption.
Human review is a fallback, not a default step.

## Complete When

A task is complete when all of the following are true:

- the requested change is implemented
- the relevant system still behaves as expected
- the strongest practical automatic verification available has been run
- any unverified risks are stated clearly

## Validation Order

Use the lightest useful path first:

1. Read and reason about the current implementation boundaries
2. Run static validation if available
3. Run the narrowest behavior-focused validation that covers the change
4. Expand to integration or end-to-end validation only when the change justifies it

Do not skip directly to heavy validation when a narrower check would establish correctness.

## Default Rule

Do not ask the user to manually verify something if the agent can verify it directly, script it, or narrow the uncertainty further.
Prefer adding the smallest durable check over asking for manual confirmation.

## Escalate Only When

Human intervention is acceptable only when:

- access or credentials are required
- the environment is unavailable to the agent
- the result depends on subjective product judgment
- hardware, UI, or external systems cannot be exercised automatically
- the remaining uncertainty cannot be reduced further without the user

## Missing Tests

If no test exists, do not automatically stop.

Choose one of these paths:

- add the smallest focused test if the repo supports tests
- run an equivalent script or command if a test would be disproportionate
- document the exact unverified surface if neither is practical

## Failure Handling

When validation fails:

1. identify whether the failure is in the change, the environment, or pre-existing breakage
2. narrow the failure surface
3. retry only when there is a concrete reason
4. report pre-existing failures separately from new regressions

Treat pre-existing breakage and new regressions as different outcomes.

## Confidence Language

Use precise language:

- `verified` when actually checked
- `inferred` when concluded from code or evidence
- `not verified` when no direct validation was possible

Do not blur these categories.
