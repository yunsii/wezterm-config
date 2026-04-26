// `picker links` — TUI for the vscode-links project-link picker.
//
// Same shape as cmd_command.go: an upstream launcher (links-menu.sh)
// runs the `vscode-links resolve --format tsv` for the current pane
// cwd into a prefetch file, then shells `tmux display-popup -E
// "picker links <prefetch_tsv> <dispatch_script>"`. This binary owns
// everything from popup-pty entry through dispatch.
//
// Each row: type \t source \t url \t title.
//   type   ∈ local | detected | remote-project | remote-shared
//   source detected:github | csv:project | csv:#shared-links | settings:links.resources | …
//   url    fully-rendered URL (no `{{...}}` placeholders)
//   title  human-friendly label
//
// Bindings:
//   Enter    → dispatch OPEN <url>
//   Ctrl+Y   → dispatch COPY <url>
//   Up/Down  → move
//   Backspace / Ctrl+U → edit search
//   Esc      → clear query first, then close (mirrors cmd_command)
//   Ctrl+C   → close

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"golang.org/x/term"
)

type linkRow struct {
	linkType string // local | detected | remote-project | remote-shared
	source   string
	url      string
	title    string
}

type linksUI struct {
	rows           []linkRow
	query          string
	filtered       []int
	selected       int
	dispatchScript string
	cwd            string
	keypressTS     int64
	menuStartTS    int64
	menuDoneTS     int64
}

func runLinks(args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: picker links <prefetch_tsv> <dispatch_script> [cwd] [keypress_ts] [menu_start_ts] [menu_done_ts]")
		return 2
	}
	prefetchPath := args[0]
	dispatchScript := args[1]

	cwd := ""
	if len(args) > 2 {
		cwd = args[2]
	}
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
	keypressTS := parseTS(3)
	menuStartTS := parseTS(4)
	menuDoneTS := parseTS(5)

	rows, diagnostics, err := loadLinkRows(prefetchPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: %v\n", err)
		return 1
	}
	if len(rows) == 0 {
		// Surface why no rows arrived; the launcher can attach diagnostic
		// lines as `# <message>` comments at the top of the prefetch.
		if len(diagnostics) > 0 {
			fmt.Fprintln(os.Stderr, "picker: no links resolved")
			for _, d := range diagnostics {
				fmt.Fprintf(os.Stderr, "  %s\n", d)
			}
		} else {
			fmt.Fprintln(os.Stderr, "picker: prefetch produced 0 link rows")
		}
		fmt.Fprint(os.Stderr, "press any key to close...")
		// Drop into raw mode briefly so the keypress is consumed without echo.
		fd := int(os.Stdin.Fd())
		state, _ := term.MakeRaw(fd)
		buf := make([]byte, 1)
		_, _ = os.Stdin.Read(buf)
		if state != nil {
			_ = term.Restore(fd, state)
		}
		return 0
	}

	fd := int(os.Stdin.Fd())
	state, err := term.MakeRaw(fd)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: MakeRaw: %v\n", err)
		return 1
	}
	defer func() {
		_ = term.Restore(fd, state)
		_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")
	}()
	_, _ = os.Stdout.WriteString("\x1b[?25l")

	ui := &linksUI{
		rows:           rows,
		dispatchScript: dispatchScript,
		cwd:            cwd,
		keypressTS:     keypressTS,
		menuStartTS:    menuStartTS,
		menuDoneTS:     menuDoneTS,
	}
	ui.refilter()
	ui.render("first")

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
			if len(ui.filtered) == 0 {
				continue
			}
			row := ui.rows[ui.filtered[ui.selected]]
			if ui.dispatch(row, "OPEN", fd, state) {
				return 0
			}
		case "\x19": // Ctrl+Y
			if len(ui.filtered) == 0 {
				continue
			}
			row := ui.rows[ui.filtered[ui.selected]]
			if ui.dispatch(row, "COPY", fd, state) {
				return 0
			}
		case "\x03":
			return 0
		case "\x1b":
			if ui.query != "" {
				ui.query = ""
				ui.refilter()
				ui.render("repaint")
				continue
			}
			return 0
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
	}
}

// loadLinkRows parses the prefetch TSV. Lines beginning with `#` are
// treated as diagnostics (returned separately so the empty-list path
// can show them); all other lines must have at least 4 tab fields.
func loadLinkRows(path string) ([]linkRow, []string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("read prefetch %s: %w", path, err)
	}
	var rows []linkRow
	var diags []string
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			diags = append(diags, strings.TrimSpace(strings.TrimPrefix(line, "#")))
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) < 4 {
			continue
		}
		rows = append(rows, linkRow{
			linkType: parts[0],
			source:   parts[1],
			url:      parts[2],
			title:    parts[3],
		})
	}
	return rows, diags, nil
}

func (ui *linksUI) refilter() {
	q := strings.ToLower(ui.query)
	ui.filtered = ui.filtered[:0]
	for i, r := range ui.rows {
		if q == "" {
			ui.filtered = append(ui.filtered, i)
			continue
		}
		// Substring across title + url + source + type — same shape as
		// command palette's haystack.
		if strings.Contains(strings.ToLower(r.title+" "+r.url+" "+r.source+" "+r.linkType), q) {
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

func (ui *linksUI) move(delta int) {
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

func (ui *linksUI) render(paintKind string) {
	cols, lines, err := term.GetSize(int(os.Stdout.Fd()))
	if err != nil || cols < 1 {
		cols = 80
	}
	if lines < 1 {
		lines = 24
	}
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

	// Header.
	b.WriteString("\x1b[1;1H\x1b[1m")
	fmt.Fprintf(&b, "Links — %d/%d", ui.displayedSelected(), filteredCount)
	b.WriteString(reset)
	b.WriteString(clearEOL)

	// cwd row (dim).
	b.WriteString("\x1b[2;1H\x1b[2m")
	if ui.cwd != "" {
		fmt.Fprintf(&b, "cwd: %s", ui.cwd)
	}
	b.WriteString(reset)
	b.WriteString(clearEOL)

	// Search row.
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
		fmt.Fprintf(&b, "\x1b[%d;1H\x1b[2mNo matching links.%s%s", row, reset, clearEOL)
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
		// Title in default weight; URL right-aligned in dim. Cap title
		// at half the column count so even pathological titles still
		// leave room for the URL.
		title := r.title
		maxTitle := cols/2 - 4
		if maxTitle < 8 {
			maxTitle = 8
		}
		if visibleWidth(title) > maxTitle {
			title = title[:maxTitle-1] + "…"
		}
		b.WriteString(title)

		used := 2 + visibleWidth(title)
		urlHint := r.url
		urlHintW := visibleWidth(urlHint)
		if used+2+urlHintW > cols {
			// Trim URL from the left until it fits.
			over := used + 2 + urlHintW - cols
			if over < urlHintW-1 {
				urlHint = "…" + urlHint[over+1:]
				urlHintW = visibleWidth(urlHint)
			} else {
				urlHint = ""
				urlHintW = 0
			}
		}
		if urlHintW > 0 {
			pad := cols - used - urlHintW
			for k := 0; k < pad; k++ {
				b.WriteByte(' ')
			}
			b.WriteString("\x1b[2m")
			b.WriteString(urlHint)
			b.WriteString(reset)
		}
		b.WriteString(clearEOL)
		row++
	}

	// Footer.
	row++
	fmt.Fprintf(&b, "\x1b[%d;1H", row)
	b.WriteString("\x1b[2mEnter open · Ctrl+y copy · Up/Down move · Backspace delete · Esc clear/close  ·  powered by ")
	b.WriteString("\x1b[22;1;38;5;108mgo")
	b.WriteString(reset)

	var elapsed, lua, menu, picker int64
	if ui.keypressTS > 0 {
		nowMs := time.Now().UnixMilli()
		elapsed = nowMs - ui.keypressTS
		if elapsed < 0 {
			elapsed = 0
		}
		if ui.menuStartTS > 0 && ui.menuDoneTS > 0 {
			lua = ui.menuStartTS - ui.keypressTS
			menu = ui.menuDoneTS - ui.menuStartTS
			picker = nowMs - ui.menuDoneTS
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
	b.WriteString("\x1b[J")

	_, _ = os.Stdout.WriteString(b.String())

	if ui.keypressTS > 0 {
		emitPerfEvent("links.perf", "links picker paint timing", map[string]string{
			"paint_kind":     paintKind,
			"picker_kind":    "go",
			"panel":          "links",
			"total_ms":       strconv.FormatInt(elapsed, 10),
			"lua_ms":         strconv.FormatInt(lua, 10),
			"menu_ms":        strconv.FormatInt(menu, 10),
			"picker_ms":      strconv.FormatInt(picker, 10),
			"item_count":     strconv.Itoa(len(ui.rows)),
			"selected_index": strconv.Itoa(ui.selected),
		})
	}
}

func (ui *linksUI) displayedSelected() int {
	if len(ui.filtered) == 0 {
		return 0
	}
	return ui.selected + 1
}

// dispatch shells out to the dispatch script with the chosen action
// and URL. Restores termios first so the script can use stdio if it
// wants, mirroring cmd_command's pattern.
func (ui *linksUI) dispatch(row linkRow, action string, fd int, state *term.State) bool {
	_ = term.Restore(fd, state)
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")

	cmd := exec.Command("bash", ui.dispatchScript, action, row.url, row.title)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
	return true
}
