using System.Diagnostics;

namespace WezTerm.WindowsHostHelper;

internal static class WindowActivator
{
    public static void LaunchDetachedProcess(string executable, IReadOnlyList<string> arguments)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = true,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };

        foreach (var item in arguments)
        {
            startInfo.ArgumentList.Add(item);
        }

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException($"failed to launch {executable}");
    }

    public static bool TryActivateWindow(WindowMatch window)
    {
        if (window.WindowHandle == IntPtr.Zero || !NativeMethods.IsWindow(window.WindowHandle))
        {
            return false;
        }

        var showCode = NativeMethods.IsIconic(window.WindowHandle) ? 9 : 5;
        NativeMethods.ShowWindowAsync(window.WindowHandle, showCode);
        Thread.Sleep(5);

        var foregroundWindow = NativeMethods.GetForegroundWindow();
        var foregroundThreadId = foregroundWindow == IntPtr.Zero
            ? 0
            : NativeMethods.GetWindowThreadProcessId(foregroundWindow, out _);
        var targetThreadId = NativeMethods.GetWindowThreadProcessId(window.WindowHandle, out _);
        var currentThreadId = NativeMethods.GetCurrentThreadId();

        var attachedToForeground = false;
        var attachedToTarget = false;
        try
        {
            if (foregroundThreadId != 0 && foregroundThreadId != currentThreadId)
            {
                attachedToForeground = NativeMethods.AttachThreadInput(currentThreadId, foregroundThreadId, true);
            }

            if (targetThreadId != 0 && targetThreadId != currentThreadId)
            {
                attachedToTarget = NativeMethods.AttachThreadInput(currentThreadId, targetThreadId, true);
            }

            NativeMethods.BringWindowToTop(window.WindowHandle);
            NativeMethods.SetActiveWindow(window.WindowHandle);
            NativeMethods.SetFocus(window.WindowHandle);
            NativeMethods.SendAltKeyTap();
            if (NativeMethods.SetForegroundWindow(window.WindowHandle)
                && WaitForWindowForeground(window.WindowHandle, 250))
            {
                return true;
            }
        }
        finally
        {
            if (attachedToTarget)
            {
                NativeMethods.AttachThreadInput(currentThreadId, targetThreadId, false);
            }

            if (attachedToForeground)
            {
                NativeMethods.AttachThreadInput(currentThreadId, foregroundThreadId, false);
            }
        }

        var processMainWindow = NativeMethods.TryGetProcessMainWindow(window.ProcessId);
        if (processMainWindow != IntPtr.Zero
            && processMainWindow != window.WindowHandle
            && TryActivateWindow(new WindowMatch(window.ProcessId, processMainWindow)))
        {
            return true;
        }

        NativeMethods.BringWindowToTop(window.WindowHandle);
        NativeMethods.SetActiveWindow(window.WindowHandle);
        NativeMethods.SetFocus(window.WindowHandle);
        NativeMethods.SendAltKeyTap();
        NativeMethods.SetForegroundWindow(window.WindowHandle);
        return WaitForWindowForeground(window.WindowHandle, 500);
    }

    private static bool WaitForWindowForeground(IntPtr windowHandle, int timeoutMs)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.ElapsedMilliseconds < timeoutMs)
        {
            if (NativeMethods.GetForegroundWindow() == windowHandle)
            {
                return true;
            }

            Thread.Sleep(20);
        }

        return false;
    }
}
