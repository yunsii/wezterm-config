# Runtime Invariants

Use this doc when you are changing runtime behavior.

## Managed Startup

- Managed project tabs bootstrap through `scripts/runtime/open-project-session.sh`.
- Linked task worktree windows bootstrap through the built-in tmux provider under `skills/worktree-task/scripts/providers/tmux-agent.sh`.
- The built-in task-worktree tmux provider must derive repo-family session reuse and task-window ownership from live git context instead of stored tmux worktree metadata, and it must keep the launched agent CLI configurable instead of hard-coding `codex`.
- Keep task-specific tmux session bootstrap inside the skill provider, not duplicated in WezTerm-side lazy setup.
- Keep environment bootstrapping and tool-specific startup logic in `scripts/runtime/run-managed-command.sh`, not in `workspaces.lua`.

## Stable Behavior

- Managed launcher profiles live in `wezterm-x/lua/constants.lua` and resolve to concrete startup commands before tmux session creation.
- The tracked `codex` launcher keeps the default dark theme behavior and forces `tui.theme=github` only when `managed_cli.ui_variant` is `light`.
- The tmux layout is the stable execution layer: left pane runs the configured primary command and right pane remains a shell in the same directory.
- One-shot task prompts belong only to the newly created task worktree window; they must not overwrite the repo-family session's stored default startup command.
- tmux status may render one or two lines depending on whether the WakaTime line is enabled and non-empty.
- WezTerm tab titles remain the primary cross-workspace navigation layer.

## Cross-Doc Rule

- If these behaviors change in a user-visible way, update [`../user/tmux-and-status.md`](../user/tmux-and-status.md).
