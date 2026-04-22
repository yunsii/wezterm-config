---
name: automation
scope: user
triggers:
  - choose between doc / script / hook / skill / plugin
  - implement over instruct decisions
  - recurring behavior placement
tags: [automation, hooks, skills, placement]
---

# Automation

## When To Read

When deciding whether a rule belongs in documentation, a script, a hook, a skill, or a plugin.

## When Not To Read

When the task is a one-off action that will not recur, or when the rule already lives in a stable layer and only needs to be applied — not relocated.

## Default

- [automation-01] If a behavior must happen every time, do not rely on prompt memory alone.
- [automation-02] Prefer implementation over instruction when consistency matters.

## Place Rules By Strength

Use documentation for:

- [automation-03] stable decision rules
- [automation-04] routing
- [automation-05] conceptual boundaries
- [automation-06] non-deterministic judgment guidance

Use scripts for:

- [automation-07] repeatable command sequences
- [automation-08] environment setup
- [automation-09] validation routines
- [automation-10] maintenance tasks

Use hooks for:

- [automation-11] deterministic enforcement
- [automation-12] preconditions
- [automation-13] automatic formatting
- [automation-14] file protection
- [automation-15] feedback loops around tool use

Use skills or plugins for:

- [automation-16] reusable multi-step workflows
- [automation-17] tool orchestration
- [automation-18] shared operational capabilities
- [automation-19] environment-aware automation

## Promote When

Ask:

- [automation-20] Must it always happen?
- [automation-21] Can it be checked automatically?
- [automation-22] Does it involve multiple steps?
- [automation-23] Is it reused across repositories or tasks?

[automation-24] If the answer is yes, it likely belongs below the doc layer.

## Safety

[automation-25] Automation should be explicit, reviewable, and bounded.

Prefer:

- [automation-26] clear inputs and outputs
- [automation-27] visible failure modes
- [automation-28] narrow scope
- [automation-29] dry-run or preview paths when practical

[automation-30] Avoid invisible automation that surprises the operator.
