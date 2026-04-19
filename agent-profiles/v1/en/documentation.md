# Documentation

Read this file when creating, splitting, or revising agent-facing documentation.

## Default

Documentation should reduce decision cost, not become a second codebase.
Keep it layered, sparse, and easy to navigate.

## Layering

Use this structure:

- entrypoint docs for hard rules and routing
- topic docs for detailed domain guidance
- local docs for environment- or project-specific constraints
- reference docs for deep background only when necessary

Do not put everything in the entrypoint.

## Progressive Disclosure

Load the minimum context needed for the current task.

Start with:
- the main entrypoint
- one matching topic file

Load more only when:
- the current doc points to it
- the task crosses boundaries
- proceeding without it would be risky

## Write

Good documentation is:

- specific
- stable
- actionable
- close to the decision point
- easy to skim

Each topic file should ideally answer:

- when to read it
- what rules apply
- what to prefer
- what to avoid
- how to validate

## Avoid

Avoid:

- long narrative history
- vague slogans
- tool trivia that changes often
- duplicated rules across many files
- instructions that should be automation instead

## Maintenance

When a file grows too broad, split by decision domain, not by audience.
Keep one source of truth for each rule.
Other files should route to it, not restate it.
