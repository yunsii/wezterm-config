// log.go — perf-event emitter shared by every picker.
//
// Mirrors `runtime_log_emit` from scripts/runtime/runtime-log-lib.sh:
// same field-quoting semantics, same `WEZTERM_RUNTIME_LOG_*` env knobs,
// same destination file. Only the level filter is fixed at "info" —
// the picker has no debug/warn/error perf events to emit.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func emitPerfEvent(category, message string, fields map[string]string) {
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
