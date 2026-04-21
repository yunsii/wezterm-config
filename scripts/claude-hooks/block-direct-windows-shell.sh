#!/usr/bin/env bash
# Claude Code PreToolUse hook for wezterm-config.
#
# Enforces the repo CLAUDE.md "Hard Rules" and docs/setup.md
# "Windows Script Execution" section: from WSL, never invoke cmd.exe or
# powershell.exe directly, except for ASCII-safe env-variable discovery
# via `cmd.exe /c "echo %VAR%"`. All other Windows shell work must go
# through the UTF-8 wrappers in scripts/runtime/windows-shell-lib.sh.
#
# Exit 2 blocks the Bash tool call and surfaces stderr to the model. On any
# parsing anomaly (missing jq, malformed stdin) the hook fails open so it
# never blocks unrelated Bash calls — enforcement is best-effort, not a
# security boundary.

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

if [[ -z "$cmd" ]]; then
  exit 0
fi

if ! grep -qE 'cmd\.exe|powershell\.exe' <<<"$cmd"; then
  exit 0
fi

# Strip allowed env-discovery patterns: `cmd.exe /c "echo %VAR%"`
# (double, single, or no quotes; optional `2>/dev/null` / `| ...` follow fine
# because we only strip the invocation itself, not what surrounds it).
sanitized="$(printf '%s' "$cmd" | sed -E \
  -e 's#cmd\.exe[[:space:]]+/c[[:space:]]+"echo[[:space:]]+%[A-Za-z_][A-Za-z0-9_]*%"##g' \
  -e "s#cmd\\.exe[[:space:]]+/c[[:space:]]+'echo[[:space:]]+%[A-Za-z_][A-Za-z0-9_]*%'##g" \
  -e 's#cmd\.exe[[:space:]]+/c[[:space:]]+echo[[:space:]]+%[A-Za-z_][A-Za-z0-9_]*%##g')"

if ! grep -qE 'cmd\.exe|powershell\.exe' <<<"$sanitized"; then
  exit 0
fi

cat >&2 <<'EOF'
Blocked: direct cmd.exe / powershell.exe invocation from WSL in wezterm-config.

Use the UTF-8 wrappers from scripts/runtime/windows-shell-lib.sh:

  source scripts/runtime/windows-shell-lib.sh
  windows_run_powershell_command_utf8 '<PowerShell command>'
  # or for .ps1 files:
  windows_run_powershell_script_utf8 /path/to/script.ps1 -Arg value

Only narrow exception: cmd.exe /c "echo %VAR%" for ASCII-safe env discovery.

Why: Chinese Windows returns GBK-encoded output through raw cmd.exe /
powershell.exe, producing mojibake in the tool output. The UTF-8 wrappers
set codepage 65001 before executing, so output stays readable.

See docs/setup.md "Windows Script Execution" and CLAUDE.md "Hard Rules".
EOF
exit 2
