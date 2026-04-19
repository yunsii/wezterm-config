using System.Text;

namespace WezTerm.WindowsHostHelper;

internal static class HelperCtlBootstrapLog
{
    public static int ExitWithError(Exception ex, string stage, long elapsedMs)
    {
        return ExitWithError(
            $"request failed at {stage}: {ex.Message}",
            stage,
            elapsedMs,
            ex.GetType().FullName,
            ex.HResult.ToString("X8"));
    }

    public static int ExitWithError(string? message, string stage, long elapsedMs, string? exceptionType = null, string? hresult = null)
    {
        try
        {
            var text = string.IsNullOrWhiteSpace(message) ? "helperctl failed" : message;
            var fullText = $"{text} | stage={stage} | elapsed_ms={elapsedMs}";
            if (!string.IsNullOrWhiteSpace(exceptionType))
            {
                fullText += $" | exception_type={exceptionType}";
            }
            if (!string.IsNullOrWhiteSpace(hresult))
            {
                fullText += $" | hresult={hresult}";
            }

            Console.Error.WriteLine(fullText);

            var logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wezterm-runtime", "logs");
            Directory.CreateDirectory(logDir);
            File.AppendAllText(
                Path.Combine(logDir, "helperctl-bootstrap.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {fullText}{Environment.NewLine}",
                new UTF8Encoding(false));
        }
        catch
        {
        }

        return 1;
    }
}
