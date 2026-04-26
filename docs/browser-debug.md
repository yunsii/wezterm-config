# Browser Debug Workflow

Use this doc when you need anything about the headless Chrome debug instance the Windows host helper runs: the four daily paths (auto-start, agent / MCP attach, `chrome://inspect`, manual `Alt+b` / `Alt+Shift+b`), the launch hardening flags, the right-status `CDP·…` badge, or the status-file contract that drives the badge.

The keyboard summary lives in [`keybindings.md#project-navigation`](./keybindings.md#project-navigation); this doc owns the workflow detail.

## The four daily paths

The default day is **headless**: the Windows helper auto-launches a headless Chrome the moment it boots, MCP / agent tools attach without ever surfacing a window, and nothing is allowed to grab the foreground or flash the taskbar. When you actually need to look at the page yourself, you pivot from your default browser through `chrome://inspect` (or `edge://inspect`) — no need to switch the headless instance to visible just to peek.

1. **Daily — auto-start (zero keystrokes)**. Helper boot runs `ReconcileOnStartup` then mode-agnostic detection on `localhost:<remote_debugging_port>` + the configured `user_data_dir`; if any chrome (visible or headless) is already there it adopts the existing PID, otherwise it launches a fresh headless one. The status segment lands on `CDP·H·<port>` immediately. MCP servers in your agent / Claude Code config can stay attached via `--browser-url=http://localhost:<port>` across sessions; nothing depends on you having pressed `Alt+b`.
2. **Programmatic — agent tools and MCP**. With auto-start running, every Chrome DevTools MCP server, every agent that takes `--browser-url=http://localhost:<port>`, and every CDP-aware automation script just connects. The endpoint always answers (you can confirm with `curl -sS http://localhost:<port>/json/version` from any pane in WSL or Windows). The agent never has to wait for a human to "set up" the browser.
3. **Human inspection — `chrome://inspect` from your default browser**. Open your normal Chrome (or Edge / any Chromium) and go to `chrome://inspect/#devices`. Click *Configure…* in the *Discover network targets* row and add `localhost:<remote_debugging_port>` (default `9222`). The headless instance's pages and service workers appear under *Remote Target*; click *inspect* on any one to open the standard DevTools window — Console, Network, Elements, Sources, Performance — fully connected to the headless session your agent is driving. This is the path for "agent broke, let me look at what it sees" and "I need to manually adjust state then hand it back". It works because the launch flags use `--remote-allow-origins=*`, so the WebSocket from `chrome://inspect` is not rejected. The headless instance keeps running afterward; closing the inspector does not change anything in the session.
4. **Manual override — `Alt+b` / `Alt+Shift+b`**. Reserved for the cases where `chrome://inspect` is not enough: `Alt+b` resets the instance to headless (kills any visible chrome on the same port + user_data_dir first, then relaunches headless), `Alt+Shift+b` kills headless and switches to a fully visible chrome (pops a window into the foreground). Use these when the agent flow requires a clean slate, or when `chrome://inspect`'s read-mostly view is not enough and you need a real visible browser window to type in. After either action the right-status badge flips to `CDP·H·<port>` or `CDP·V·<port>` to confirm.

## Auto-start behavior

The Windows helper auto-starts a headless Chrome debug instance the moment it boots (after `ReconcileOnStartup`), so `http://localhost:<remote_debugging_port>` always has a CDP endpoint for MCP / agent tools without requiring `Alt+b` to be pressed first.

- Detection is **mode-agnostic**: any chrome already running on that port + `user_data_dir` is adopted as-is regardless of mode (so a visible session you started yesterday survives helper restarts intact). Only when nothing is running does the helper launch one, and that launch is **always headless** to avoid interrupting whatever app currently owns the foreground.
- Auto-start never steals focus and never writes the WindowReuseService cache (those belong to user-driven `Alt+b`).
- To disable: set `chrome_debug_browser.auto_start = false` in `wezterm-x/local/constants.lua`.
- The `chrome_debug_browser.headless` field still governs the user-driven `Alt+b` path and is independent of auto-start.

## `Alt+b` — headless launch / reuse

Launches or reuses the Chrome debug browser profile from `wezterm-x/local/constants.lua` in headless mode. Pressing it never steals focus or flashes the taskbar; MCP clients attach via `--browser-url=http://localhost:<port>`.

The launch always adds these hardening flags:

- `--remote-allow-origins=*` — covers MCP `http://localhost:<port>` clients and the human-debug path through `chrome://inspect` / `edge://inspect` / `devtools://devtools`. The wildcard is acceptable because Chrome binds the port to 127.0.0.1 and the dedicated `user_data_dir` is not the user's main profile.
- `--disable-extensions`, `--no-first-run`, `--no-default-browser-check`.
- `--headless=new` and `--window-size=1920,1080` — headless defaults to 800×600, which breaks MCP screenshots and viewport-sensitive scrapes.

If a visible-mode Chrome is already holding the same port + `--user-data-dir`, the helper terminates it (entire process tree) before launching headless so the Chrome singleton lock is released — this is the automatic mode switch; `Alt+Shift+b` is the visible-direction companion.

In `hybrid-wsl` this goes through the same Windows native helper path as `Alt+v`. In `posix-local` it stays unavailable until a native host helper exists.

## `Alt+Shift+b` — visible launch / reuse

Launches or reuses the same Chrome debug browser profile in visible (headful) mode for manual acceptance or UI verification. Shares the same `user_data_dir` (cookies, logins, extensions state preserved across mode switches) and same port as `Alt+b`, so only one mode can run at a time.

Pressing this when a headless instance is running will kill that headless first, wait for the `--user-data-dir` singleton lock to release, and start a visible Chrome with the same hardening flags (minus `--headless=new` and `--window-size=1920,1080`, which are headless-only). MCP connections from the previous headless session will drop and can be reestablished on the visible instance. The right-status segment flips to `CDP·V·<port>` after launch.

## Right-status `CDP` badge

The WezTerm right-status renders just to the right of the IME segment as a fixed-width badge. The four states share the same glyph count so the bar width never jitters when you switch modes:

| Badge | Meaning | Style |
|---|---|---|
| `CDP·H·<port>` | headless ready | inactive palette, Normal intensity |
| `CDP·V·<port>` | visible ready | running-attention palette, Bold |
| `CDP·-·<port>` | helper alive but Chrome not running (`mode=none` or `alive=false`; auto-start failed or you killed chrome and have not relaunched). The port falls back to `remote_debugging_port` when no state file exists yet | idle palette, Italic |
| `CDP·?·<port>` | helper itself looks dead — its `state.env` heartbeat is older than `helper_heartbeat_timeout_seconds`, so the chrome state file may be arbitrarily stale and the badge cannot be trusted | warning palette, Italic |

## State file contract

The helper writes the current mode/port/pid/alive to `chrome_debug_browser.state_file` (defaults to `$runtime_state_dir/state/chrome-debug/state.json`) on every successful request, and rewrites it to `mode=none, alive=false` the moment the Chrome process exits.

Liveness detection runs through `ChromeLivenessWatcher`, which subscribes `Process.Exited` plus a 5-second `HasExited` poll fallback, and re-subscribes on helper restart through `ReconcileOnStartup`.

## End-to-end smoke check

```bash
curl -sS http://localhost:<port>/json/version
```

A healthy chain returns a JSON blob with `Browser`, `Protocol-Version`, and `webSocketDebuggerUrl`; that single response confirms helper, chrome, and the inspect path are all live.

If the badge shows `CDP·?·<port>`, run `wezterm-runtime-sync` or restart WezTerm to respawn the helper. See also [`diagnostics.md`](./diagnostics.md) for the runtime-side traceability fields.
