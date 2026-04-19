namespace WezTerm.WindowsHostHelper;

internal sealed record ClipboardState(
    string Kind,
    string Sequence,
    string Formats,
    string TextValue,
    string UpdatedAtMs,
    string HeartbeatAtMs,
    string ListenerPid,
    string ListenerStartedAtMs,
    string Distro,
    string WindowsPath,
    string WslPath,
    string LastError)
{
    public static ClipboardState Starting() => new(
        Kind: "starting",
        Sequence: string.Empty,
        Formats: string.Empty,
        TextValue: string.Empty,
        UpdatedAtMs: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
        HeartbeatAtMs: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
        ListenerPid: Environment.ProcessId.ToString(),
        ListenerStartedAtMs: DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
        Distro: string.Empty,
        WindowsPath: string.Empty,
        WslPath: string.Empty,
        LastError: string.Empty);

    public static ClipboardState Text(string sequence, string formats, string text) => Starting() with
    {
        Kind = "text",
        Sequence = sequence,
        Formats = formats,
        TextValue = text,
        UpdatedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
    };

    public static ClipboardState Image(string sequence, string formats, string windowsPath, string wslPath, string? distro) => Starting() with
    {
        Kind = "image",
        Sequence = sequence,
        Formats = formats,
        UpdatedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
        Distro = distro ?? string.Empty,
        WindowsPath = windowsPath,
        WslPath = wslPath,
    };

    public static ClipboardState Unknown(string error, string sequence = "", string formats = "") => Starting() with
    {
        Kind = "unknown",
        Sequence = sequence,
        Formats = formats,
        UpdatedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(),
        LastError = error,
    };
}
