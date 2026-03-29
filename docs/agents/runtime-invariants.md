# Runtime Invariants

Use this doc when you are changing runtime behavior.

## Managed Startup

- Managed project tabs bootstrap through `scripts/runtime/open-project-session.sh`.
- Keep tmux session bootstrap behavior there, not duplicated in WezTerm-side lazy setup.
- Keep environment bootstrapping and tool-specific startup logic in `scripts/runtime/run-managed-command.sh`, not in `workspaces.lua`.

## Stable Behavior

- Managed launcher profiles live in `wezterm-x/lua/constants.lua` and resolve to concrete startup commands before tmux session creation.
- The tracked `codex` launcher keeps the default dark theme behavior and forces `tui.theme=github` only when `managed_cli.ui_variant` is `light`.
- The tmux layout is the stable execution layer: left pane runs the configured primary command and right pane remains a shell in the same directory.
- tmux status may render one or two lines depending on whether the WakaTime line is enabled and non-empty.
- WezTerm tab titles remain the primary cross-workspace navigation layer.

## Cross-Doc Rule

- If these behaviors change in a user-visible way, update [`../user/tmux-and-status.md`](../user/tmux-and-status.md).
