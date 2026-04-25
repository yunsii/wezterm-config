// picker is a static Linux binary that runs inside `tmux display-popup -E`
// and serves as the TUI for the agent-attention overlay (and, eventually,
// the worktree picker). It replaces the bash + render.sh + jq combo with
// a single fork — process startup drops from ~30-80ms (bash + 3 lib
// sources cold) to ~2-5ms (Go runtime init), and the input loop avoids
// the per-keypress fork that bash incurs for `read -t 0` / `printf`
// substitutions.
//
// Subcommand layout: `picker attention <prefetch_tsv> <attention_jump_sh>`.
// The prefetch TSV is built upstream (currently by tmux-attention-menu.sh,
// soon by the WezTerm Lua handler directly) so the picker itself never
// touches state.json or jq.
//
// Build: `CGO_ENABLED=0 go build -ldflags='-s -w' -o bin/picker .`
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: picker <subcommand> [args...]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "attention":
		os.Exit(runAttention(os.Args[2:]))
	default:
		fmt.Fprintf(os.Stderr, "picker: unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

// ─── attention ────────────────────────────────────────────────────────

type attentionRow struct {
	status string // "running" | "waiting" | "done" | "__sentinel__"
	body   string
	age    string
	id     string
}

func runAttention(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: picker attention <prefetch_tsv> <attention_jump_sh> [keypress_ts] [menu_start_ts] [menu_done_ts]")
		return 2
	}
	prefetchPath := args[0]
	jumpScript := args[1]
	// Optional diagnostic timestamps (all epoch ms, 0 disables that
	// segment). The footer breaks elapsed into three buckets so the user
	// can see WHERE the cold-start cost lives:
	//   L = menu_start - keypress  (lua handler + tmux dispatch + bash boot)
	//   M = menu_done  - menu_start (menu.sh work: jq + popup spawn)
	//   P = render     - menu_done  (popup pty + go runtime + first frame)
	parseTS := func(i int) int64 {
		if len(args) <= i {
			return 0
		}
		v, err := strconv.ParseInt(args[i], 10, 64)
		if err != nil || v <= 0 {
			return 0
		}
		return v
	}
	keypressTS := parseTS(2)
	menuStartTS := parseTS(3)
	menuDoneTS := parseTS(4)

	rows, err := loadAttentionRows(prefetchPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: %v\n", err)
		return 1
	}
	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, "picker: prefetch TSV produced 0 rows")
		return 1
	}

	fd := int(os.Stdin.Fd())
	state, err := term.MakeRaw(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: MakeRaw: %v\n", err)
		return 1
	}
	defer func() {
		_ = term.Restore(fd, state)
		// Show cursor + reset attrs so the popup pty leaves no residue.
		_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")
	}()
	// Hide cursor for the picker's lifetime.
	_, _ = os.Stdout.WriteString("\x1b[?25l")

	selected := 0
	total := len(rows)

	// First paint.
	renderAttentionFrame(rows, selected, keypressTS, menuStartTS, menuDoneTS, "first")

	for {
		key, err := readKey()
		if err != nil {
			if err == io.EOF {
				return 0
			}
			continue
		}

		switch key {
		case "\r", "\n":
			dispatchAttention(rows[selected], jumpScript)
			return 0
		case "\x1b", "\x03", "\x1b/":
			// Bare Esc, Ctrl+C, or the forwarded `\x1b/` from a second
			// Alt+/ press — the popup is the only thing listening, so
			// the same chord that opens the picker also closes it.
			return 0
		case "\x1b[B", "\x1bOB", "j":
			selected = (selected + 1) % total
			renderAttentionFrame(rows, selected, keypressTS, menuStartTS, menuDoneTS, "repaint")
		case "\x1b[A", "\x1bOA", "k":
			selected = (selected - 1 + total) % total
			renderAttentionFrame(rows, selected, keypressTS, menuStartTS, menuDoneTS, "repaint")
		}
	}
}

func loadAttentionRows(path string) ([]attentionRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read prefetch %s: %w", path, err)
	}
	var rows []attentionRow
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) < 4 {
			continue
		}
		rows = append(rows, attentionRow{
			status: parts[0],
			body:   parts[1],
			age:    parts[2],
			id:     parts[3],
		})
	}
	return rows, nil
}

// renderAttentionFrame mirrors scripts/runtime/tmux-attention/render.sh's
// `attention_picker_emit_frame` byte-for-byte: same ANSI positioning,
// same color codes, same selection highlight scheme. If you change
// either, change both — the bash menu.sh side still pre-renders the
// first frame for the bash fallback path.
func renderAttentionFrame(rows []attentionRow, selected int, keypressTS, menuStartTS, menuDoneTS int64, paintKind string) {
	cols, lines, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || cols < 1 {
		cols = 80
	}
	if lines < 1 {
		lines = 24
	}
	visibleRows := lines - 4
	if visibleRows < 1 {
		visibleRows = 1
	}
	itemCount := len(rows)

	startIndex := 0
	if selected >= visibleRows {
		startIndex = selected - visibleRows + 1
	}
	endIndex := startIndex + visibleRows - 1
	if endIndex >= itemCount {
		endIndex = itemCount - 1
		startIndex = endIndex - visibleRows + 1
		if startIndex < 0 {
			startIndex = 0
		}
	}

	const reset = "\x1b[0m"
	const clearEOL = "\x1b[K"

	var b strings.Builder
	b.Grow(2048)

	// Title row.
	b.WriteString("\x1b[1;1H\x1b[1m")
	fmt.Fprintf(&b, "Agent attention — %d/%d  ·  order matches status bar (⟳ → ⚠ → ✓)", selected+1, itemCount)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	// Item rows start at row 3 (row 2 stays blank as a divider).
	row := 3
	for i := startIndex; i <= endIndex; i++ {
		fmt.Fprintf(&b, "\x1b[%d;1H", row)
		r := rows[i]
		if i == selected {
			b.WriteString("\x1b[1;7m")
			b.WriteString(plainBadge(r.status))
			b.WriteString("  ")
			b.WriteString(r.body)
			if r.age != "" {
				b.WriteString("  (")
				b.WriteString(r.age)
				b.WriteString(")")
			}
			b.WriteString(reset)
			b.WriteString(clearEOL)
		} else {
			b.WriteString(coloredBadge(r.status))
			b.WriteString("  ")
			b.WriteString(r.body)
			if r.age != "" {
				b.WriteString("  \x1b[2m(")
				b.WriteString(r.age)
				b.WriteString(")")
				b.WriteString(reset)
			}
			b.WriteString(clearEOL)
		}
		row++
	}

	// Footer: blank divider then dim hint + powered-by badge + (when a
	// keypress ts is provided) end-to-end key→paint latency. The
	// powered-by badge makes which code path is live legible at a glance
	// during the parallel-implementation phase (this Go binary vs the
	// bash fallback); same green family as `✓ DONE` (palette 108)
	// signals "fast path active". The latency badge is the diagnostic
	// readout the user is actively comparing across runs — drop both
	// once the bash picker is removed.
	row++
	fmt.Fprintf(&b, "\x1b[%d;1H", row)
	b.WriteString("\x1b[2mEnter jump | Up/Down move | Esc / Alt+/ close  ·  powered by ")
	b.WriteString("\x1b[22;1;38;5;108mgo")
	b.WriteString(reset)
	var elapsed, lua, menu, picker int64
	if keypressTS > 0 {
		nowMs := time.Now().UnixMilli()
		elapsed = nowMs - keypressTS
		if elapsed < 0 {
			elapsed = 0
		}
		// Stage breakdown (when all three upstream timestamps are
		// supplied) — `L+M+P = total`, so it's easy to spot which bucket
		// is the bottleneck on any given run.
		if menuStartTS > 0 && menuDoneTS > 0 {
			lua = menuStartTS - keypressTS
			menu = menuDoneTS - menuStartTS
			picker = nowMs - menuDoneTS
			if lua < 0 {
				lua = 0
			}
			if menu < 0 {
				menu = 0
			}
			if picker < 0 {
				picker = 0
			}
			fmt.Fprintf(&b, "\x1b[2m  ·  %dms = %d+%d+%d (lua+menu+picker)%s", elapsed, lua, menu, picker, reset)
		} else {
			fmt.Fprintf(&b, "\x1b[2m  ·  %dms key→paint%s", elapsed, reset)
		}
	}
	b.WriteString(clearEOL)

	// Wipe anything still drawn below the footer (e.g. stale content from
	// a taller previous frame in the same popup pty).
	b.WriteString("\x1b[J")

	_, _ = os.Stdout.WriteString(b.String())

	// Perf event for the bench harness. Mirror the bash picker's
	// `attention.perf` category + `popup paint timing` message so both
	// code paths feed the same dashboard.
	if keypressTS > 0 {
		logPerfEvent("popup paint timing", map[string]string{
			"paint_kind":     paintKind,
			"picker_kind":    "go",
			"total_ms":       strconv.FormatInt(elapsed, 10),
			"lua_ms":         strconv.FormatInt(lua, 10),
			"menu_ms":        strconv.FormatInt(menu, 10),
			"picker_ms":      strconv.FormatInt(picker, 10),
			"item_count":     strconv.Itoa(len(rows)),
			"selected_index": strconv.Itoa(selected),
		})
	}
}

// ─── perf log emitter ─────────────────────────────────────────────────
//
// Mirrors `runtime_log_emit` from scripts/runtime/runtime-log-lib.sh:
// same field-quoting semantics, same `WEZTERM_RUNTIME_LOG_*` env knobs,
// same destination file. Only the level filter is fixed at "info" — the
// picker has no debug/warn/error perf events to emit.

func logPerfEvent(message string, fields map[string]string) {
	const category = "attention.perf"

	if os.Getenv("WEZTERM_RUNTIME_LOG_ENABLED") == "0" {
		return
	}
	// Level filter: only emit when the configured threshold is at or
	// below "info". Default in runtime-log-lib is "info"; "warn"/"error"
	// disable info logs.
	switch strings.ToLower(os.Getenv("WEZTERM_RUNTIME_LOG_LEVEL")) {
	case "", "info", "debug":
		// pass
	default:
		return
	}
	if cats := os.Getenv("WEZTERM_RUNTIME_LOG_CATEGORIES"); cats != "" {
		ok := false
		for _, c := range strings.Split(cats, ",") {
			if strings.TrimSpace(c) == category {
				ok = true
				break
			}
		}
		if !ok {
			return
		}
	}

	logFile := os.Getenv("WEZTERM_RUNTIME_LOG_FILE")
	if logFile == "" {
		stateHome := os.Getenv("XDG_STATE_HOME")
		if stateHome == "" {
			stateHome = filepath.Join(os.Getenv("HOME"), ".local", "state")
		}
		logFile = filepath.Join(stateHome, "wezterm-runtime", "logs", "runtime.log")
	}
	if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()

	traceID := os.Getenv("WEZTERM_RUNTIME_TRACE_ID")
	source := os.Getenv("WEZTERM_RUNTIME_LOG_SOURCE")
	if source == "" {
		source = "picker"
	}
	ts := time.Now().Format("2006-01-02 15:04:05")

	var b strings.Builder
	fmt.Fprintf(&b, "ts=%s level=%s source=%s category=%s trace_id=%s message=%s",
		logEscape(ts), logEscape("info"), logEscape(source),
		logEscape(category), logEscape(traceID), logEscape(message))
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(&b, " %s=%s", k, logEscape(fields[k]))
	}
	b.WriteByte('\n')
	_, _ = f.WriteString(b.String())
}

// logEscape mirrors runtime_log_escape_value: simple escapes for \, ",
// newline, carriage return, tab — wrapped in double quotes.
func logEscape(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '\\':
			b.WriteString(`\\`)
		case '"':
			b.WriteString(`\"`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func coloredBadge(status string) string {
	switch status {
	case "running":
		return "\x1b[1;38;5;39m⟳ RUN \x1b[0m"
	case "waiting":
		return "\x1b[1;38;5;208m⚠ WAIT\x1b[0m"
	case "done":
		return "\x1b[38;5;108m✓ DONE\x1b[0m"
	case "__sentinel__":
		return "\x1b[1;38;5;160m✗ CLR \x1b[0m"
	}
	return "· ----"
}

func plainBadge(status string) string {
	switch status {
	case "running":
		return "⟳ RUN "
	case "waiting":
		return "⚠ WAIT"
	case "done":
		return "✓ DONE"
	case "__sentinel__":
		return "✗ CLR "
	}
	return "· ----"
}

func dispatchAttention(r attentionRow, jumpScript string) {
	// Restore termios + show cursor BEFORE shelling out to tmux so the
	// popup pty cleans up cleanly even if tmux's run-shell has any
	// observable side effect on the parent fd state.
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")

	var cmd string
	if r.id == "__clear_all__" {
		cmd = fmt.Sprintf("bash %s --clear-all", shellEscape(jumpScript))
	} else {
		cmd = fmt.Sprintf("bash %s --session %s", shellEscape(jumpScript), shellEscape(r.id))
	}
	// `tmux run-shell -b` returns immediately; the popup tears down
	// before attention-jump.sh starts the WezTerm cli round-trip, so
	// the user perceives the jump as instant.
	_ = exec.Command("tmux", "run-shell", "-b", cmd).Run()
}

// shellEscape quotes a string for embedding into a bash command line
// passed via `tmux run-shell -b "<cmd>"`. We need POSIX single-quote
// safety for arbitrary content.
func shellEscape(s string) string {
	if s == "" {
		return "''"
	}
	if !strings.ContainsAny(s, " \t\n'\"\\$`*?[]{}|&;<>()#") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// ─── input ────────────────────────────────────────────────────────────

// readKey reads one keystroke from stdin. With termios raw mode active
// (term.MakeRaw sets VMIN=1 VTIME=0), Read() blocks until at least one
// byte is available but returns up to len(buf) bytes if more are already
// buffered. Multi-byte escape sequences (`\x1b[A`, `\x1bO B`, the
// forwarded `\x1b/` from a second Alt+/ press) all arrive in one PTY
// write from the terminal, so a single Read() captures them atomically.
// Bare Esc has no follow-up bytes and returns as a 1-byte read — the
// caller distinguishes it by string match. No `read -t 0` peek needed
// because the kernel already gives us the right semantics.
func readKey() (string, error) {
	var buf [16]byte
	n, err := os.Stdin.Read(buf[:])
	if err != nil {
		return "", err
	}
	if n == 0 {
		return "", nil
	}
	return string(buf[:n]), nil
}
