using System.Text;

namespace WezTerm.WindowsHostHelper;

internal static class FileSystemUtil
{
    public static void EnsureDirectory(string? path)
    {
        if (!string.IsNullOrWhiteSpace(path))
        {
            Directory.CreateDirectory(path);
        }
    }

    public static void WriteAtomicTextFile(string path, string content)
    {
        var tempPath = $"{path}.tmp.{Environment.ProcessId}";
        File.WriteAllText(tempPath, content, new UTF8Encoding(false));
        File.Move(tempPath, path, overwrite: true);
    }

    public static string Sanitize(string? value)
    {
        return (value ?? string.Empty).Replace("\r", " ").Replace("\n", " ").Trim();
    }
}
