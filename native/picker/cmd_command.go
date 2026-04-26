// `picker command` — replaces tmux-command-picker.sh inside the popup pty.
// Same shape as the attention subcommand: menu.sh prefetches the visible
// items into a TSV, this binary owns everything from popup-pty entry
// through dispatch. Cuts ~30-80ms of bash startup + lib sourcing per
// invocation; see docs/performance.md cross-panel baseline.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/term"
)

type commandRow struct {
	id             string
	label          string
	description    string
	accelerator    string // single-letter shortcut from manifest
	hotkeyDisplay  string // human-readable hotkey label, comma-joined
	confirmMessage string
}

type commandUI struct {
	rows           []commandRow
	mode           string
	query          string
	filtered       []int // indexes into rows after the substring filter
	selected       int
	ts             perfTimings
	runScript      string
	sessionName    string
	currentWindow  string
	cwd            string
	clientTTY      string
	lastCommandID  string
	pendingConfirm string // non-empty while the confirm overlay is up
	pendingItemID  string
}

type commandPicker struct{}

func (commandPicker) Name() string { return "command" }

func (commandPicker) Run(args []string) int {
	if len(args) < 8 {
		fmt.Fprintln(os.Stderr, "usage: picker command <prefetch_tsv> <run_script> <runtime_mode> <session_name> <current_window_id> <cwd> <client_tty> <last_command_id> [keypress_ts] [menu_start_ts] [menu_done_ts]")
		return 2
	}
	prefetchPath := args[0]
	runScript := args[1]
	mode := args[2]
	sessionName := args[3]
	currentWindow := args[4]
	cwd := args[5]
	clientTTY := args[6]
	lastCommandID := args[7]
	ts := parsePerfTimings(args, 8)

	rows, err := loadCommandRows(prefetchPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: %v\n", err)
		return 1
	}
	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, "picker: prefetch TSV produced 0 rows")
		return 1
	}

	// Move the MRU entry to the top with a ↻ prefix so it's both
	// pre-selected and visually distinguished. Mirrors the bash picker.
	if lastCommandID != "" {
		for i, r := range rows {
			if r.id == lastCommandID {
				if i > 0 {
					mru := rows[i]
					mru.label = "↻ " + mru.label
					rows = append([]commandRow{mru}, append(rows[:i], rows[i+1:]...)...)
				} else {
					rows[0].label = "↻ " + rows[0].label
				}
				break
			}
		}
	}

	fd, state, ok := enterRawMode()
	if !ok {
		return 1
	}
	defer restoreRawMode(fd, state)

	ui := &commandUI{
		rows:          rows,
		mode:          mode,
		runScript:     runScript,
		sessionName:   sessionName,
		currentWindow: currentWindow,
		cwd:           cwd,
		clientTTY:     clientTTY,
		lastCommandID: lastCommandID,
		ts:            ts,
	}
	ui.refilter()
	ui.render("first")

	return runKeyLoop(func(key string) (loopAction, int) {
		// Confirm overlay swallows all keys until it is dismissed.
		if ui.pendingConfirm != "" {
			if strings.EqualFold(key, "y") {
				ui.pendingConfirm = ""
				if ui.dispatchByID(ui.pendingItemID, fd, state) {
					return loopExit, 0
				}
			} else {
				ui.pendingConfirm = ""
				ui.pendingItemID = ""
				ui.render("repaint")
			}
			return loopContinue, 0
		}

		switch key {
		case "\r", "\n":
			if len(ui.filtered) == 0 {
				return loopContinue, 0
			}
			row := ui.rows[ui.filtered[ui.selected]]
			if row.confirmMessage != "" {
				ui.pendingConfirm = row.confirmMessage
				ui.pendingItemID = row.id
				ui.renderConfirm()
				return loopContinue, 0
			}
			if ui.dispatchByID(row.id, fd, state) {
				return loopExit, 0
			}
		case "\x1b[20099~", "\x03":
			// Forwarded Ctrl+Shift+P (the chord that opened this popup) or
			// Ctrl+C: always close, regardless of query state. Makes the
			// open shortcut a true toggle, mirroring Alt+/ on attention.
			return loopExit, 0
		case "\x1b":
			// Bare Esc: clear query first if non-empty, then close. Friendly
			// behavior that lets users back out of a search without losing
			// the popup; the open chord above is the unconditional toggle.
			if ui.query != "" {
				ui.query = ""
				ui.refilter()
				ui.render("repaint")
				return loopContinue, 0
			}
			return loopExit, 0
		case "\x1b[B", "\x1bOB":
			ui.move(1)
			ui.render("repaint")
		case "\x1b[A", "\x1bOA":
			ui.move(-1)
			ui.render("repaint")
		case "\x7f", "\x08":
			if ui.query != "" {
				ui.query = ui.query[:len(ui.query)-1]
				ui.refilter()
				ui.render("repaint")
			}
		case "\x15": // Ctrl+U
			if ui.query != "" {
				ui.query = ""
				ui.refilter()
				ui.render("repaint")
			}
		default:
			if isPrintable(key) {
				ui.query += key
				ui.refilter()
				ui.render("repaint")
			}
		}
		return loopContinue, 0
	})
}

func loadCommandRows(path string) ([]commandRow, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read prefetch %s: %w", path, err)
	}
	var rows []commandRow
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		// 6 fields: id  label  description  accelerator  hotkey_display  confirm_message
		parts := strings.SplitN(line, "\t", 6)
		if len(parts) < 6 {
			continue
		}
		rows = append(rows, commandRow{
			id:             parts[0],
			label:          parts[1],
			description:    parts[2],
			accelerator:    parts[3],
			hotkeyDisplay:  parts[4],
			confirmMessage: parts[5],
		})
	}
	return rows, nil
}

func (ui *commandUI) refilter() {
	q := strings.ToLower(ui.query)
	ui.filtered = ui.filtered[:0]
	for i, r := range ui.rows {
		if q == "" {
			ui.filtered = append(ui.filtered, i)
			continue
		}
		// Match same haystack the bash picker built: label + description +
		// id + accelerator + hotkey. Substring match on lowered haystack.
		if strings.Contains(strings.ToLower(r.label+" "+r.description+" "+r.id+" "+r.accelerator+" "+r.hotkeyDisplay), q) {
			ui.filtered = append(ui.filtered, i)
		}
	}
	if len(ui.filtered) == 0 {
		ui.selected = 0
		return
	}
	if ui.selected >= len(ui.filtered) {
		ui.selected = len(ui.filtered) - 1
	}
	if ui.selected < 0 {
		ui.selected = 0
	}
}

func (ui *commandUI) move(delta int) {
	n := len(ui.filtered)
	if n == 0 {
		ui.selected = 0
		return
	}
	ui.selected = (ui.selected + delta) % n
	if ui.selected < 0 {
		ui.selected += n
	}
}

func (ui *commandUI) render(paintKind string) {
	cols, lines := getTermSize()
	visibleRows := lines - 7
	if visibleRows < 1 {
		visibleRows = 1
	}
	filteredCount := len(ui.filtered)

	startIndex := 0
	if ui.selected >= visibleRows {
		startIndex = ui.selected - visibleRows + 1
	}
	endIndex := startIndex + visibleRows - 1
	if endIndex >= filteredCount {
		endIndex = filteredCount - 1
		startIndex = endIndex - visibleRows + 1
		if startIndex < 0 {
			startIndex = 0
		}
	}

	const reset = "\x1b[0m"
	const clearEOL = "\x1b[K"

	var b strings.Builder
	b.Grow(2048)

	// Header rows.
	b.WriteString("\x1b[1;1H\x1b[1m")
	fmt.Fprintf(&b, "Command Palette — %d/%d", ui.displayedSelected(), filteredCount)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	b.WriteString("\x1b[2;1H\x1b[2m")
	fmt.Fprintf(&b, "Runtime mode: %s", ui.mode)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	b.WriteString("\x1b[3;1H")
	if ui.query != "" {
		b.WriteString("Search: ")
		b.WriteString(ui.query)
	} else {
		b.WriteString("\x1b[2mType to search…")
		b.WriteString(reset)
	}
	b.WriteString(clearEOL)

	row := 5
	if filteredCount == 0 {
		fmt.Fprintf(&b, "\x1b[%d;1H\x1b[2mNo matching commands.%s%s", row, reset, clearEOL)
		row++
	}
	for i := startIndex; i <= endIndex && i < filteredCount; i++ {
		fmt.Fprintf(&b, "\x1b[%d;1H", row)
		r := ui.rows[ui.filtered[i]]
		if i == ui.selected {
			b.WriteString("▶ ")
		} else {
			b.WriteString("  ")
		}
		b.WriteString(r.label)

		// Hotkey hint right-aligned (best-effort; truncation falls back to
		// dropping the hint when the label already crowds the column).
		if r.hotkeyDisplay != "" {
			hint := "[" + r.hotkeyDisplay + "]"
			// Caret + space + label + 2-space gutter + hint
			used := 2 + visibleWidth(r.label) + 2 + visibleWidth(hint)
			if used <= cols {
				pad := cols - used
				for k := 0; k < pad; k++ {
					b.WriteByte(' ')
				}
				b.WriteString("\x1b[2m")
				b.WriteString(hint)
				b.WriteString(reset)
			}
		}
		b.WriteString(clearEOL)
		row++
	}

	// Footer with hint + powered-by badge + latency split (same convention
	// as the attention picker).
	row++
	fmt.Fprintf(&b, "\x1b[%d;1H", row)
	b.WriteString("\x1b[2mEnter run | Up/Down move | Backspace delete | Esc clear/close  ·  powered by ")
	b.WriteString("\x1b[22;1;38;5;108mgo")
	b.WriteString(reset)
	ui.ts.renderFooterTail(&b)
	b.WriteString(clearEOL)
	b.WriteString("\x1b[J")

	_, _ = os.Stdout.WriteString(b.String())

	// Perf event — separate category from attention.perf so perf-trend.sh
	// can filter by panel. Bench fields mirror attention's schema.
	ui.ts.emit("command.perf", "command", "command palette paint timing", paintKind, len(ui.rows), ui.selected, nil)
}

func (ui *commandUI) displayedSelected() int {
	if len(ui.filtered) == 0 {
		return 0
	}
	return ui.selected + 1
}

func (ui *commandUI) renderConfirm() {
	const reset = "\x1b[0m"
	const clearEOL = "\x1b[K"
	var b strings.Builder
	b.WriteString("\x1b[H\x1b[2J")
	b.WriteString("\x1b[1;1H\x1b[1m")
	b.WriteString(ui.pendingConfirm)
	b.WriteString(reset)
	b.WriteString(clearEOL)
	b.WriteString("\x1b[3;1H\x1b[2mPress y to continue, any other key to cancel.")
	b.WriteString(reset)
	b.WriteString(clearEOL)
	_, _ = os.Stdout.WriteString(b.String())
}

// dispatchByID looks up the row by id (post-MRU reorder) and runs the
// command-run.sh bash script synchronously, with stdin/stdout/stderr
// inherited so the failure-prompt branch in run.sh still works. Returns
// true when the dispatch fired (caller exits with 0 in that case).
func (ui *commandUI) dispatchByID(itemID string, fd int, state *term.State) bool {
	if itemID == "" {
		return false
	}
	// Restore termios + show cursor BEFORE shelling out; the deferred
	// Restore in the caller will run again on return but is idempotent.
	_ = term.Restore(fd, state)
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h\x1b[H\x1b[2J")

	cmd := exec.Command("bash", ui.runScript, ui.sessionName, itemID, ui.currentWindow, ui.cwd, ui.clientTTY)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run() // run.sh handles its own status reporting via tmux display-message
	return true
}

func init() { register(commandPicker{}) }
