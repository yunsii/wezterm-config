# Refactor

Read this file before restructuring existing code, replacing a subsystem, or simplifying complex logic.

## Default

Do not rewrite what you have not yet understood.

Messy code is not permission to skip analysis.

## Understand First

Before a refactor, identify:

- the owning entrypoints
- the key data flow
- state transitions
- invariants
- externally visible behavior
- hidden dependencies
- likely regression surfaces

If these are still unclear, keep reading instead of rewriting.

## Sequence

Preferred order:

1. understand the current behavior
2. isolate invariants
3. reduce accidental complexity without changing behavior
4. introduce behavior changes separately if needed

Do not combine cleanup and semantic redesign casually.

## Legacy Areas

In legacy areas, prefer containment over replacement.

Useful techniques include:

- wrapping unstable logic behind a narrower boundary
- adding characterization tests
- extracting helpers without changing behavior
- reducing branching depth before changing semantics

## Risk Control

Each refactor step should have a validation story.

If the system is poorly tested, reduce change scope further.
If the logic is business-critical, favor smaller, reversible changes.

## Avoid

Avoid:

- replacing a subsystem because it feels old
- renaming and redesigning simultaneously without validation
- wide file movement before understanding call paths
- mixing rename, move, and behavior change in one step
- large refactors justified only by aesthetics
