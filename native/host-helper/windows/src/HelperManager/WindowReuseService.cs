namespace WezTerm.WindowsHostHelper;

internal sealed class WindowReuseService
{
    private readonly InstanceRegistry instanceRegistry;

    public WindowReuseService(InstanceRegistry instanceRegistry)
    {
        this.instanceRegistry = instanceRegistry;
    }

    public ReuseDecision EvaluateReuse(LaunchMatchSpec spec, ForegroundWindowInfo? initialForeground, int timeoutMs)
    {
        var persistedWindow = instanceRegistry.GetWindow(spec.InstanceType, spec.LaunchKey, spec.ProcessName);
        if (persistedWindow != null)
        {
            if (!WindowActivator.TryActivateWindow(persistedWindow))
            {
                return new ReuseDecision(null, "registry_window_activation_failed", true, 0, false, Array.Empty<int>());
            }

            instanceRegistry.RememberWindow(spec.InstanceType, spec.LaunchKey, persistedWindow);
            return new ReuseDecision(persistedWindow, "registry_window", true, 0, false, Array.Empty<int>());
        }

        var matchingWindow = WindowQuery.FindWindowForMatchingProcesses(spec);
        if (matchingWindow != null)
        {
            instanceRegistry.RememberWindow(spec.InstanceType, spec.LaunchKey, matchingWindow);
            if (WindowActivator.TryActivateWindow(matchingWindow))
            {
                return new ReuseDecision(matchingWindow, "matched_window", false, 1, true, new[] { matchingWindow.ProcessId });
            }

            return new ReuseDecision(null, "matched_window_activation_failed", false, 1, true, new[] { matchingWindow.ProcessId });
        }

        var matchingProcessIds = WindowQuery.FindMatchingProcessIds(spec);
        if (spec.ReuseMode != ReuseMode.PreferReuse)
        {
            return new ReuseDecision(null, matchingProcessIds.Count > 0 ? "matched_process_without_window" : "no_match", false, matchingProcessIds.Count, false, matchingProcessIds);
        }

        if (matchingProcessIds.Count == 0)
        {
            return new ReuseDecision(null, "no_match", false, 0, false, matchingProcessIds);
        }

        var reboundWindow = TryRebindExistingInstance(spec, matchingProcessIds, initialForeground, timeoutMs);
        if (reboundWindow != null)
        {
            return new ReuseDecision(reboundWindow, "matched_process_rebind", false, matchingProcessIds.Count, false, matchingProcessIds);
        }

        return new ReuseDecision(null, "matched_process_rebind_failed", false, matchingProcessIds.Count, false, matchingProcessIds);
    }

    public void RememberWindow(string instanceType, string key, WindowMatch window)
    {
        instanceRegistry.RememberWindow(instanceType, key, window);
    }

    private WindowMatch? TryRebindExistingInstance(LaunchMatchSpec spec, IReadOnlyCollection<int> matchingProcessIds, ForegroundWindowInfo? initialForeground, int timeoutMs)
    {
        var existingWindow = WindowQuery.FindWindowForProcessIds(spec.ProcessName, matchingProcessIds);
        if (existingWindow != null && WindowActivator.TryActivateWindow(existingWindow))
        {
            instanceRegistry.RememberWindow(spec.InstanceType, spec.LaunchKey, existingWindow);
            return existingWindow;
        }

        foreach (var processId in matchingProcessIds)
        {
            var processWindow = NativeMethods.TryGetProcessMainWindow(processId);
            if (processWindow == IntPtr.Zero)
            {
                continue;
            }

            var processWindowMatch = new WindowMatch(processId, processWindow);
            if (!WindowActivator.TryActivateWindow(processWindowMatch))
            {
                continue;
            }

            var activatedWindow = WindowQuery.WaitForForegroundProcessWindow(spec.ProcessName, initialForeground, timeoutMs)
                ?? WindowQuery.WaitForWindowForProcessIds(spec.ProcessName, matchingProcessIds, timeoutMs)
                ?? processWindowMatch;
            if (activatedWindow != null)
            {
                instanceRegistry.RememberWindow(spec.InstanceType, spec.LaunchKey, activatedWindow);
                return activatedWindow;
            }
        }

        return null;
    }
}
