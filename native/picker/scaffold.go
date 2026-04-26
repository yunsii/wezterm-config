// scaffold.go — runtime helpers shared by every picker: timestamp
// argument parsing, the perf-timing breakdown rendered in each footer,
// raw-mode termios setup/teardown, the key-read loop, terminal-size
// query, and a few tiny text utilities. Factored out so each cmd_*.go
// can stay focused on its data model, key bindings, and render layout
// — the parts that actually differ between pickers.
package main

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
)

// ─── timestamp args ───────────────────────────────────────────────────

// parseTimestampArg pulls an epoch-ms argument at args[i]. Returns 0
// when the index is out of range or the value is missing/non-positive
// — the perf footer treats 0 as "not supplied" and skips that segment.
func parseTimestampArg(args []string, i int) int64 {
	if len(args) <= i {
		return 0
	}
	v, err := strconv.ParseInt(args[i], 10, 64)
	if err != nil || v <= 0 {
		return 0
	}
	return v
}

// perfTimings carries the three optional epoch-ms timestamps the
// menu.sh launcher passes through (keypress → menu_start → menu_done).
// They feed the footer's `Xms = lua+menu+picker` breakdown and the
// perf-event emit.
type perfTimings struct {
	keypressTS  int64
	menuStartTS int64
	menuDoneTS  int64
}

// parsePerfTimings reads the conventional trailing triple at
// args[base], args[base+1], args[base+2]. All three are optional.
func parsePerfTimings(args []string, base int) perfTimings {
	return perfTimings{
		keypressTS:  parseTimestampArg(args, base),
		menuStartTS: parseTimestampArg(args, base+1),
		menuDoneTS:  parseTimestampArg(args, base+2),
	}
}

// stages computes the elapsed total + 3-bucket breakdown. Returns
// all zeros when keypressTS isn't supplied. The breakdown is
// meaningful only when all three timestamps are non-zero; otherwise
// lua/menu/picker are zero and only `elapsed` is set.
func (t perfTimings) stages() (elapsed, lua, menu, picker int64) {
	if t.keypressTS <= 0 {
		return 0, 0, 0, 0
	}
	now := time.Now().UnixMilli()
	elapsed = now - t.keypressTS
	if elapsed < 0 {
		elapsed = 0
	}
	if t.menuStartTS > 0 && t.menuDoneTS > 0 {
		lua = t.menuStartTS - t.keypressTS
		menu = t.menuDoneTS - t.menuStartTS
		picker = now - t.menuDoneTS
		if lua < 0 {
			lua = 0
		}
		if menu < 0 {
			menu = 0
		}
		if picker < 0 {
			picker = 0
		}
	}
	return
}

// renderFooterTail appends the dim "  ·  Xms = a+b+c (lua+menu+picker)"
// (or fallback "  ·  Xms key→paint") suffix to b. No-op when keypressTS
// is 0. Returns the stages so the caller can pass them straight into
// emit() without recomputing.
func (t perfTimings) renderFooterTail(b *strings.Builder) (elapsed, lua, menu, picker int64) {
	if t.keypressTS <= 0 {
		return 0, 0, 0, 0
	}
	const reset = "\x1b[0m"
	elapsed, lua, menu, picker = t.stages()
	if t.menuStartTS > 0 && t.menuDoneTS > 0 {
		fmt.Fprintf(b, "\x1b[2m  ·  %dms = %d+%d+%d (lua+menu+picker)%s",
			elapsed, lua, menu, picker, reset)
	} else {
		fmt.Fprintf(b, "\x1b[2m  ·  %dms key→paint%s", elapsed, reset)
	}
	return
}

// emit posts a perf event with the schema every picker shares.
// extra is merged in for picker-specific fields; nil is fine. No-op
// when keypressTS is 0.
func (t perfTimings) emit(category, panel, message, paintKind string, itemCount, selectedIdx int, extra map[string]string) {
	if t.keypressTS <= 0 {
		return
	}
	elapsed, lua, menu, picker := t.stages()
	fields := map[string]string{
		"paint_kind":     paintKind,
		"picker_kind":    "go",
		"panel":          panel,
		"total_ms":       strconv.FormatInt(elapsed, 10),
		"lua_ms":         strconv.FormatInt(lua, 10),
		"menu_ms":        strconv.FormatInt(menu, 10),
		"picker_ms":      strconv.FormatInt(picker, 10),
		"item_count":     strconv.Itoa(itemCount),
		"selected_index": strconv.Itoa(selectedIdx),
	}
	for k, v := range extra {
		fields[k] = v
	}
	emitPerfEvent(category, message, fields)
}

// ─── terminal ─────────────────────────────────────────────────────────

// getTermSize returns (cols, lines) with the same fallback every
// picker uses when GetSize fails or returns nonsense (cols<1 → 80,
// lines<1 → 24).
func getTermSize() (cols, lines int) {
	c, l, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || c < 1 {
		c = 80
	}
	if l < 1 {
		l = 24
	}
	return c, l
}

// enterRawMode hides the cursor and switches stdin to raw termios.
// Returns ok=false (with a diagnostic on stderr) when MakeRaw fails;
// the caller should bail out without further terminal mutation.
func enterRawMode() (fd int, state *term.State, ok bool) {
	fd = int(os.Stdin.Fd())
	s, err := term.MakeRaw(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: MakeRaw: %v\n", err)
		return 0, nil, false
	}
	_, _ = os.Stdout.WriteString("\x1b[?25l")
	return fd, s, true
}

// restoreRawMode is the matched cleanup: restores termios, resets SGR,
// shows the cursor. Idempotent — safe to call from a dispatch path
// that shells out, and again from the deferred cleanup.
func restoreRawMode(fd int, state *term.State) {
	_ = term.Restore(fd, state)
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")
}

// ─── input loop ───────────────────────────────────────────────────────

type loopAction int

const (
	loopContinue loopAction = iota
	loopExit
)

// runKeyLoop drives the standard read-key loop. The handler returns
// (loopExit, code) to terminate the loop with that exit code, or
// (loopContinue, _) to keep looping. EOF on stdin closes cleanly with
// exit 0; other read errors are silently retried (mirrors the prior
// per-picker behaviour).
func runKeyLoop(onKey func(key string) (loopAction, int)) int {
	for {
		key, err := readKey()
		if err != nil {
			if err == io.EOF {
				return 0
			}
			continue
		}
		action, code := onKey(key)
		if action == loopExit {
			return code
		}
	}
}

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

// ─── text utilities ───────────────────────────────────────────────────

// shellEscape quotes a string for embedding into a bash command line
// passed via `tmux run-shell -b "<cmd>"`. POSIX single-quote safety for
// arbitrary content.
func shellEscape(s string) string {
	if s == "" {
		return "''"
	}
	if !strings.ContainsAny(s, " \t\n'\"\\$`*?[]{}|&;<>()#") {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// isPrintable reports whether every rune in s is a printable character
// (i.e. safe to append to a filter query). Single control bytes and
// DEL are rejected; multi-byte UTF-8 passes since runes ≥ 0x80 are
// printable for filter purposes.
func isPrintable(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// visibleWidth approximates terminal cell width for right-align math.
// Treats every rune as 1 cell; double-wide CJK or emoji in labels
// render fine but the hint may shift by a column. Acceptable for a
// single line of metadata — perfect alignment would require pulling
// in a width-table package, which is out of proportion for this usage.
func visibleWidth(s string) int {
	w := 0
	inEsc := false
	for _, r := range s {
		if inEsc {
			if r == 'm' || r == 'K' || r == 'H' || r == 'J' {
				inEsc = false
			}
			continue
		}
		if r == 0x1b {
			inEsc = true
			continue
		}
		w++
	}
	return w
}
