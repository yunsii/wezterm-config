---
name: platform-actions
scope: user
triggers:
  - system clipboard write
  - desktop app focus or launch
  - browser or URL open
  - local notification
  - reveal file in OS shell
tags: [host-effects, platform, side-effects, safety]
---

# Platform Actions

## When To Read

When the task may trigger a host-side side effect on the user's local machine.

Examples:

- writing to the system clipboard
- focusing or launching a desktop application
- opening a browser or URL
- showing a local notification
- revealing a file in the OS shell

## When Not To Read

When the task stays entirely within the repository (file edits, code analysis, running tests in-process) and produces no host-side effect.

## Scope

- [platform-actions-01] This file defines policy, not guaranteed capability availability.
- [platform-actions-02] Whether an action is actually possible depends on the active platform, installed wrappers, and project-local integrations.

## Default

Agent actions that affect the local machine should be:

- [platform-actions-03] narrow
- [platform-actions-04] explicit
- [platform-actions-05] reversible where possible
- [platform-actions-06] directly in service of the current task

[platform-actions-07] Prefer preparing the next user step over silently taking extra actions beyond it.

## Command Boundary

[platform-actions-08] Prefer a stable high-level wrapper command over raw transport details when one exists.

Use wrappers that:

- [platform-actions-09] hide platform-specific IPC details
- [platform-actions-10] expose clear inputs and outputs
- [platform-actions-11] fail visibly
- [platform-actions-12] are easy to log and verify

- [platform-actions-13] Do not couple user-level policy to a specific named pipe, binary path, or transport encoding when a stable wrapper already owns that layer.
- [platform-actions-14] If no stable wrapper or owned command boundary exists for a given action, treat that action as unavailable by default.

## Wrapper Discovery

- [platform-actions-15] Use an explicit marker file instead of guessing paths.
- [platform-actions-16] Do not infer wrappers from the current task repository, AGENTS symlinks, or unrelated environment details.

A marker file should declare:

- [platform-actions-17] which capabilities are available (e.g. clipboard, notification, app focus)
- [platform-actions-18] the absolute path to each wrapper
- [platform-actions-19] enough context to verify the wrapper is current

- [platform-actions-20] If the marker file is missing, treat host-side wrappers as unavailable.
- [platform-actions-21] If a referenced wrapper does not exist or is not executable, treat that specific capability as unavailable.
- [platform-actions-22] The concrete marker contract is environment-specific and lives in the project that ships the wrappers, not in this user-level profile.
- [platform-actions-23] The active environment's project documentation is the source of truth for the marker path and the keys it exposes.

## Clipboard

[platform-actions-24] Agent may proactively write to the system clipboard when the output is clearly intended for immediate user paste.

Typical allowed cases:

- [platform-actions-25] a short shell command
- [platform-actions-26] a commit message
- [platform-actions-27] a short code snippet
- [platform-actions-28] a URL
- [platform-actions-29] other token-free text the user is expected to paste elsewhere

Default limits:

- [platform-actions-30] do not proactively read the clipboard unless the user explicitly asks
- [platform-actions-31] do not simulate paste or depend on window focus
- [platform-actions-32] do not keep monitoring or syncing clipboard state in the background

Ask before writing:

- [platform-actions-33] secrets or credentials
- [platform-actions-34] destructive commands
- [platform-actions-35] long multi-line scripts
- [platform-actions-36] unusually large payloads
- [platform-actions-37] content that may overwrite something the user is likely to still need

[platform-actions-38] After writing to the clipboard, explicitly tell the user that the clipboard was updated and summarize what was written.

## Other Host-Side Actions

Agent may take other host-side actions only when all of the following are true:

- [platform-actions-39] the action is a natural continuation of the current task
- [platform-actions-40] the action is low-risk and easy to understand
- [platform-actions-41] there is a stable wrapper or well-owned command boundary
- [platform-actions-42] the user would otherwise need to perform the same mechanical step manually

[platform-actions-43] Ask before actions that are destructive, persistent, privacy-sensitive, or hard to undo.

## Reporting

When a host-side action succeeds, report:

- [platform-actions-44] what action was taken
- [platform-actions-45] what target was affected
- [platform-actions-46] whether follow-up is still needed from the user

[platform-actions-47] When it fails, report the failed action, the immediate reason if known, and whether the main task is still blocked.
