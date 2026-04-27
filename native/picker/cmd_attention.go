// `picker attention` — TUI for the agent-attention overlay (Alt+/).
//
// Receives a prefetch TSV (built upstream by the WezTerm Lua handler /
// tmux-attention-menu.sh) so the picker itself never touches state.json
// or jq. The popup lifecycle is: read TSV → raw mode → first paint →
// key loop → on Enter, fire attention-jump.sh via `tmux run-shell -b`
// (popup tears down before the jump round-trip starts).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

type attentionRow struct {
	status     string // "running" | "waiting" | "done" | "recent" | "__sentinel__"
	body       string
	age        string
	id         string
	lastStatus string // for "recent" rows: "running" | "waiting" | "done"; empty otherwise
}

type attentionPicker struct{}

func (attentionPicker) Name() string { return "attention" }

func (attentionPicker) Run(args []string) int {
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
	ts := parsePerfTimings(args, 2)

	rows, err := loadAttentionRows(prefetchPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "picker: %v\n", err)
		return 1
	}
	if len(rows) == 0 {
		fmt.Fprintln(os.Stderr, "picker: prefetch TSV produced 0 rows")
		return 1
	}

	fd, state, ok := enterRawMode()
	if !ok {
		return 1
	}
	defer restoreRawMode(fd, state)

	// Type-to-filter is always-on (mirrors the command palette); there is
	// no separate "filter mode" to enter. Every printable keystroke goes
	// straight into the substring filter, the search row at line 2 is
	// always visible, and Tab still cycles the orthogonal status filter.
	filterText := ""
	statusFilter := "all" // "all" | "running" | "waiting" | "done"
	selected := 0

	visible := applyAttentionFilter(rows, filterText, statusFilter)

	render := func() {
		renderAttentionFrame(visible, selected, ts, filterText, statusFilter)
	}
	render()
	// Once-per-popup perf event, dispatched AFTER the first frame's bytes
	// hit stdout — see docs/logging-conventions.md "Render-path discipline".
	ts.emitFirstPaint("attention.perf", "attention", "popup paint timing", len(visible), selected, nil)

	cycleStatus := func() {
		switch statusFilter {
		case "all":
			statusFilter = "waiting"
		case "waiting":
			statusFilter = "done"
		case "done":
			statusFilter = "running"
		case "running":
			statusFilter = "all"
		default:
			statusFilter = "all"
		}
		selected = 0
		visible = applyAttentionFilter(rows, filterText, statusFilter)
	}

	return runKeyLoop(func(key string) (loopAction, int) {
		switch key {
		case "\r", "\n":
			if len(visible) == 0 {
				return loopContinue, 0
			}
			dispatchAttention(visible[selected], jumpScript)
			return loopExit, 0
		case "\x1b/", "\x03":
			// Forwarded second Alt+/ and Ctrl+C — unconditional close.
			// Preserves toggle behaviour and gives the user a stable
			// escape hatch even when the filter is non-empty.
			return loopExit, 0
		case "\x1b":
			// Bare Esc: clear filter when non-empty, otherwise close.
			// Matches the command palette's Esc semantics so the user
			// can back out of a search without losing the popup.
			if filterText != "" {
				filterText = ""
				selected = 0
				visible = applyAttentionFilter(rows, filterText, statusFilter)
				render()
				return loopContinue, 0
			}
			return loopExit, 0
		case "\x1b[B", "\x1bOB":
			if len(visible) > 0 {
				selected = (selected + 1) % len(visible)
				render()
			}
		case "\x1b[A", "\x1bOA":
			if len(visible) > 0 {
				selected = (selected - 1 + len(visible)) % len(visible)
				render()
			}
		case "\t":
			cycleStatus()
			render()
		case "\x7f", "\x08":
			if filterText != "" {
				filterText = filterText[:len(filterText)-1]
				selected = 0
				visible = applyAttentionFilter(rows, filterText, statusFilter)
				render()
			}
		case "\x15": // Ctrl+U — clear filter in one keystroke.
			if filterText != "" {
				filterText = ""
				selected = 0
				visible = applyAttentionFilter(rows, filterText, statusFilter)
				render()
			}
		default:
			// Append printable ASCII only (single byte 0x20–0x7E). Stray
			// escape sequences or multi-byte input is ignored so it
			// cannot pollute the filter string.
			if len(key) == 1 {
				c := key[0]
				if c >= 0x20 && c <= 0x7E {
					filterText += key
					selected = 0
					visible = applyAttentionFilter(rows, filterText, statusFilter)
					render()
				}
			}
		}
		return loopContinue, 0
	})
}

// applyAttentionFilter returns the subset of rows that pass the current
// filter. The clear-all sentinel is included only when both filter
// dimensions are at their defaults (empty text + "all" status) — the
// sentinel is a meta action and the user typing/cycling clearly excludes
// it from intent.
func applyAttentionFilter(rows []attentionRow, filterText, statusFilter string) []attentionRow {
	filterActive := filterText != "" || statusFilter != "all"
	lowerFilter := strings.ToLower(filterText)
	out := make([]attentionRow, 0, len(rows))
	for _, r := range rows {
		if r.status == "__sentinel__" {
			if filterActive {
				continue
			}
			out = append(out, r)
			continue
		}
		if statusFilter != "all" && r.status != statusFilter {
			continue
		}
		if filterText != "" {
			if !strings.Contains(strings.ToLower(r.body), lowerFilter) {
				continue
			}
		}
		out = append(out, r)
	}
	return out
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
		parts := strings.SplitN(line, "\t", 5)
		if len(parts) < 4 {
			continue
		}
		row := attentionRow{
			status: parts[0],
			body:   parts[1],
			age:    parts[2],
			id:     parts[3],
		}
		if len(parts) >= 5 {
			row.lastStatus = parts[4]
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// renderAttentionFrame mirrors scripts/runtime/tmux-attention/render.sh's
// `attention_picker_emit_frame` byte-for-byte: same ANSI positioning,
// same color codes, same selection highlight scheme. If you change
// either, change both — the bash menu.sh side still pre-renders the
// first frame for the bash fallback path.
func renderAttentionFrame(rows []attentionRow, selected int, ts perfTimings, filterText, statusFilter string) {
	_, lines := getTermSize()
	// 5 non-row lines: title, search input, blank divider, blank-before-
	// footer, footer.
	visibleRows := lines - 5
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

	// Title row. The substring filter has its own search row below; the
	// title only shows count + (when active) the status filter chip.
	titleN := selected + 1
	if itemCount == 0 {
		titleN = 0
	}
	b.WriteString("\x1b[1;1H\x1b[1m")
	fmt.Fprintf(&b, "Agent attention — %d/%d", titleN, itemCount)
	if statusFilter == "all" {
		b.WriteString("  ·  order matches status bar (⚠ → ✓ → ⟳)")
		b.WriteString(reset)
	} else {
		b.WriteString(reset)
		switch statusFilter {
		case "running":
			b.WriteString("  \x1b[1;38;5;39m[⟳ running]")
			b.WriteString(reset)
		case "waiting":
			b.WriteString("  \x1b[1;38;5;208m[⚠ waiting]")
			b.WriteString(reset)
		case "done":
			b.WriteString("  \x1b[38;5;108m[✓ done]")
			b.WriteString(reset)
		}
	}
	b.WriteString(clearEOL)

	// Search row at line 2 — always visible (command-palette style). Empty
	// state shows a dim placeholder so the affordance is discoverable.
	cursor := "\x1b[7m \x1b[27m"
	if filterText != "" {
		fmt.Fprintf(&b, "\x1b[2;1HSearch: %s%s", filterText, cursor)
	} else {
		fmt.Fprintf(&b, "\x1b[2;1H\x1b[2mSearch: %s\x1b[2m Type to filter (Tab cycles status)…%s", cursor, reset)
	}
	b.WriteString(clearEOL)

	// Item rows start at row 4 (row 1 = title, row 2 = search, row 3 =
	// blank divider).
	row := 4
	if itemCount == 0 {
		fmt.Fprintf(&b, "\x1b[%d;1H\x1b[2mNo matches — Esc clears search, Tab cycles status, Backspace edits.%s%s", row, reset, clearEOL)
		row++
	}
	for i := startIndex; i <= endIndex; i++ {
		fmt.Fprintf(&b, "\x1b[%d;1H", row)
		r := rows[i]
		// Only the leading caret distinguishes selected from unselected;
		// everything else (badge color, body, dim age) renders identically.
		// The 2-col gutter is reserved on every row so column alignment
		// stays stable as the cursor moves.
		if i == selected {
			b.WriteString("▶ ")
		} else {
			b.WriteString("  ")
		}
		b.WriteString(coloredBadge(r.status))
		b.WriteString("  ")
		b.WriteString(r.body)
		if r.age != "" {
			b.WriteString("  \x1b[2m(")
			b.WriteString(r.age)
			b.WriteString(")")
			b.WriteString(reset)
		}
		// Recent rows carry the prior live status as a dim suffix so the
		// user can tell at a glance what the entry was doing when it was
		// archived (e.g. an unfinished waiting prompt vs a clean done).
		if r.status == "recent" && r.lastStatus != "" {
			fmt.Fprintf(&b, "  \x1b[2m(%s, archived)%s", r.lastStatus, reset)
		}
		b.WriteString(clearEOL)
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
	//
	// The blank divider row must be explicitly cleared: when a previous
	// frame had a smaller item count its footer landed where this frame's
	// divider lives, and the trailing `\x1b[J` only wipes lines BELOW the
	// new footer. Without this `\x1b[K` the old footer ghosts through.
	fmt.Fprintf(&b, "\x1b[%d;1H%s", row, clearEOL)
	row++
	fmt.Fprintf(&b, "\x1b[%d;1H", row)
	b.WriteString("\x1b[2mEnter jump | Up/Down move | type filter | Tab status | Esc clear/close  ·  powered by ")
	b.WriteString("\x1b[22;1;38;5;108mgo")
	b.WriteString(reset)
	ts.renderFooterTail(&b)
	b.WriteString(clearEOL)

	// Wipe anything still drawn below the footer (e.g. stale content from
	// a taller previous frame in the same popup pty).
	b.WriteString("\x1b[J")

	_, _ = os.Stdout.WriteString(b.String())
}

func coloredBadge(status string) string {
	switch status {
	case "running":
		return "\x1b[1;38;5;39m⟳ RUN \x1b[0m"
	case "waiting":
		return "\x1b[1;38;5;208m⚠ WAIT\x1b[0m"
	case "done":
		return "\x1b[38;5;108m✓ DONE\x1b[0m"
	case "recent":
		return "\x1b[2;38;5;245m💬 RCNT\x1b[0m"
	case "__sentinel__":
		return "\x1b[1;38;5;160m✗ CLR \x1b[0m"
	}
	return "· ----"
}

func dispatchAttention(r attentionRow, jumpScript string) {
	// Restore termios + show cursor BEFORE shelling out to tmux so the
	// popup pty cleans up cleanly even if tmux's run-shell has any
	// observable side effect on the parent fd state.
	_, _ = os.Stdout.WriteString("\x1b[0m\x1b[?25h")

	var cmd string
	switch {
	case r.id == "__clear_all__":
		cmd = fmt.Sprintf("bash %s --clear-all", shellEscape(jumpScript))
	case strings.HasPrefix(r.id, "recent::"):
		// Encoded by tmux-attention-menu.sh as "recent::<sid>::<archived_ts>".
		// Split into the two pieces so the jump script can disambiguate
		// multiple recent rows that share a session_id (same agent
		// archived from different panes).
		rest := strings.TrimPrefix(r.id, "recent::")
		sid, archived, _ := strings.Cut(rest, "::")
		if archived == "" {
			cmd = fmt.Sprintf("bash %s --recent --session %s",
				shellEscape(jumpScript), shellEscape(sid))
		} else {
			cmd = fmt.Sprintf("bash %s --recent --session %s --archived-ts %s",
				shellEscape(jumpScript), shellEscape(sid), shellEscape(archived))
		}
	default:
		cmd = fmt.Sprintf("bash %s --session %s", shellEscape(jumpScript), shellEscape(r.id))
	}
	// `tmux run-shell -b` returns immediately; the popup tears down
	// before attention-jump.sh starts the WezTerm cli round-trip, so
	// the user perceives the jump as instant.
	_ = exec.Command("tmux", "run-shell", "-b", cmd).Run()
}

func init() { register(attentionPicker{}) }
