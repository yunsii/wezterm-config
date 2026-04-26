# Codex CLI Setup Notes

Operator-facing setup notes for `~/.codex/config.toml`. Codex's permission
model is sandbox + approval policy, not a Claude-style allowlist — these
are knobs you tune once, not patterns an agent proposes per call.

This file is a checklist, not a normative profile. The agent-facing rules
in [../en/permissions.md](../en/permissions.md) are host-agnostic and
apply equally to a Codex session, but Codex itself does not consume the
rules in [../en/permissions-claude.md](../en/permissions-claude.md).

## Tuning Knobs (Ranked By ROI)

### 1. `approval_policy` × `sandbox_mode` default

The biggest lever. Codex defaults to `untrusted` × `read-only`, which
prompts on essentially everything. Two practical bundles:

```toml
# Default daily driver — agent can write inside cwd, asks before stepping
# outside or running anything dangerous.
approval_policy = "on-request"
sandbox_mode    = "workspace-write"
```

```toml
# "Yolo" sessions — equivalent to `codex --full-auto`. Prompts only on
# sandbox failures, not on agent-initiated escalations. Trades the
# `[platform-actions-41]` "shift-to-side-effect must be declared" semantics
# for fewer prompts.
approval_policy = "on-failure"
sandbox_mode    = "workspace-write"
```

### 2. `[profiles.X]` presets for different work modes

Switch with `codex --profile <name>` instead of editing config per task.

```toml
[profiles.research]
approval_policy = "never"
sandbox_mode    = "read-only"
[profiles.research.sandbox_workspace_write]
network_access = false

[profiles.dev]
approval_policy = "on-request"
sandbox_mode    = "workspace-write"
[profiles.dev.sandbox_workspace_write]
network_access = true

[profiles.deploy]
approval_policy = "on-request"
sandbox_mode    = "danger-full-access"
```

`research` for browsing-only sessions, `dev` for normal work, `deploy`
for explicit elevation moments. Default to `dev`.

### 3. `writable_roots` for cross-fs work

This repo's runtime sync writes paths outside the WSL home (Windows-side
runtime, host helper state, machine cache). Without these in
`writable_roots`, every sync invocation re-prompts:

```toml
[sandbox_workspace_write]
writable_roots = [
  "~/.wezterm-x",
  "~/.cache/wezterm-runtime",
  "/mnt/c/Users/Yuns/AppData/Local/wezterm-runtime",
  "/mnt/c/Users/Yuns/.wezterm-x",
]
network_access = true
```

Adjust per machine — these paths are user-specific. Source of truth for
the runtime path layout is
[`scripts/runtime/windows-runtime-paths-lib.sh`](../../../scripts/runtime/windows-runtime-paths-lib.sh).

### 4. `[shell_environment_policy]` to limit token surface

Aligns with [../en/secrets.md](../en/secrets.md): keep secret-shaped
env vars out of agent context.

```toml
[shell_environment_policy]
inherit = "core"
exclude = [
  "*_TOKEN", "*_KEY", "*_SECRET",
  "GH_TOKEN", "GITHUB_TOKEN",
  "ANTHROPIC_*", "OPENAI_API_KEY",
]
```

`inherit = "core"` means only PATH / HOME / USER / etc. flow through;
anything else must be explicitly whitelisted via `set` or `include`.

### 5. `[mcp_servers.*]` to mirror Claude's MCP capabilities

If Claude Code uses chrome-devtools / deepwiki / context7 via MCP, the
same servers can be reused under Codex. Capability parity, fewer
context-switch losses:

```toml
[mcp_servers.deepwiki]
command = "deepwiki-mcp-cli"
args    = ["serve"]

[mcp_servers.context7]
command = "..."  # mirror your ~/.claude/ MCP entries
```

### 6. `notify` hook → desktop / Feishu

Pipe approval-request events to the same notification path the rest of
this repo uses (`scripts/runtime/agent-clipboard.sh`,
`feishu-notify` skill, etc.). Keeps cross-host signal consistent.

```toml
notify = ["bash", "/home/yuns/github/wezterm-config/scripts/codex-hooks/notify.sh"]
```

The notify script does not exist yet — write it when this knob is
actually wanted.

### 7. `~/.codex/prompts/` for saved prompts

Filesystem-backed equivalent of slash commands. Drop a `.md` per prompt;
recall in a session via Codex's `/` menu. Common candidates from this
repo: "sync runtime", "reload tmux", "render hotkey report".

### 8. `disable_response_storage = true` (optional, compliance)

Set when conversations should not persist on the provider's servers.
Independent of permission policy; listed here for completeness.

## What This File Is Not

- **Not** a Codex-side equivalent of `permissions-claude.md`. Codex has
  no per-pattern allowlist, so there is no agent-facing "decide whether
  to promote a pattern" loop to specify.
- **Not** automatically loaded by any agent. This is operator
  documentation for setting up `~/.codex/config.toml` once.
- **Not** machine-portable verbatim — `writable_roots` and
  `notify` paths are user-specific.

## Verification

After editing `~/.codex/config.toml`:

```bash
codex --help                    # confirms config parses
codex --profile research        # smoke-test the named profile loads
```

If a profile fails to load, Codex usually surfaces the parse error
inline rather than silently falling back.
