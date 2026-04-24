---
name: documentation
scope: user
triggers:
  - creating agent-facing docs
  - splitting or revising docs
  - doc layering decisions
tags: [documentation, layering, progressive-disclosure]
---

# Documentation

## When To Read

When creating, splitting, or revising agent-facing documentation.

## When Not To Read

When editing code without touching its docs, or when only fixing typos / small wording inside an existing doc that already follows the layering rules.

## Default

- [documentation-01] Documentation should reduce decision cost, not become a second codebase.
- [documentation-02] Keep it layered, sparse, and easy to navigate.

## Layering

Use this structure:

- [documentation-03] entrypoint docs for hard rules and routing
- [documentation-04] topic docs for detailed domain guidance
- [documentation-05] local docs for environment- or project-specific constraints
- [documentation-06] reference docs for deep background only when necessary

[documentation-07] Do not put everything in the entrypoint.

## Progressive Disclosure

[documentation-08] Load the minimum context needed for the current task.

Start with:

- [documentation-09] the main entrypoint
- [documentation-10] one matching topic file

Load more only when:

- [documentation-11] the current doc points to it
- [documentation-12] the task crosses boundaries
- [documentation-13] proceeding without it would be risky

## Write

Good documentation is:

- [documentation-14] specific
- [documentation-15] stable
- [documentation-16] actionable
- [documentation-17] close to the decision point
- [documentation-18] easy to skim

Each topic file should ideally answer:

- [documentation-19] when to read it
- [documentation-20] what rules apply
- [documentation-21] what to prefer
- [documentation-22] what to avoid
- [documentation-23] how to validate

## Avoid

- [documentation-24] long narrative history
- [documentation-25] vague slogans
- [documentation-26] tool trivia that changes often
- [documentation-27] duplicated rules across many files
- [documentation-28] instructions that should be automation instead

## Maintenance

- [documentation-29] When a file grows too broad, split by decision domain, not by audience.
- [documentation-30] Keep one source of truth for each rule.
- [documentation-31] Other files should route to it, not restate it.
- [documentation-32] When a change alters behavior, interfaces, or workflows that an existing doc describes, update that doc in the same edit.
