---
name: implementation
scope: user
triggers:
  - structure
  - abstractions
  - module boundaries
  - reliability
  - performance
tags: [design, architecture, complexity, change-size]
---

# Implementation

## When To Read

When choosing structure, abstractions, module boundaries, reliability patterns, or performance tradeoffs.

## When Not To Read

When the change is a localized bug fix with no design decision, or pure text/comment edits. The AGENTS.md one-liner covers those.

## Default

Prefer implementations that are understandable, observable, proportionate, and cheap to maintain.

## Organize Around Ownership

Use structures with:

- [implementation-01] a clear entrypoint
- [implementation-02] explicit boundaries
- [implementation-03] stable interfaces
- [implementation-04] limited hidden coupling
- [implementation-05] a small number of places where critical behavior lives

[implementation-06] Do not scatter one responsibility across many files without a strong reason.

## Reliability

Prefer implementations that are:

- [implementation-07] idempotent where possible
- [implementation-08] explicit about failure
- [implementation-09] easy to observe
- [implementation-10] safe to retry
- [implementation-11] safe to stop midway
- [implementation-12] easy to roll back

[implementation-13] Avoid fragile sequences with hidden assumptions.

## Maintainability

Prefer:

- [implementation-14] a small number of strong concepts
- [implementation-15] narrow interfaces
- [implementation-16] straightforward control flow
- [implementation-17] comments only where intent would otherwise be unclear

Avoid:

- [implementation-18] speculative abstraction
- [implementation-19] over-generalization
- [implementation-20] deeply implicit behavior
- [implementation-21] large rewrites without stable checkpoints

## Performance

[implementation-22] Do not optimize by default.

Optimize when there is at least one of:

- [implementation-23] a measured hotspot
- [implementation-24] repeated cost at meaningful scale
- [implementation-25] a latency-sensitive path
- [implementation-26] a resource bottleneck that materially affects user experience

[implementation-27] When optimizing, preserve clarity unless the tradeoff is clearly worth it.

## Reuse Versus Duplication

- [implementation-28] Prefer reuse of existing mechanisms when the fit is real.
- [implementation-29] Do not force reuse when it creates awkward abstractions or hidden coupling.
- [implementation-30] Short, obvious duplication is often cheaper than premature frameworking.
- [implementation-31] Repeated orchestration with stable semantics is a stronger signal to extract a helper, script, skill, or plugin.

## Change Precision

[implementation-32] Touch only what the task requires.

- [implementation-33] Read the surrounding context fully before generating or editing code.
- [implementation-34] Match existing style and patterns unless the task is explicitly to change them.
- [implementation-35] Do not refactor adjacent code, rename unrelated identifiers, or tidy up during a focused change.

## Change Size

[implementation-36] Prefer small closed-loop changes.

If a task is large, split it into steps where each step:

- [implementation-37] preserves behavior or clearly changes one thing
- [implementation-38] is independently reviewable
- [implementation-39] is independently verifiable

## Error Handling

- [implementation-40] Surface failures; do not swallow them. A silent `catch` that returns a default value hides regressions until much later.
- [implementation-41] Fail loud at the failure boundary. Raise a clear error and let the caller decide whether to recover.
- [implementation-42] Match the error surface to the layer: internal invariants raise exceptions, user-facing boundaries return structured errors, external system calls return status codes or typed results.
- [implementation-43] Recover only when there is a concrete recovery plan. A bare `except: pass` / `catch (e) {}` is never a recovery plan.
- [implementation-44] Preserve the original cause when re-raising or wrapping. The stack trace and error chain are evidence, not noise.
