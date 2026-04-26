#!/usr/bin/env bash
# Build the static `picker` binary used by tmux-attention-menu.sh (and,
# eventually, tmux-worktree-menu.sh) inside the popup pty.
#
# Build flags: CGO_ENABLED=0 + GOOS=linux for a fully static ELF (no
# libc / glibc dependency). `-ldflags='-s -w'` strips debug info so the
# binary is ~2MB instead of ~6MB. The result lives at
# native/picker/bin/picker and is gitignored — sync-runtime.sh
# regenerates it on every sync, the same way the tmux chord bindings
# are regenerated.
#
# Skips silently with a one-line note when `go` is not in PATH, so
# machines without Go installed still complete the sync (and fall back
# to the bash picker on Alt+/).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_path="$script_dir/bin/picker"

# Resolve `go` from PATH first, then fall back to common manual-install
# locations. sync-runtime.sh runs in a non-interactive shell that may not
# have inherited the user's PATH additions for ~/.local/go/bin etc.
go_bin=''
if command -v go >/dev/null 2>&1; then
  go_bin="$(command -v go)"
elif [[ -x "$HOME/.local/go/bin/go" ]]; then
  go_bin="$HOME/.local/go/bin/go"
elif [[ -x /usr/local/go/bin/go ]]; then
  go_bin=/usr/local/go/bin/go
fi

if [[ -z "$go_bin" ]]; then
  printf 'build-picker: skipped (go not found in PATH or ~/.local/go/bin or /usr/local/go/bin); attention picker will use bash fallback\n'
  exit 0
fi

mkdir -p "$script_dir/bin"
(
  cd "$script_dir"
  CGO_ENABLED=0 GOOS=linux "$go_bin" build -trimpath -ldflags='-s -w' -o "$out_path" .
)
printf 'build-picker: wrote %s (%s) using %s\n' "$out_path" "$(stat -c '%s bytes' "$out_path" 2>/dev/null || echo 'unknown size')" "$go_bin"
