#!/bin/sh

# Best-effort launcher for Alt+b in posix-local. It always starts the configured
# debug browser profile, and on common desktops it first tries to focus an
# existing matching browser window.

chrome_path=$1
remote_debugging_port=$2
user_data_dir=$3

if [ -z "$chrome_path" ]; then
  echo "Alt+b launcher: missing chrome_path" >&2
  exit 1
fi

if [ -z "$remote_debugging_port" ]; then
  echo "Alt+b launcher: missing remote_debugging_port" >&2
  exit 1
fi

matching_process_running() {
  if ! command -v pgrep >/dev/null 2>&1; then
    return 1
  fi

  pgrep -f -- "$chrome_path.*--remote-debugging-port=$remote_debugging_port" >/dev/null 2>&1
}

focus_existing_window() {
  case "$(uname -s)" in
    Darwin)
      if command -v osascript >/dev/null 2>&1; then
        osascript -e 'tell application "Google Chrome" to activate' >/dev/null 2>&1 && return 0
      fi
      ;;
    Linux)
      if [ -n "$DISPLAY" ] && command -v wmctrl >/dev/null 2>&1; then
        wmctrl -xa "google-chrome.Google-chrome" >/dev/null 2>&1 && return 0
        wmctrl -a "Google Chrome" >/dev/null 2>&1 && return 0
      fi
      ;;
  esac

  return 1
}

if matching_process_running && focus_existing_window; then
  exit 0
fi

if [ -n "$user_data_dir" ]; then
  "$chrome_path" \
    "--remote-debugging-port=$remote_debugging_port" \
    "--user-data-dir=$user_data_dir" >/dev/null 2>&1 &
else
  "$chrome_path" \
    "--remote-debugging-port=$remote_debugging_port" >/dev/null 2>&1 &
fi
