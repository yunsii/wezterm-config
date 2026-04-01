---
name: worktree-task
description: Create or reclaim a linked git task worktree under the repository parent's `.worktrees/<repo>/` folder and optionally launch it through a built-in or custom provider such as the generic tmux agent provider.
---

# Worktree Task

Use this skill when the user wants either:

- a new implementation task to start in its own linked git worktree and managed tmux agent window instead of continuing inside the current worktree
- an existing task worktree created by this skill to be reclaimed safely after the work is done

The skill-owned scripts are the source of truth for task naming, prompt-file placement, worktree creation, optional provider launch, and task reclaim.

## Launch Workflow

1. Before `launch` or `reclaim`, check whether `WEZTERM_CONFIG_REPO` is configured. If it is missing, ask the user which tracked `wezterm-config` repo or derived repo should be used, then run `worktree-task configure --repo /absolute/path` before continuing.
2. Summarize the user request into a compact task prompt that is ready to hand to a fresh agent CLI session.
3. Pick a short task title that can be slugified into a branch and worktree name.
4. Run the skill script from inside the target repository so it can create the linked worktree under the repository parent's `.worktrees/<repo>/` directory.
5. Let the selected provider open or prepare the new task target. The built-in `tmux-agent` provider reuses the current repo-family tmux session when the current pane or window layout still resolves to that repo family through live git context.
6. Report the resulting branch name, worktree path, and tmux session to the user.

Launch command:

Pipe the cleaned-up task prompt on stdin:

```bash
printf '%s' "$TASK_PROMPT" | bash {{skill_path}}/scripts/worktree-task launch --title "$TASK_TITLE"
```

Useful options:

- `--task-slug value`: override the generated slug prefix
- `--branch value`: force a branch name instead of the default `task/<slug>`
- `--base-ref value`: create the branch from a specific ref instead of the primary worktree `HEAD`
- `--provider none|tmux-agent|custom:name|/absolute/path`: choose a built-in or external provider
- `--provider-mode off|auto|required`: disable runtime launch, allow provider fallback, or require provider success
- `--workspace value`: override the tmux session namespace used by the built-in tmux provider
- `--session-name value`: force the built-in tmux provider to use a specific session name
- `--variant light|dark|auto`: choose the managed agent CLI UI variant for the built-in tmux provider
- `--no-attach`: create/select the runtime target without switching the current client

## Reclaim Workflow

1. Identify the task worktree to reclaim. If you are already inside that linked worktree, the reclaim script can infer it automatically.
2. Confirm whether the task worktree has uncommitted changes. Do not discard them silently.
3. Run the reclaim script so it asks the selected provider to clean up runtime state for that worktree, removes the linked worktree, and deletes the branch only when that branch is already merged into the primary worktree `HEAD`.
4. Report what was removed and what was kept.

Reclaim command:

```bash
bash {{skill_path}}/scripts/worktree-task reclaim
```

Useful options:

- `--task-slug value`: reclaim `.worktrees/<repo>/<slug>` from the current repo family
- `--worktree-root path`: reclaim a specific linked task worktree
- `--provider none|tmux-agent|custom:name|/absolute/path`: override the provider used for cleanup
- `--provider-mode off|auto|required`: disable runtime cleanup, allow fallback, or require provider success
- `--force`: allow reclaiming a dirty worktree and pass `-f` to `git worktree remove`
- `--keep-branch`: keep the task branch even if it is already merged

## Rules

- Prefer running this skill from the existing managed tmux agent window for the target repo. That gives the script enough context to reuse the current repo-family tmux session directly.
- `WEZTERM_CONFIG_REPO` is required. Every time you use this skill, check whether it is configured first; if it is missing, ask the user which tracked `wezterm-config` repo or derived repo to use, then save that choice with `worktree-task configure --repo /absolute/path`.
- Prefer `worktree-task configure --repo` as the stable recovery path whenever `WEZTERM_CONFIG_REPO` is missing. `launch` often reads the task prompt from stdin, so config discovery should not depend on waiting for input on that same stream.
- Keep the cleaned-up task prompt concise and action-oriented. Include acceptance criteria or constraints only when they materially affect the implementation.
- Do not ask the user to type into an interactive shell prompt. Pass the prompt through stdin or a prompt file.
- The script does not archive task prompts under the repository. Runtime launch uses a temporary prompt file only long enough for the new tmux pane to start.
- The skill is self-contained. Repo-specific behavior should come from tracked config such as `.worktree-task/config.env`, not from hard-coded relative paths into the target repository.
- Set `WEZTERM_CONFIG_REPO` when you want the installed skill to reuse a tracked `wezterm-config` repo or a derived repo as the source of shared worktree-task conventions.
- Config collection now follows the tracked `wezterm-config` repo profile first, then the user override config, then the target repo override config.
- Relative repo-managed paths such as `WT_PROVIDER_TMUX_CONFIG_FILE=tmux.conf` resolve against the configured `wezterm-config` repo, not against the target task repository.
- If the requested slug already exists, the script automatically appends a numeric suffix unless the user forced an explicit branch name.
- If you need a non-default branch base, pass `--base-ref` explicitly instead of assuming the current linked worktree branch is correct.
- Reclaim only skill-managed task worktrees under the repository parent's `.worktrees/<repo>/`; do not silently remove the primary worktree or unrelated linked worktrees.
- By default reclaim refuses to remove a dirty worktree. Require `--force` before discarding local changes.
- Delete the task branch only when it is already merged into the primary worktree `HEAD`; otherwise keep it and report that clearly.
- The built-in `tmux-agent` provider derives session reuse, existing task-window discovery, and reclaim cleanup from live git context instead of stored tmux worktree metadata.
- Configure the built-in tmux agent launcher with `WT_PROVIDER_AGENT_BOOTSTRAP`, `WT_PROVIDER_AGENT_COMMAND`, `WT_PROVIDER_AGENT_COMMAND_LIGHT`, `WT_PROVIDER_AGENT_COMMAND_DARK`, and optional `WT_PROVIDER_AGENT_PROMPT_FLAG` in `.worktree-task/config.env` or the user config override file.
- Repos that are themselves a `wezterm-config` repo, or a derived repo that carries the same conventions, should track `WEZTERM_CONFIG_REPO=.` in `.worktree-task/config.env`.
- Built-in providers currently include `none` and `tmux-agent`. External providers can be selected by absolute path or `custom:name` when discoverable through `WT_PROVIDER_SEARCH_PATHS`.

## Script

Unified entry point:

```bash
bash {{skill_path}}/scripts/worktree-task --help
```

Config command:

```bash
bash {{skill_path}}/scripts/worktree-task configure --repo /absolute/path/to/wezterm-config
```
