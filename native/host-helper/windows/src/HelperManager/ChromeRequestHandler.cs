using System.Text.Json;

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
        var chromeProcessName = PathResolvers.GetProcessNameFromExecutable(chromePath, "chrome");
        var launchKey = PathResolvers.BuildChromeCacheKey(port, userDataDir);
        var normalizedUserDataDir = PathResolvers.NormalizeWindowsPath(userDataDir);
        var matchSpec = new LaunchMatchSpec(
            InstanceType: "chrome",
            LaunchKey: launchKey,
            ProcessName: chromeProcessName,
            CommandLineMatcher: commandLine =>
                commandLine.Contains($"--remote-debugging-port={port}", StringComparison.OrdinalIgnoreCase)
                && PathResolvers.NormalizeWindowsPath(commandLine).Contains(normalizedUserDataDir, StringComparison.OrdinalIgnoreCase),
            ReuseMode: ReuseMode.PreferReuse);
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

        WindowActivator.LaunchDetachedProcess(chromePath, new[]
        {
            $"--remote-debugging-port={port}",
            $"--user-data-dir={userDataDir}",
        });
        logger.Info("chrome", "launched debug chrome", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["chrome_path"] = chromePath,
            ["port"] = port.ToString(),
            ["user_data_dir"] = userDataDir,
            ["decision_path"] = "launch",
        });

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
}
