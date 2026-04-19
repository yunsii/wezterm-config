using System.Text;

namespace WezTerm.WindowsHostHelper;

internal sealed class StructuredLogger
{
    private readonly DiagnosticConfig config;
    private readonly object writeLock = new();

    public StructuredLogger(DiagnosticConfig config)
    {
        this.config = config;
    }

    public void Info(string category, string message, IDictionary<string, string?>? fields = null) => Write("info", category, message, fields);
    public void Warn(string category, string message, IDictionary<string, string?>? fields = null) => Write("warn", category, message, fields);
    public void Error(string category, string message, IDictionary<string, string?>? fields = null) => Write("error", category, message, fields);

    private void Write(string level, string category, string message, IDictionary<string, string?>? fields)
    {
        if (!config.Enabled || !config.CategoryEnabled || string.IsNullOrWhiteSpace(config.FilePath))
        {
            return;
        }

        if (LevelRank(level) > LevelRank(config.Level))
        {
            return;
        }

        lock (writeLock)
        {
            try
            {
                FileSystemUtil.EnsureDirectory(Path.GetDirectoryName(config.FilePath!));
                RotateIfNeeded();

                var line = new StringBuilder();
                line.Append("ts=").Append(Escape(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")));
                line.Append(" level=").Append(Escape(level));
                line.Append(" source=").Append(Escape("windows-helper-manager"));
                line.Append(" category=").Append(Escape(category));
                line.Append(" message=").Append(Escape(message));

                if (fields != null)
                {
                    foreach (var item in fields.OrderBy(item => item.Key, StringComparer.Ordinal))
                    {
                        line.Append(' ').Append(item.Key).Append('=').Append(Escape(item.Value));
                    }
                }

                File.AppendAllText(config.FilePath!, line + Environment.NewLine, new UTF8Encoding(false));
            }
            catch
            {
            }
        }
    }

    private void RotateIfNeeded()
    {
        if (config.MaxBytes <= 0 || config.MaxFiles <= 0 || string.IsNullOrWhiteSpace(config.FilePath) || !File.Exists(config.FilePath))
        {
            return;
        }

        var fileInfo = new FileInfo(config.FilePath);
        if (fileInfo.Length < config.MaxBytes)
        {
            return;
        }

        var lastPath = $"{config.FilePath}.{config.MaxFiles}";
        if (File.Exists(lastPath))
        {
            File.Delete(lastPath);
        }

        for (var index = config.MaxFiles - 1; index >= 1; index -= 1)
        {
            var source = $"{config.FilePath}.{index}";
            var destination = $"{config.FilePath}.{index + 1}";
            if (File.Exists(source))
            {
                File.Move(source, destination, overwrite: true);
            }
        }

        File.Move(config.FilePath, $"{config.FilePath}.1", overwrite: true);
    }

    private static int LevelRank(string level) => level switch
    {
        "error" => 1,
        "warn" => 2,
        "info" => 3,
        "debug" => 4,
        _ => 3,
    };

    private static string Escape(string? value)
    {
        var text = (value ?? "nil")
            .Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal)
            .Replace("\n", "\\n", StringComparison.Ordinal)
            .Replace("\r", "\\r", StringComparison.Ordinal)
            .Replace("\t", "\\t", StringComparison.Ordinal);
        return $"\"{text}\"";
    }
}
