namespace WezTerm.WindowsHostHelper;

internal sealed record WindowCacheEntry(int ProcessId, IntPtr WindowHandle, DateTime? ProcessStartTimeUtc);
internal sealed record WindowMatch(int ProcessId, IntPtr WindowHandle);
internal sealed record ForegroundWindowInfo(int ProcessId, string ProcessName, IntPtr WindowHandle);
internal sealed record PersistentWindowCacheEntry(int ProcessId, long WindowHandle, DateTime? ProcessStartTimeUtc);
internal sealed record LaunchMatchSpec(
    string InstanceType,
    string LaunchKey,
    string ProcessName,
    Func<string, bool> CommandLineMatcher,
    ReuseMode ReuseMode);
internal sealed record ReuseDecision(
    WindowMatch? Window,
    string Path,
    bool RegistryHit,
    int MatchedProcessCount,
    bool MatchedWindowFound,
    IReadOnlyList<int> MatchedProcessIds);

internal enum ReuseMode
{
    Strict,
    PreferReuse,
}
