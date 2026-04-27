// wezbus.go — Go-side producer for the wezterm event bus.
//
// Mirrors the bash implementation in scripts/runtime/wezterm-event-lib.sh.
// Picker is always invoked from inside a tmux popup pty, where DCS
// pass-through to the parent client tty is unreliable, so file is the
// default transport and the menu wrapper sets WEZTERM_EVENT_FORCE_FILE=1
// to make that explicit. The OSC branch is kept for symmetry and for
// override / future scenarios where the picker (or another Go-side
// producer) runs outside a popup.
//
// Transport selection (auto unless overridden):
//   ① $WEZTERM_EVENT_TRANSPORT=osc|file
//   ② $WEZTERM_EVENT_FORCE_FILE=1
//   ③ /dev/tty writable → osc, otherwise file
//
// Event dir resolution prefers $WEZBUS_EVENT_DIR (injected by the menu
// wrapper) so the picker doesn't have to redo the wezterm-runtime path
// detection that the bash side already did.
package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func wezbusPickTransport() string {
	switch os.Getenv("WEZTERM_EVENT_TRANSPORT") {
	case "osc":
		return "osc"
	case "file":
		return "file"
	}
	if os.Getenv("WEZTERM_EVENT_FORCE_FILE") != "" {
		return "file"
	}
	if f, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0); err == nil {
		_ = f.Close()
		return "osc"
	}
	return "file"
}

func wezbusUserVarName(name string) string {
	return "we_" + strings.ReplaceAll(name, ".", "_")
}

func wezbusEventDir() string {
	if v := os.Getenv("WEZBUS_EVENT_DIR"); v != "" {
		return v
	}
	// Fallback: Linux XDG path. Picker should normally have the env
	// injected by the menu wrapper, so this branch is just defensive.
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		if home, err := os.UserHomeDir(); err == nil {
			state = filepath.Join(home, ".local", "state")
		}
	}
	return filepath.Join(state, "wezterm-runtime", "state", "wezterm-events")
}

func wezbusSendOSC(name, payload string) error {
	encoded := base64.StdEncoding.EncodeToString([]byte(payload))
	seq := fmt.Sprintf("\x1b]1337;SetUserVar=%s=%s\x07", wezbusUserVarName(name), encoded)
	if os.Getenv("TMUX") != "" {
		seq = "\x1bPtmux;" + strings.ReplaceAll(seq, "\x1b", "\x1b\x1b") + "\x1b\\"
	}
	f, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(seq)
	return err
}

func wezbusSendFile(name, payload string) error {
	dir := wezbusEventDir()
	if dir == "" {
		return fmt.Errorf("wezbus: no event dir resolved")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	target := filepath.Join(dir, name+".json")
	tmp := target + ".tmp"
	body := fmt.Sprintf("{\"version\":1,\"name\":%q,\"payload\":%q,\"ts\":%d}\n",
		name, payload, time.Now().UnixMilli())
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// wezbusSend is the public producer entry point. Returns the chosen
// transport ("osc" / "file") plus any error from the send. Callers
// typically log the transport so the diagnostic trail shows which
// branch was taken.
func wezbusSend(name, payload string) (string, error) {
	transport := wezbusPickTransport()
	switch transport {
	case "osc":
		return transport, wezbusSendOSC(name, payload)
	default:
		return transport, wezbusSendFile(name, payload)
	}
}
