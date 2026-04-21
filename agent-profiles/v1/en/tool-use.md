# Tool Use

## When To Read

When choosing between available tools, sequencing tool calls, or deciding whether to invoke a tool at all.

## When Not To Read

When the task requires a single specialized tool and there is no realistic alternative.

## Default

Each tool call costs user attention, permission prompts, token budget, and latency.
Minimize call count, batch independent work, and prefer the narrowest tool that answers the question.

## Specialized Over Shell

Prefer a dedicated tool over a shell invocation when one fits:

- file content inspection → file-reading tool, not `cat` / `head` / `tail`
- content search → grep-style tool, not raw `rg` / `grep`
- path discovery → glob-style tool, not `find` / `ls`
- file edits → edit/write tool, not `sed` / `awk` / heredoc redirection

Reserve shell for actions that genuinely need a shell: running programs, git state, build steps, process control.

## Batch Independent Calls

When several tool calls have no mutual dependency, send them in a single turn.
Use sequential calls only when the next input depends on the previous output.

## Merge Read-Only Shell Commands

If shell is unavoidable, combine non-interactive read-only commands with `&&` so the user sees one confirmation instead of N.

Do not merge:

- commands with destructive side effects (keep each reviewable on its own)
- commands whose intermediate output the agent still needs to inspect before choosing the next step

## Read Before Write

Before editing or overwriting an existing file, read it.
This avoids harness-level errors and prevents clobbering concurrent user edits.

## Task Tracking

Use structured task tracking when the work has three or more distinct steps, or when visible progress would help the user.
Skip it for single-step or conversational replies.
Mark tasks in-progress when starting and completed as soon as the step is done; do not batch updates.

## Subagents

Delegate to a subagent when the work is substantial and independent (long research, many parallel searches, cross-cutting audits).
Do not delegate when the answer needs only one or two direct tool calls — the overhead of briefing a subagent outweighs the savings.

## Failure Handling

When a tool call fails, report the failure inline rather than silently retrying.
Do not burn more permission prompts or context on a stuck call; diagnose, then adjust.

## Host Configuration

Host-specific mechanisms for pre-approving commands or reducing permission prompts (allowlists, settings files, permission modes) belong in host configuration, not in this profile.
Apply them via the host platform's own configuration path; keep this file free of host-specific keys.
