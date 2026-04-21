# Implementation

## When To Read

When choosing structure, abstractions, module boundaries, reliability patterns, or performance tradeoffs.

## When Not To Read

When the change is a localized bug fix with no design decision, or pure text/comment edits. The AGENTS.md one-liner covers those.

## Default

Prefer implementations that are understandable, observable, proportionate, and cheap to maintain.

## Organize Around Ownership

Use structures with:

- a clear entrypoint
- explicit boundaries
- stable interfaces
- limited hidden coupling
- a small number of places where critical behavior lives

Do not scatter one responsibility across many files without a strong reason.

## Reliability

Prefer implementations that are:

- idempotent where possible
- explicit about failure
- easy to observe
- safe to retry
- safe to stop midway
- easy to roll back

Avoid fragile sequences with hidden assumptions.

## Maintainability

Prefer:

- a small number of strong concepts
- narrow interfaces
- straightforward control flow
- comments only where intent would otherwise be unclear

Avoid:

- speculative abstraction
- over-generalization
- deeply implicit behavior
- large rewrites without stable checkpoints

## Performance

Do not optimize by default.

Optimize when there is at least one of:

- a measured hotspot
- repeated cost at meaningful scale
- a latency-sensitive path
- a resource bottleneck that materially affects user experience

When optimizing, preserve clarity unless the tradeoff is clearly worth it.

## Reuse Versus Duplication

Prefer reuse of existing mechanisms when the fit is real.
Do not force reuse when it creates awkward abstractions or hidden coupling.

Short, obvious duplication is often cheaper than premature frameworking.
Repeated orchestration with stable semantics is a stronger signal to extract a helper, script, skill, or plugin.

## Change Precision

Touch only what the task requires.

- Read the surrounding context fully before generating or editing code.
- Match existing style and patterns unless the task is explicitly to change them.
- Do not refactor adjacent code, rename unrelated identifiers, or tidy up during a focused change.

## Change Size

Prefer small closed-loop changes.

If a task is large, split it into steps where each step:

- preserves behavior or clearly changes one thing
- is independently reviewable
- is independently verifiable
