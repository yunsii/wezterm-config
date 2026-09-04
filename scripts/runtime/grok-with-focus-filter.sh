#!/usr/bin/env bash
# Launch Grok Build with terminal FocusIn/FocusOut CSI stripped.
#
# Why: Grok full-repaints on FocusGained; under tmux+WezTerm that shows as a
# whole-transcript flash when Alt+o / pane click switches focus. Session-wide
# `focus-events off` stops the flash but also starves Vim/Claude/attention.
# This wrapper keeps focus-events on for the session and only blinds Grok.
#
# Install (required — grok's own ~/.zshrc snippet prepends ~/.grok/bin ahead of
# ~/.local/bin, so a ~/.local/bin/grok symlink alone is skipped):
#   scripts/runtime/grok-with-focus-filter.sh --install
# That keeps the real binary at ~/.grok/bin/grok.real and points
# ~/.grok/bin/grok (+ ~/.local/bin/grok) at this script. Re-run after every
# `grok update` (the updater overwrites ~/.grok/bin/grok).
#
# Health check (non-mutating; agents/docs triage first):
#   scripts/runtime/grok-with-focus-filter.sh --check
#
# Opt out for one run: GROK_FOCUS_FILTER=0 grok ...
# Point at a specific binary: GROK_REAL_BIN=/path/to/grok grok ...
# Docs: docs/tmux-ui.md#grok-build-in-tmux (Standing ops after grok update).
set -euo pipefail

# When installed as ~/.grok/bin/grok or ~/.local/bin/grok → this file,
# BASH_SOURCE is the symlink path; resolve to scripts/runtime/ first.
_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
FILTER_PY="$SCRIPT_DIR/grok-focus-filter.py"
REPO_WRAPPER="$SCRIPT_DIR/grok-with-focus-filter.sh"

is_this_wrapper() {
  local path="$1"
  local resolved
  resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  [[ "$resolved" == "$_SELF" || "$resolved" == "$REPO_WRAPPER" ]]
}

resolve_real_bin() {
  if [[ -n "${GROK_REAL_BIN:-}" && -x "${GROK_REAL_BIN}" ]]; then
    if is_this_wrapper "${GROK_REAL_BIN}"; then
      printf 'grok-with-focus-filter: GROK_REAL_BIN points at the wrapper\n' >&2
      exit 127
    fi
    printf '%s\n' "$GROK_REAL_BIN"
    return
  fi
  local candidate
  # Prefer the parked real binary; never pick ~/.grok/bin/grok when it is us.
  for candidate in \
    "${HOME}/.grok/bin/grok.real" \
    "${HOME}/.grok/downloads/grok-1.0.5-linux-x86_64" \
    "${HOME}/.grok/downloads/grok-1.0.7-linux-x86_64"; do
    if [[ -x "$candidate" ]] && ! is_this_wrapper "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  # Newest matching download artifact, if any.
  local newest=""
  if compgen -G "${HOME}/.grok/downloads/grok-*-linux-x86_64" >/dev/null 2>&1; then
    newest="$(ls -1t "${HOME}/.grok/downloads"/grok-*-linux-x86_64 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$newest" && -x "$newest" ]] && ! is_this_wrapper "$newest"; then
    printf '%s\n' "$newest"
    return
  fi
  # Last resort: PATH entries that are not this wrapper (and not a symlink to it).
  local resolved
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if is_this_wrapper "$candidate"; then
      continue
    fi
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done < <(type -aP grok 2>/dev/null || true)
  printf 'grok-with-focus-filter: cannot find a real grok binary (expected ~/.grok/bin/grok.real)\n' >&2
  exit 127
}

install_wrapper() {
  local grok_dir="${HOME}/.grok/bin"
  local target="${grok_dir}/grok"
  local real="${grok_dir}/grok.real"
  local local_link="${HOME}/.local/bin/grok"

  mkdir -p "$grok_dir" "${HOME}/.local/bin"

  if [[ -e "$target" || -L "$target" ]]; then
    if is_this_wrapper "$target"; then
      printf 'install: %s already points at the focus-filter wrapper\n' "$target"
    elif [[ -f "$target" && ! -L "$target" ]]; then
      if [[ -e "$real" ]]; then
        # Keep newer of the two as grok.real
        if [[ "$target" -nt "$real" ]]; then
          mv -f "$target" "$real"
          printf 'install: moved newer %s → %s\n' "$target" "$real"
        else
          rm -f "$target"
          printf 'install: removed stale %s (kept existing %s)\n' "$target" "$real"
        fi
      else
        mv -f "$target" "$real"
        printf 'install: moved %s → %s\n' "$target" "$real"
      fi
    else
      # Unexpected symlink (e.g. `grok update` repointed ~/.grok/bin/grok at
      # downloads/grok-*-linux-x86_64). Park / promote that artifact into
      # grok.real so the wrapper keeps the newest binary.
      local dest
      dest="$(readlink -f "$target" 2>/dev/null || true)"
      if [[ -n "$dest" && -f "$dest" ]]; then
        if [[ ! -e "$real" || "$dest" -nt "$real" ]]; then
          cp -f "$dest" "$real"
          chmod +x "$real"
          printf 'install: promoted %s → %s\n' "$dest" "$real"
        fi
      fi
      rm -f "$target"
    fi
  fi

  if [[ ! -x "$real" ]]; then
    # Seed from downloads if present.
    local seed=""
    if compgen -G "${HOME}/.grok/downloads/grok-*-linux-x86_64" >/dev/null 2>&1; then
      seed="$(ls -1t "${HOME}/.grok/downloads"/grok-*-linux-x86_64 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$seed" && -x "$seed" ]]; then
      cp -f "$seed" "$real"
      chmod +x "$real"
      printf 'install: seeded %s from %s\n' "$real" "$seed"
    else
      printf 'install: missing real binary at %s and no downloads seed\n' "$real" >&2
      exit 1
    fi
  else
    # Even when grok.real already exists, prefer a newer download artifact
    # left behind by `grok update` (common: symlink overwritten, .real stale).
    local newest=""
    if compgen -G "${HOME}/.grok/downloads/grok-*-linux-x86_64" >/dev/null 2>&1; then
      newest="$(ls -1t "${HOME}/.grok/downloads"/grok-*-linux-x86_64 2>/dev/null | head -1 || true)"
    fi
    if [[ -n "$newest" && -x "$newest" && "$newest" -nt "$real" ]]; then
      cp -f "$newest" "$real"
      chmod +x "$real"
      printf 'install: upgraded %s from newer download %s\n' "$real" "$newest"
    fi
  fi

  ln -sfn "$REPO_WRAPPER" "$target"
  ln -sfn "$REPO_WRAPPER" "$local_link"
  printf 'install: %s → %s\n' "$target" "$REPO_WRAPPER"
  printf 'install: %s → %s\n' "$local_link" "$REPO_WRAPPER"
  printf 'install: real binary %s\n' "$real"
  printf 'Re-run after every `grok update`. Exit and --resume any live Grok session.\n'
  # Smoke: resolved real must not be the wrapper.
  GROK_REAL_BIN= "$REPO_WRAPPER" --version >/dev/null
  printf 'install: smoke --version ok via wrapper\n'
}

# Non-mutating health check for docs / agents / post-update ops.
# Exit 0 when login-path first hit is the wrapper and grok.real is executable.
# Exit 1 with actionable lines otherwise (do not auto-install).
check_wrapper() {
  local target="${HOME}/.grok/bin/grok"
  local real="${HOME}/.grok/bin/grok.real"
  local local_link="${HOME}/.local/bin/grok"
  local rc=0

  if is_this_wrapper "$target"; then
    printf 'ok: %s → focus-filter wrapper\n' "$target"
  else
    printf 'FAIL: %s is not the focus-filter wrapper\n' "$target"
    if [[ -L "$target" ]]; then
      printf '  currently → %s\n' "$(readlink "$target" 2>/dev/null || true)"
    elif [[ -e "$target" ]]; then
      printf '  currently a plain file/ELF (typical after `grok update`)\n'
    else
      printf '  missing\n'
    fi
    printf '  fix: scripts/runtime/grok-with-focus-filter.sh --install\n'
    rc=1
  fi

  if [[ -x "$real" ]]; then
    printf 'ok: %s executable\n' "$real"
  else
    printf 'FAIL: missing executable %s\n' "$real"
    printf '  fix: scripts/runtime/grok-with-focus-filter.sh --install\n'
    rc=1
  fi

  if is_this_wrapper "$local_link"; then
    printf 'ok: %s → focus-filter wrapper (backup PATH entry)\n' "$local_link"
  else
    printf 'WARN: %s is not the wrapper (login PATH still needs ~/.grok/bin fixed)\n' "$local_link"
  fi

  # Prefer a login-shell which so we mirror interactive `grok` / direct CLI.
  local first=""
  first="$(zsh -ilc 'command -v grok' 2>/dev/null || command -v grok || true)"
  if [[ -n "$first" ]] && is_this_wrapper "$first"; then
    printf 'ok: login/PATH first hit is the wrapper (%s)\n' "$first"
  elif [[ -n "$first" ]]; then
    printf 'FAIL: login/PATH first hit is %s (not the wrapper)\n' "$first"
    printf '  direct `grok` in a fresh shell will flash under tmux until --install\n'
    rc=1
  else
    printf 'FAIL: grok not on PATH\n'
    rc=1
  fi

  if (( rc == 0 )); then
    printf 'check: focus-filter install looks healthy\n'
  else
    printf 'check: focus-filter install needs repair (see FAIL lines above)\n' >&2
  fi
  return "$rc"
}

if [[ "${1:-}" == "--install" ]]; then
  install_wrapper
  exit 0
fi

if [[ "${1:-}" == "--check" ]]; then
  check_wrapper
  exit $?
fi

REAL_BIN="$(resolve_real_bin)"
export GROK_REAL_BIN="$REAL_BIN"

if [[ ! -f "$FILTER_PY" ]]; then
  printf 'grok-with-focus-filter: missing %s\n' "$FILTER_PY" >&2
  exit 127
fi

exec python3 "$FILTER_PY" -- "$REAL_BIN" "$@"
