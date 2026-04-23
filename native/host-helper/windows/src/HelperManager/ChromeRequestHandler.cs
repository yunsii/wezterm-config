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
            $"--remote-allow-origins=http://localhost:{port}",
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
            WriteState(logger, stateFile, traceId, headless, port, null, "launched");
            return new RequestOutcome(
                Domain: "chrome",
                Action: "focus_or_start",
                Status: "launched",
                DecisionPath: "launch_headless");
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

    private static void WriteState(StructuredLogger logger, string? stateFile, string traceId, bool headless, int port, int? pid, string action)
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
                ["schema"] = 1,
                ["mode"] = headless ? "headless" : "visible",
                ["port"] = port,
                ["pid"] = pid,
                ["updated_at_ms"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
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
                ["error"] = ex.Message,
            });
        }
    }
}
