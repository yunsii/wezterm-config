using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed class VscodeRequestHandler
{
    private readonly StructuredLogger logger;
    private readonly WindowReuseService windowReuseService;

    public VscodeRequestHandler(StructuredLogger logger, WindowReuseService windowReuseService)
    {
        this.logger = logger;
        this.windowReuseService = windowReuseService;
    }

    public RequestOutcome FocusOrOpen(JsonElement payload, string traceId)
    {
        var requestedDir = PathResolvers.NormalizeWslPath(RequestPayloadReader.RequireString(payload, "requested_dir"));
        var distro = RequestPayloadReader.RequireString(payload, "distro");
        var targetDir = PathResolvers.ResolveWorktreeRoot(requestedDir, distro);
        var command = RequestPayloadReader.GetStringArray(payload, "code_command").ToArray();
        if (command.Length == 0)
        {
            command = new[] { "code" };
        }

        var codeExecutable = command[0];
        var codeArguments = command.Skip(1).ToList();
        var processName = PathResolvers.GetProcessNameFromExecutable(codeExecutable, "Code");
        var launchKey = PathResolvers.BuildWindowCacheKey(distro, targetDir);
        var folderUri = PathResolvers.BuildVscodeFolderUri(distro, targetDir);
        var matchSpec = new LaunchMatchSpec(
            InstanceType: "vscode",
            LaunchKey: launchKey,
            ProcessName: processName,
            CommandLineMatcher: commandLine => commandLine.Contains(folderUri, StringComparison.OrdinalIgnoreCase),
            ReuseMode: ReuseMode.Strict);
        var existingVisibleWindowHandles = WindowQuery.CaptureVisibleProcessWindowHandles(processName);

        logger.Info("alt_o", "resolved vscode target", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["requested_dir"] = requestedDir,
            ["target_dir"] = targetDir,
            ["launch_key"] = launchKey,
        });

        var reuseDecision = windowReuseService.EvaluateReuse(matchSpec, WindowQuery.GetForegroundWindowInfo(), 1000);
        logger.Info("alt_o", "evaluated vscode reuse candidates", new Dictionary<string, string?>
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
            ["folder_uri"] = folderUri,
        });
        if (reuseDecision.Window != null)
        {
            logger.Info("alt_o", "focused cached vscode window", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["target_dir"] = targetDir,
                ["launch_key"] = launchKey,
                ["pid"] = reuseDecision.Window.ProcessId.ToString(),
                ["hwnd"] = reuseDecision.Window.WindowHandle.ToInt64().ToString(),
                ["decision_path"] = reuseDecision.Path,
            });
            return new RequestOutcome(
                Domain: "vscode",
                Action: "focus_or_open",
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

        var initialForeground = WindowQuery.GetForegroundWindowInfo();
        WindowActivator.LaunchDetachedProcess(codeExecutable, codeArguments.Concat(new[] { "--folder-uri", folderUri }).ToArray());
        logger.Info("alt_o", "launched vscode", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["target_dir"] = targetDir,
            ["folder_uri"] = folderUri,
            ["code_executable"] = codeExecutable,
            ["decision_path"] = "launch",
        });

        WindowMatch? boundWindow = WindowQuery.WaitForForegroundProcessWindow(processName, initialForeground, 4000);
        string decisionPath;
        var focusedWindow = boundWindow;
        if (focusedWindow != null)
        {
            windowReuseService.RememberWindow("vscode", launchKey, focusedWindow);
            decisionPath = "launch_bind_foreground_window";
            logger.Info("alt_o", "captured vscode window after launch", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["target_dir"] = targetDir,
                ["launch_key"] = launchKey,
                ["pid"] = focusedWindow.ProcessId.ToString(),
                ["hwnd"] = focusedWindow.WindowHandle.ToInt64().ToString(),
                ["decision_path"] = decisionPath,
            });
        }
        else
        {
            var launchedWindow = WindowQuery.WaitForWindowForMatchingProcessIds(matchSpec, 4000);
            launchedWindow ??= WindowQuery.WaitForNewProcessWindow(processName, existingVisibleWindowHandles, 4000);
            if (launchedWindow != null && WindowActivator.TryActivateWindow(launchedWindow))
            {
                boundWindow = launchedWindow;
                decisionPath = existingVisibleWindowHandles.Contains(launchedWindow.WindowHandle)
                    ? "launch_bind_existing_visible_window"
                    : "launch_bind_new_visible_window";
                windowReuseService.RememberWindow("vscode", launchKey, launchedWindow);
                logger.Info("alt_o", "focused vscode window after launch fallback", new Dictionary<string, string?>
                {
                    ["trace_id"] = traceId,
                    ["target_dir"] = targetDir,
                    ["launch_key"] = launchKey,
                    ["pid"] = launchedWindow.ProcessId.ToString(),
                    ["hwnd"] = launchedWindow.WindowHandle.ToInt64().ToString(),
                    ["decision_path"] = decisionPath,
                });
            }
            else
            {
                decisionPath = "launch_unbound";
                logger.Info("alt_o", "no vscode foreground window captured after launch", new Dictionary<string, string?>
                {
                    ["trace_id"] = traceId,
                    ["target_dir"] = targetDir,
                    ["launch_key"] = launchKey,
                    ["decision_path"] = decisionPath,
                });
            }
        }

        return new RequestOutcome(
            Domain: "vscode",
            Action: "focus_or_open",
            Status: "launched",
            DecisionPath: boundWindow != null ? decisionPath : "launch_unbound",
            ResultType: boundWindow != null ? "window_ref" : null,
            Result: boundWindow != null
                ? new HelperWindowRefResult
                {
                    Pid = boundWindow.ProcessId,
                    Hwnd = boundWindow.WindowHandle.ToInt64(),
                }
                : null,
            ProcessId: boundWindow?.ProcessId,
            WindowHandle: boundWindow?.WindowHandle.ToInt64());
    }
}
