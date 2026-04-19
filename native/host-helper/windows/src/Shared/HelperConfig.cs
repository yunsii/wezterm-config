using System.Text;
using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed class HelperConfig
{
    public required string ConfigHash { get; init; }
    public required string RuntimeDir { get; init; }
    public required string StatePath { get; init; }
    public string? WindowCachePath { get; init; }
    public required string IpcEndpoint { get; init; }
    public required DiagnosticConfig Diagnostics { get; init; }
    public string? ClipboardOutputDir { get; init; }
    public string? ClipboardWslDistro { get; init; }
    public int ClipboardImageReadRetryCount { get; init; }
    public int ClipboardImageReadRetryDelayMs { get; init; }
    public int ClipboardCleanupMaxAgeHours { get; init; }
    public int ClipboardCleanupMaxFiles { get; init; }
    public int HeartbeatIntervalMs { get; init; }

    public static HelperConfig Load(string path)
    {
        var json = File.ReadAllText(path, new UTF8Encoding(false));
        var parsed = JsonSerializer.Deserialize<HelperConfig>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
        }) ?? throw new InvalidOperationException("config file was empty");

        if (string.IsNullOrWhiteSpace(parsed.RuntimeDir) ||
            string.IsNullOrWhiteSpace(parsed.ConfigHash) ||
            string.IsNullOrWhiteSpace(parsed.StatePath) ||
            string.IsNullOrWhiteSpace(parsed.IpcEndpoint))
        {
            throw new InvalidOperationException("config file is missing required paths");
        }

        return new HelperConfig
        {
            ConfigHash = parsed.ConfigHash,
            RuntimeDir = parsed.RuntimeDir,
            StatePath = parsed.StatePath,
            WindowCachePath = ResolveWindowCachePath(parsed.WindowCachePath),
            IpcEndpoint = parsed.IpcEndpoint,
            Diagnostics = parsed.Diagnostics,
            ClipboardOutputDir = ResolveClipboardOutputDir(parsed.ClipboardOutputDir),
            ClipboardWslDistro = parsed.ClipboardWslDistro,
            ClipboardImageReadRetryCount = parsed.ClipboardImageReadRetryCount,
            ClipboardImageReadRetryDelayMs = parsed.ClipboardImageReadRetryDelayMs,
            ClipboardCleanupMaxAgeHours = parsed.ClipboardCleanupMaxAgeHours,
            ClipboardCleanupMaxFiles = parsed.ClipboardCleanupMaxFiles,
            HeartbeatIntervalMs = parsed.HeartbeatIntervalMs,
        };
    }

    private static string ResolveClipboardOutputDir(string? configuredPath)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("LocalApplicationData was unavailable for clipboard exports");
        }

        var fallbackPath = Path.Combine(localAppData, "wezterm-runtime", "state", "clipboard", "exports");
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            return fallbackPath;
        }

        if (!Path.IsPathRooted(configuredPath))
        {
            return fallbackPath;
        }

        return Path.GetFullPath(configuredPath);
    }

    private static string ResolveWindowCachePath(string? configuredPath)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("LocalApplicationData was unavailable for helper window cache");
        }

        var fallbackPath = Path.Combine(localAppData, "wezterm-runtime", "cache", "helper", "window-cache.json");
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            return fallbackPath;
        }

        if (!Path.IsPathRooted(configuredPath))
        {
            return fallbackPath;
        }

        return Path.GetFullPath(configuredPath);
    }
}

internal sealed class DiagnosticConfig
{
    public bool Enabled { get; init; }
    public bool CategoryEnabled { get; init; }
    public string Level { get; init; } = "info";
    public string? FilePath { get; init; }
    public int MaxBytes { get; init; }
    public int MaxFiles { get; init; }
}
