// `picker worktree` — replaces tmux-worktree-picker.sh inside the popup
// pty. Reads a TSV menu.sh prefetched (with existing_window_id already
// resolved, so the popup pty does zero tmux RPCs at first paint) and
// fires `tmux-worktree-open.sh` via `tmux run-shell -b` so the popup
// tears down before the open work starts.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/term"
)

type worktreeRow struct {
	label            string
	path             string
	branch           string
	existingWindowID string // empty when no tmux window for this worktree yet
	accelerator      string // single-char key, e.g. "1" or "a"; "" when out of slots
}

type worktreeUI struct {
	rows                []worktreeRow
	selected            int
	currentWorktreeRoot string
	repoLabel           string
	openScript          string
	sessionName         string
	currentWindowID     string
	cwd                 string
	ts                  perfTimings
}

type worktreePicker struct{}

func (worktreePicker) Name() string { return "worktree" }

func (worktreePicker) Run(args []string) int {
	if len(args) < 7 {
		fmt.Fprintln(os.Stderr, "usage: picker worktree <prefetch_tsv> <open_script> <session_name> <current_window_id> <cwd> <current_worktree_root> <repo_label> [keypress_ts] [menu_start_ts] [menu_done_ts]")
		return 2
	}
	prefetchPath := args[0]
	openScript := args[1]
	sessionName := args[2]
	currentWindowID := args[3]
	cwd := args[4]
	currentRoot := args[5]
	repoLabel := args[6]
	ts := parsePerfTimings(args, 7)

	rows, err := loadWorktreeRows(prefetchPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: %v\n", err)
		return 1
	}
	if len(rows) == 0 {
		fmt.Fprintf(os.Stderr, "picker: no worktrees for %s\n", repoLabel)
		return 1
	}

	// Pre-select the current worktree row so Enter on first paint = stay
	// (or with no current root, default to the first row).
	selected := 0
	for i, r := range rows {
		if r.path == currentRoot {
			selected = i
			break
		}
	}

	fd, state, ok := enterRawMode()
	if !ok {
		return 1
	}
	defer restoreRawMode(fd, state)

	ui := &worktreeUI{
		rows:                rows,
		selected:            selected,
		currentWorktreeRoot: currentRoot,
		repoLabel:           repoLabel,
		openScript:          openScript,
		sessionName:         sessionName,
		currentWindowID:     currentWindowID,
		cwd:                 cwd,
		ts:                  ts,
	}
	ui.render("first")

	return runKeyLoop(func(key string) (loopAction, int) {
		switch key {
		case "\r", "\n":
			ui.dispatch(fd, state)
			return loopExit, 0
		case "\x1b", "\x03", "\x1bg":
			// Bare Esc / Ctrl+C / forwarded Alt+g (the chord that opened
			// this popup, treated as a toggle exit). Mirrors bash picker.
			return loopExit, 0
		case "\x1b[B", "\x1bOB":
			ui.move(1)
			ui.render("repaint")
		case "\x1b[A", "\x1bOA":
			ui.move(-1)
			ui.render("repaint")
		default:
			if i := ui.findAccelerator(key); i >= 0 {
				ui.selected = i
				ui.dispatch(fd, state)
				return loopExit, 0
			}
		}
		return loopContinue, 0
	})
}

func loadWorktreeRows(path string) ([]worktreeRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read prefetch %s: %w", path, err)
	}
	accels := []string{
		"1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
		"a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
		"k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
		"u", "v", "w", "x", "y", "z",
	}
	var rows []worktreeRow
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		// 4 fields: label  path  branch  existing_window_id
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) < 4 {
			continue
		}
		row := worktreeRow{
			label:            parts[0],
			path:             parts[1],
			branch:           parts[2],
			existingWindowID: parts[3],
		}
		if len(rows) < len(accels) {
			row.accelerator = accels[len(rows)]
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func (ui *worktreeUI) move(delta int) {
	n := len(ui.rows)
	if n == 0 {
		ui.selected = 0
		return
	}
	ui.selected = (ui.selected + delta) % n
	if ui.selected < 0 {
		ui.selected += n
	}
}

func (ui *worktreeUI) findAccelerator(key string) int {
	if len(key) != 1 {
		return -1
	}
	k := strings.ToLower(key)
	for i, r := range ui.rows {
		if r.accelerator == k {
			return i
		}
	}
	return -1
}

func (ui *worktreeUI) render(paintKind string) {
	_, lines := getTermSize()
	visibleRows := lines - 6
	if visibleRows < 1 {
		visibleRows = 1
	}
	itemCount := len(ui.rows)

	startIndex := 0
	if ui.selected >= visibleRows {
		startIndex = ui.selected - visibleRows + 1
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
	fmt.Fprintf(&b, "Worktrees: %s", ui.repoLabel)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	// "Showing N-M of K" indicator.
	b.WriteString("\x1b[2;1H\x1b[2m")
	fmt.Fprintf(&b, "Showing %d-%d of %d", startIndex+1, endIndex+1, itemCount)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	row := 4
	for i := startIndex; i <= endIndex; i++ {
		fmt.Fprintf(&b, "\x1b[%d;1H", row)
		r := ui.rows[i]
		marker := ' '
		if r.path == ui.currentWorktreeRoot {
			marker = '*'
		}
		accelText := "   "
		if r.accelerator != "" {
			accelText = "[" + r.accelerator + "]"
		}
		branch := ""
		if r.branch != "" {
			branch = " [" + r.branch + "]"
		}
		suffix := ""
		if r.existingWindowID == "" {
			suffix = " (new)"
		}
		if i == ui.selected {
			b.WriteString("▶ ")
		} else {
			b.WriteString("  ")
		}
		fmt.Fprintf(&b, "%s %c %s%s%s", accelText, marker, r.label, branch, suffix)
		b.WriteString(clearEOL)
		row++
	}

	// Footer.
	row++
	fmt.Fprintf(&b, "\x1b[%d;1H", row)
	b.WriteString("\x1b[2mEnter open | Up/Down move | 1-9,0,a-z open | Esc close  ·  powered by ")
	b.WriteString("\x1b[22;1;38;5;108mgo")
	b.WriteString(reset)
	ui.ts.renderFooterTail(&b)
	b.WriteString(clearEOL)
	b.WriteString("\x1b[J")

	_, _ = os.Stdout.WriteString(b.String())

	ui.ts.emit("worktree.perf", "worktree", "worktree picker paint timing", paintKind, itemCount, ui.selected, nil)
}

func (ui *worktreeUI) dispatch(fd int, state *term.State) {
	if ui.selected < 0 || ui.selected >= len(ui.rows) {
		return
	}
	r := ui.rows[ui.selected]

	// Restore termios + cursor BEFORE shelling out to tmux. Mirrors the
	// attention picker's dispatchAttention.
	_ = term.Restore(fd, state)
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")

	// `tmux run-shell -b` returns immediately so the popup tears down
	// before tmux-worktree-open.sh starts the (potentially slow) tmux
	// new-window / cd / send-keys round-trip.
	cmd := fmt.Sprintf("bash %s %s %s %s %s",
		shellEscape(ui.openScript),
		shellEscape(ui.sessionName),
		shellEscape(r.path),
		shellEscape(ui.currentWindowID),
		shellEscape(ui.cwd))
	_ = exec.Command("tmux", "run-shell", "-b", cmd).Run()
}

func init() { register(worktreePicker{}) }
