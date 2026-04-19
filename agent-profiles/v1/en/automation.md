# Automation

Read this file when deciding whether a rule belongs in documentation, a script, a hook, a skill, or a plugin.

## Default

If a behavior must happen every time, do not rely on prompt memory alone.

Prefer implementation over instruction when consistency matters.

## Place Rules By Strength

Use documentation for:

- stable decision rules
- routing
- conceptual boundaries
- non-deterministic judgment guidance

Use scripts for:

- repeatable command sequences
- environment setup
- validation routines
- maintenance tasks

Use hooks for:

- deterministic enforcement
- preconditions
- automatic formatting
- file protection
- feedback loops around tool use

Use skills or plugins for:

- reusable multi-step workflows
- tool orchestration
- shared operational capabilities
- environment-aware automation

## Promote When

Ask:

- Must it always happen?
- Can it be checked automatically?
- Does it involve multiple steps?
- Is it reused across repositories or tasks?

If the answer is yes, it likely belongs below the doc layer.

## Safety

Automation should be explicit, reviewable, and bounded.

Prefer:

- clear inputs and outputs
- visible failure modes
- narrow scope
- dry-run or preview paths when practical

Avoid invisible automation that surprises the operator.
