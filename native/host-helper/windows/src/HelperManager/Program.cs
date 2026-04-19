using System.Text;

namespace WezTerm.WindowsHostHelper;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (!TryParseServerArgs(args, out var configPath, out var parseError))
        {
            return ExitWithError(parseError);
        }

        HelperConfig config;
        try
        {
            config = HelperConfig.Load(configPath!);
        }
        catch (Exception ex)
        {
            return ExitWithError($"failed to load config: {ex.Message}");
        }

        using var mutex = new Mutex(initiallyOwned: true, name: @"Local\WezTermRuntimeHelperManager", createdNew: out var createdNew);
        if (!createdNew)
        {
            return 0;
        }

        var manager = new HostHelperManager(config);
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
        {
            var ex = eventArgs.ExceptionObject as Exception;
            manager.ReportFatalError(ex?.ToString() ?? "unknown unhandled exception");
        };

        try
        {
            manager.Run();
            return 0;
        }
        catch (Exception ex)
        {
            manager.ReportFatalError(ex.ToString());
            return ExitWithError(ex.Message);
        }
    }

    private static bool TryParseServerArgs(string[] args, out string? configPath, out string? error)
    {
        configPath = null;
        error = null;

        for (var index = 0; index < args.Length; index += 1)
        {
            if (!string.Equals(args[index], "--config", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (index + 1 >= args.Length)
            {
                error = "missing value for --config";
                return false;
            }

            configPath = args[index + 1];
            index += 1;
        }

        if (string.IsNullOrWhiteSpace(configPath))
        {
            error = "usage: helper-manager.exe --config <path>";
            return false;
        }

        return true;
    }

    private static int ExitWithError(string? message)
    {
        try
        {
            var text = string.IsNullOrWhiteSpace(message) ? "helper-manager failed" : message;
            var logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wezterm-runtime", "logs");
            FileSystemUtil.EnsureDirectory(logDir);
            File.AppendAllText(
                Path.Combine(logDir, "manager-bootstrap.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {text}{Environment.NewLine}",
                new UTF8Encoding(false));
        }
        catch
        {
        }

        return 1;
    }
}
