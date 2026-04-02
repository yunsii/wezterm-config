# Validation

Use this doc when you changed runtime config or need release workflow rules.

## Runtime Validation

After runtime config changes:

1. Run the `wezterm-runtime-sync` skill from the repo root. If repo-root `.sync-target` already points at a valid target, `skills/wezterm-runtime-sync/scripts/sync-runtime.sh` is enough; otherwise use `--target-home /absolute/path` after the target has been confirmed.
2. Let WezTerm auto-reload the synced config by default. Use `Ctrl+Shift+R` only to force a reload when needed; current WezTerm versions watch the loaded config file and `require`-loaded Lua modules automatically.
3. Reload tmux config or recreate tmux sessions if tmux styling or startup behavior changed.
4. Verify workspace shortcuts still match [`../user/keybindings.md`](../user/keybindings.md).
5. When task-worktree launch behavior changes, verify a new linked task worktree opens as another tmux window in the same repo-family session and that later worktree windows still fall back to the session default launcher instead of replaying the one-shot task prompt.

## Diagnostics Validation

- Keep both WezTerm and runtime diagnostics disabled by default when you are not actively debugging.
- When you add or change diagnostics, verify that enabling them produces structured lines and that disabling them returns the system to its normal quiet behavior.
- For keybinding investigations, temporarily set `diagnostics.wezterm.debug_key_events = true`, reproduce the issue, and then turn it back off.
- For runtime script investigations, use `wezterm-x/local/runtime-logging.sh` to scope logging level, file path, and categories instead of editing individual scripts.
- If your change introduces a new diagnostics category or log file, update [`../user/maintenance.md`](../user/maintenance.md).

## Doc-Only Changes

- If only documentation changed, runtime sync and reload are not required.

## Commit Rule

- Do not auto-commit or auto-push unless the user asks or the task explicitly calls for it.
- If a commit is needed, follow [`commit-guidelines.md`](./commit-guidelines.md).
