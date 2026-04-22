---
name: refactor
scope: user
triggers:
  - restructuring existing code
  - replacing a subsystem
  - simplifying complex logic
tags: [refactor, risk, containment, sequence]
---

# Refactor

## When To Read

Before restructuring existing code, replacing a subsystem, or simplifying complex logic.

## When Not To Read

When adding a new feature without touching existing structure, or when fixing a bug without restructuring its surroundings.

## Default

- [refactor-01] Do not rewrite what you have not yet understood.
- [refactor-02] Messy code is not permission to skip analysis.

## Understand First

Before a refactor, identify:

- [refactor-03] the owning entrypoints
- [refactor-04] the key data flow
- [refactor-05] state transitions
- [refactor-06] invariants
- [refactor-07] externally visible behavior
- [refactor-08] hidden dependencies
- [refactor-09] likely regression surfaces

[refactor-10] If these are still unclear, keep reading instead of rewriting.

## Sequence

Preferred order:

- [refactor-11] understand the current behavior
- [refactor-12] isolate invariants
- [refactor-13] reduce accidental complexity without changing behavior
- [refactor-14] introduce behavior changes separately if needed

[refactor-15] Do not combine cleanup and semantic redesign casually.

## Legacy Areas

[refactor-16] In legacy areas, prefer containment over replacement.

Useful techniques include:

- [refactor-17] wrapping unstable logic behind a narrower boundary
- [refactor-18] adding characterization tests
- [refactor-19] extracting helpers without changing behavior
- [refactor-20] reducing branching depth before changing semantics

## Risk Control

- [refactor-21] Each refactor step should have a validation story.
- [refactor-22] If the system is poorly tested, reduce change scope further.
- [refactor-23] If the logic is business-critical, favor smaller, reversible changes.

## Avoid

- [refactor-24] replacing a subsystem because it feels old
- [refactor-25] renaming and redesigning simultaneously without validation
- [refactor-26] wide file movement before understanding call paths
- [refactor-27] mixing rename, move, and behavior change in one step
- [refactor-28] large refactors justified only by aesthetics
