using System.Diagnostics;
using System.Text.Json;
using System.Threading;

namespace WezTerm.WindowsHostHelper;

internal sealed class ChromeRequestHandler
{
    private readonly StructuredLogger logger;
    private readonly WindowReuseService windowReuseService;

    public ChromeRequestHandler(StructuredLogger logger, WindowReuseService windowReuseService)
    {
        this.logger = logger;
        this.windowReuseService = windowReuseService;
    }

    // Builds the LaunchMatchSpec used to find an existing debug chrome by
    // command-line. When `requireHeadless` is null the spec matches any
    // running mode (used by AutoStart, which only cares that *some* chrome
    // already serves the configured port + user-data-dir, headless or not).
    // When non-null the spec enforces equality with --headless on the cmdline,
    // which is what FocusOrStart needs so it can distinguish "current mode is
    // already correct" from "stale instance to kill".
    private static LaunchMatchSpec BuildChromeMatchSpec(
        string chromePath,
        int port,
        string userDataDir,
        bool? requireHeadless,
        string launchKeySuffix)
    {
        var chromeProcessName = PathResolvers.GetProcessNameFromExecutable(chromePath, "chrome");
        var launchKey = PathResolvers.BuildChromeCacheKey(port, userDataDir) + launchKeySuffix;
        var normalizedUserDataDir = PathResolvers.NormalizeWindowsPath(userDataDir);
        return new LaunchMatchSpec(
            InstanceType: "chrome",
            LaunchKey: launchKey,
            ProcessName: chromeProcessName,
            CommandLineMatcher: commandLine =>
            {
                if (!commandLine.Contains($"--remote-debugging-port={port}", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (!PathResolvers.NormalizeWindowsPath(commandLine).Contains(normalizedUserDataDir, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (requireHeadless is null)
                {
                    return true;
                }
                var processIsHeadless = commandLine.Contains("--headless", StringComparison.OrdinalIgnoreCase);
                return processIsHeadless == requireHeadless.Value;
            },
            ReuseMode: ReuseMode.PreferReuse);
    }

    public RequestOutcome FocusOrStart(JsonElement payload, string traceId)
    {
        var chromePath = RequestPayloadReader.RequireString(payload, "chrome_path");
        var port = RequestPayloadReader.RequireInt(payload, "remote_debugging_port");
        var userDataDir = RequestPayloadReader.RequireString(payload, "user_data_dir");
        var headless = RequestPayloadReader.GetOptionalBool(payload, "headless");
        var stateFile = RequestPayloadReader.GetOptionalString(payload, "state_file");
        var modeSuffix = headless ? ":headless" : ":visible";
        var chromeProcessName = PathResolvers.GetProcessNameFromExecutable(chromePath, "chrome");
        var launchKey = PathResolvers.BuildChromeCacheKey(port, userDataDir) + modeSuffix;
        var normalizedUserDataDir = PathResolvers.NormalizeWindowsPath(userDataDir);
        var matchSpec = new LaunchMatchSpec(
            InstanceType: "chrome",
            LaunchKey: launchKey,
            ProcessName: chromeProcessName,
            CommandLineMatcher: commandLine =>
            {
                if (!commandLine.Contains($"--remote-debugging-port={port}", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (!PathResolvers.NormalizeWindowsPath(commandLine).Contains(normalizedUserDataDir, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                var processIsHeadless = commandLine.Contains("--headless", StringComparison.OrdinalIgnoreCase);
                return processIsHeadless == headless;
            },
            ReuseMode: ReuseMode.PreferReuse);

        var staleSpec = new LaunchMatchSpec(
            InstanceType: "chrome",
            LaunchKey: launchKey + ":stale",
            ProcessName: chromeProcessName,
            CommandLineMatcher: commandLine =>
            {
                if (!commandLine.Contains($"--remote-debugging-port={port}", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (!PathResolvers.NormalizeWindowsPath(commandLine).Contains(normalizedUserDataDir, StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                var processIsHeadless = commandLine.Contains("--headless", StringComparison.OrdinalIgnoreCase);
                return processIsHeadless != headless;
            },
            ReuseMode: ReuseMode.PreferReuse);
        var staleProcessIds = WindowQuery.FindMatchingProcessIds(staleSpec);
        if (staleProcessIds.Count > 0)
        {
            foreach (var stalePid in staleProcessIds)
            {
                try
                {
                    using var proc = Process.GetProcessById(stalePid);
                    proc.Kill(entireProcessTree: true);
                    proc.WaitForExit(3000);
                }
                catch
                {
                }
            }
            Thread.Sleep(500);
            logger.Info("chrome", "killed stale chrome instances for mode switch", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["port"] = port.ToString(),
                ["killed_pids"] = WindowQuery.FormatProcessIds(staleProcessIds),
                ["target_mode"] = headless ? "headless" : "visible",
            });
        }

        var initialForeground = WindowQuery.GetForegroundWindowInfo();
        var existingVisibleWindowHandles = WindowQuery.CaptureVisibleProcessWindowHandles(chromeProcessName);

        var reuseDecision = windowReuseService.EvaluateReuse(matchSpec, initialForeground, 1000);
        logger.Info("chrome", "evaluated chrome reuse candidates", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["launch_key"] = launchKey,
            ["reuse_mode"] = matchSpec.ReuseMode.ToString(),
            ["registry_hit"] = reuseDecision.RegistryHit ? "1" : "0",
            ["matched_process_count"] = reuseDecision.MatchedProcessCount.ToString(),
            ["matched_process_ids"] = WindowQuery.FormatProcessIds(reuseDecision.MatchedProcessIds),
            ["matched_window_found"] = reuseDecision.MatchedWindowFound ? "1" : "0",
            ["decision_path"] = reuseDecision.Path,
            ["existing_visible_window_count"] = existingVisibleWindowHandles.Count.ToString(),
            ["normalized_user_data_dir"] = normalizedUserDataDir,
            ["port"] = port.ToString(),
            ["headless"] = headless ? "1" : "0",
        });
        if (reuseDecision.Window != null)
        {
            logger.Info("chrome", "focused cached debug chrome window", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["launch_key"] = launchKey,
                ["pid"] = reuseDecision.Window.ProcessId.ToString(),
                ["hwnd"] = reuseDecision.Window.WindowHandle.ToInt64().ToString(),
                ["port"] = port.ToString(),
                ["user_data_dir"] = userDataDir,
                ["decision_path"] = reuseDecision.Path,
            });
            WriteState(logger, stateFile, traceId, headless, port, reuseDecision.Window.ProcessId, "reused");
            ChromeLivenessWatcher.Track(logger, stateFile, reuseDecision.Window.ProcessId, port, headless, traceId);
            return new RequestOutcome(
                Domain: "chrome",
                Action: "focus_or_start",
                Status: "reused",
                DecisionPath: reuseDecision.Path,
                ResultType: "window_ref",
                Result: new HelperWindowRefResult
                {
                    Pid = reuseDecision.Window.ProcessId,
                    Hwnd = reuseDecision.Window.WindowHandle.ToInt64(),
                },
                ProcessId: reuseDecision.Window.ProcessId,
                WindowHandle: reuseDecision.Window.WindowHandle.ToInt64());
        }

        if (headless && reuseDecision.MatchedProcessIds.Count > 0)
        {
            var reusedPid = reuseDecision.MatchedProcessIds[0];
            logger.Info("chrome", "reused headless debug chrome process", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["launch_key"] = launchKey,
                ["pid"] = reusedPid.ToString(),
                ["port"] = port.ToString(),
                ["user_data_dir"] = userDataDir,
            });
            WriteState(logger, stateFile, traceId, headless, port, reusedPid, "reused");
            ChromeLivenessWatcher.Track(logger, stateFile, reusedPid, port, headless, traceId);
            return new RequestOutcome(
                Domain: "chrome",
                Action: "focus_or_start",
                Status: "reused",
                DecisionPath: "reused_headless_no_window",
                ProcessId: reusedPid);
        }

        var launchArgs = new List<string>
        {
            $"--remote-debugging-port={port}",
            $"--user-data-dir={userDataDir}",
            // Allow any origin so the human-debug path through chrome://inspect
            // (or edge://inspect, devtools://devtools, etc.) can WebSocket-attach
            // when the user wants to interactively inspect the headless instance.
            // Acceptable in this local-dev scenario because Chrome binds the
            // remote-debugging port to 127.0.0.1 -- the surface is limited to
            // tabs running on the same machine, and the user-data-dir is a
            // dedicated debug profile, not their main browsing data.
            "--remote-allow-origins=*",
            "--disable-extensions",
            "--no-first-run",
            "--no-default-browser-check",
        };
        if (headless)
        {
            launchArgs.Add("--headless=new");
            launchArgs.Add("--window-size=1920,1080");
        }
        WindowActivator.LaunchDetachedProcess(chromePath, launchArgs);
        logger.Info("chrome", "launched debug chrome", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["chrome_path"] = chromePath,
            ["port"] = port.ToString(),
            ["user_data_dir"] = userDataDir,
            ["headless"] = headless ? "1" : "0",
            ["decision_path"] = "launch",
        });

        if (headless)
        {
            // Headless Chrome has no window to bind, so resolve the actual
            // chrome.exe pid via command-line matching. Without this, the
            // state file's `pid` field is null and ChromeLivenessWatcher
            // cannot subscribe Process.Exited.
            var headlessPids = WindowQuery.WaitForMatchingProcessIds(matchSpec, 4000);
            int? headlessPid = headlessPids.Count > 0 ? headlessPids[0] : null;
            logger.Info("chrome", "resolved headless chrome pid", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["launch_key"] = launchKey,
                ["pid"] = headlessPid?.ToString(),
                ["matched_count"] = headlessPids.Count.ToString(),
                ["port"] = port.ToString(),
            });
            WriteState(logger, stateFile, traceId, headless, port, headlessPid, "launched");
            if (headlessPid is int pid)
            {
                ChromeLivenessWatcher.Track(logger, stateFile, pid, port, headless, traceId);
            }
            return new RequestOutcome(
                Domain: "chrome",
                Action: "focus_or_start",
                Status: "launched",
                DecisionPath: "launch_headless",
                ProcessId: headlessPid);
        }

        var launchedWindow = WindowQuery.WaitForWindowForMatchingProcessIds(matchSpec, 4000);
        launchedWindow ??= WindowQuery.WaitForForegroundProcessWindow(chromeProcessName, initialForeground, 4000);
        launchedWindow ??= WindowQuery.WaitForNewProcessWindow(chromeProcessName, existingVisibleWindowHandles, 4000);
        if (launchedWindow != null)
        {
            WindowActivator.TryActivateWindow(launchedWindow);
            windowReuseService.RememberWindow("chrome", launchKey, launchedWindow);
            var boundPidWasPreexisting = reuseDecision.MatchedProcessIds.Contains(launchedWindow.ProcessId);
            var decisionPath = existingVisibleWindowHandles.Contains(launchedWindow.WindowHandle)
                ? "launch_bind_existing_visible_window"
                : "launch_bind_new_visible_window";
            logger.Info("chrome", "bound launched debug chrome window", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["launch_key"] = launchKey,
                ["pid"] = launchedWindow.ProcessId.ToString(),
                ["hwnd"] = launchedWindow.WindowHandle.ToInt64().ToString(),
                ["port"] = port.ToString(),
                ["user_data_dir"] = userDataDir,
                ["decision_path"] = decisionPath,
                ["bound_pid_was_preexisting"] = boundPidWasPreexisting ? "1" : "0",
            });
            WriteState(logger, stateFile, traceId, headless, port, launchedWindow.ProcessId, boundPidWasPreexisting ? "launch_handoff_existing" : "launched");
            ChromeLivenessWatcher.Track(logger, stateFile, launchedWindow.ProcessId, port, headless, traceId);
            return new RequestOutcome(
                Domain: "chrome",
                Action: "focus_or_start",
                Status: boundPidWasPreexisting ? "launch_handoff_existing" : "launched",
                DecisionPath: decisionPath,
                ResultType: "window_ref",
                Result: new HelperWindowRefResult
                {
                    Pid = launchedWindow.ProcessId,
                    Hwnd = launchedWindow.WindowHandle.ToInt64(),
                },
                ProcessId: launchedWindow.ProcessId,
                WindowHandle: launchedWindow.WindowHandle.ToInt64());
        }

        logger.Warn("chrome", "launched debug chrome but did not bind a reusable window", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["launch_key"] = launchKey,
            ["port"] = port.ToString(),
            ["user_data_dir"] = userDataDir,
            ["decision_path"] = "launch_unbound",
        });
        return new RequestOutcome(
            Domain: "chrome",
            Action: "focus_or_start",
            Status: "launched",
            DecisionPath: "launch_unbound");
    }

    // Helper-driven auto-start: invoked once at HostHelperManager.Run() after
    // ReconcileOnStartup, so 9222 always has a CDP endpoint without the user
    // having to press Alt+b. Differs from FocusOrStart on three points by
    // design:
    //   * Mode-agnostic detection: any chrome on the right port + user-data-dir
    //     is fine; we don't kill a visible instance just because the configured
    //     default is headless. The user can always switch via Alt+b/Alt+Shift+b.
    //   * Never activates a window. Helper boot is a background event; popping
    //     a Chrome window to the foreground at startup would be intrusive.
    //   * Never writes the WindowReuseService cache. That cache reflects "the
    //     window the user last invoked"; auto-start has no user intent.
    // Auto-start always launches headless (when launching). Adopting an
    // already-running visible chrome is fine (we record its actual mode so
    // the status segment matches reality), but we never spin up a visible
    // window on our own -- that would be intrusive on helper boot.
    public static void AutoStart(
        StructuredLogger logger,
        string chromePath,
        int port,
        string userDataDir,
        string? stateFile)
    {
        const string traceId = "auto_start";
        const bool launchHeadless = true;

        if (string.IsNullOrWhiteSpace(chromePath))
        {
            logger.Warn("chrome", "auto-start skipped: chrome_path empty", new Dictionary<string, string?>
            {
                ["port"] = port.ToString(),
            });
            return;
        }

        // Only validate existence for rooted paths. Relative names like
        // "chrome.exe" are resolved by Process.Start through PATH, and
        // File.Exists("chrome.exe") would always be false unless we happened
        // to be running from Chrome's install dir.
        if (Path.IsPathRooted(chromePath) && !File.Exists(chromePath))
        {
            logger.Warn("chrome", "auto-start skipped: chrome executable missing", new Dictionary<string, string?>
            {
                ["chrome_path"] = chromePath,
                ["port"] = port.ToString(),
            });
            return;
        }

        if (string.IsNullOrWhiteSpace(userDataDir))
        {
            logger.Warn("chrome", "auto-start skipped: user_data_dir empty", new Dictionary<string, string?>
            {
                ["port"] = port.ToString(),
            });
            return;
        }

        // Step 1: detect any running chrome on this port + user-data-dir,
        // regardless of headless. If found, just adopt it.
        var anyModeSpec = BuildChromeMatchSpec(chromePath, port, userDataDir, requireHeadless: null, launchKeySuffix: ":auto");
        var existingPids = WindowQuery.FindMatchingProcessIds(anyModeSpec);
        if (existingPids.Count > 0)
        {
            // Inspect the running pid's command line to record the *actual*
            // mode in state (not the configured default), so the status
            // segment matches reality.
            var existingPid = existingPids[0];
            var runningCommandLine = ProcessCommandLineReader.TryGetCommandLine(existingPid) ?? string.Empty;
            var runningHeadless = runningCommandLine.Contains("--headless", StringComparison.OrdinalIgnoreCase);
            logger.Info("chrome", "auto-start adopted existing chrome", new Dictionary<string, string?>
            {
                ["pid"] = existingPid.ToString(),
                ["port"] = port.ToString(),
                ["headless"] = runningHeadless ? "1" : "0",
                ["user_data_dir"] = userDataDir,
            });
            WriteState(logger, stateFile, traceId, runningHeadless, port, existingPid, "auto_adopted");
            ChromeLivenessWatcher.Track(logger, stateFile, existingPid, port, runningHeadless, traceId);
            return;
        }

        // Step 2: nothing running. Launch with the configured default mode.
        var launchArgs = new List<string>
        {
            $"--remote-debugging-port={port}",
            $"--user-data-dir={userDataDir}",
            // Allow any origin so the human-debug path through chrome://inspect
            // (or edge://inspect, devtools://devtools, etc.) can WebSocket-attach
            // when the user wants to interactively inspect the headless instance.
            // Acceptable in this local-dev scenario because Chrome binds the
            // remote-debugging port to 127.0.0.1 -- the surface is limited to
            // tabs running on the same machine, and the user-data-dir is a
            // dedicated debug profile, not their main browsing data.
            "--remote-allow-origins=*",
            "--disable-extensions",
            "--no-first-run",
            "--no-default-browser-check",
        };
        if (launchHeadless)
        {
            launchArgs.Add("--headless=new");
            launchArgs.Add("--window-size=1920,1080");
        }

        try
        {
            WindowActivator.LaunchDetachedProcess(chromePath, launchArgs);
        }
        catch (Exception ex)
        {
            logger.Warn("chrome", "auto-start launch failed", new Dictionary<string, string?>
            {
                ["chrome_path"] = chromePath,
                ["port"] = port.ToString(),
                ["headless"] = launchHeadless ? "1" : "0",
                ["error"] = ex.Message,
            });
            WriteStateNone(logger, stateFile, traceId, port, pid: null, action: "auto_launch_failed");
            return;
        }

        var matchSpec = BuildChromeMatchSpec(chromePath, port, userDataDir, requireHeadless: launchHeadless, launchKeySuffix: ":auto-launched");
        var pids = WindowQuery.WaitForMatchingProcessIds(matchSpec, 4000);
        if (pids.Count == 0)
        {
            logger.Warn("chrome", "auto-start launched but pid not resolved", new Dictionary<string, string?>
            {
                ["chrome_path"] = chromePath,
                ["port"] = port.ToString(),
                ["headless"] = launchHeadless ? "1" : "0",
            });
            WriteStateNone(logger, stateFile, traceId, port, pid: null, action: "auto_launch_pid_unresolved");
            return;
        }

        var pid = pids[0];
        logger.Info("chrome", "auto-start launched chrome", new Dictionary<string, string?>
        {
            ["pid"] = pid.ToString(),
            ["port"] = port.ToString(),
            ["headless"] = launchHeadless ? "1" : "0",
            ["chrome_path"] = chromePath,
        });
        WriteState(logger, stateFile, traceId, launchHeadless, port, pid, "auto_launched");
        ChromeLivenessWatcher.Track(logger, stateFile, pid, port, launchHeadless, traceId);
    }

    public static void WriteState(StructuredLogger logger, string? stateFile, string traceId, bool headless, int port, int? pid, string action)
    {
        WriteStateInternal(logger, stateFile, traceId, headless ? "headless" : "visible", port, pid, alive: true, exitedAtMs: null, action);
    }

    public static void WriteStateNone(StructuredLogger logger, string? stateFile, string traceId, int port, int? pid, string action)
    {
        WriteStateInternal(logger, stateFile, traceId, "none", port, pid, alive: false, exitedAtMs: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), action);
    }

    private static void WriteStateInternal(StructuredLogger logger, string? stateFile, string traceId, string mode, int port, int? pid, bool alive, long? exitedAtMs, string action)
    {
        if (string.IsNullOrWhiteSpace(stateFile))
        {
            return;
        }
        try
        {
            var dir = Path.GetDirectoryName(stateFile);
            if (!string.IsNullOrEmpty(dir))
            {
                Directory.CreateDirectory(dir);
            }
            var state = new Dictionary<string, object?>
            {
                ["schema"] = 2,
                ["mode"] = mode,
                ["port"] = port,
                ["pid"] = pid,
                ["alive"] = alive,
                ["updated_at_ms"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                ["exited_at_ms"] = exitedAtMs,
                ["action"] = action,
            };
            var json = JsonSerializer.Serialize(state);
            var tmp = stateFile + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, stateFile, overwrite: true);
        }
        catch (Exception ex)
        {
            logger.Warn("chrome", "failed to write chrome debug state", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["state_file"] = stateFile,
                ["mode"] = mode,
                ["error"] = ex.Message,
            });
        }
    }
}
