// picker is a static Linux binary that runs inside `tmux display-popup -E`
// and serves as the TUI for several wezterm-x popups (attention overlay,
// command palette, worktree picker, links picker). It replaces the bash +
// render.sh + jq combo with a single fork — process startup drops from
// ~30-80ms (bash + 3 lib sources cold) to ~2-5ms (Go runtime init), and
// the input loop avoids the per-keypress fork that bash incurs for
// `read -t 0` / `printf` substitutions.
//
// Each subcommand lives in its own cmd_*.go and self-registers via
// init() into the registry in picker.go; this file is just the
// entrypoint. Shared runtime helpers (raw mode, key loop, perf
// timings) live in scaffold.go; the perf-event emitter lives in
// log.go.
//
// Build: `CGO_ENABLED=0 go build -ldflags='-s -w' -o bin/picker .`
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: picker <subcommand> [args...]")
		os.Exit(2)
	}
	os.Exit(dispatchSubcommand(os.Args[1], os.Args[2:]))
}
