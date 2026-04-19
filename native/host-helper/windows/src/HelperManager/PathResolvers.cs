namespace WezTerm.WindowsHostHelper;

internal static class PathResolvers
{
    public static string ResolveWorktreeRoot(string directory, string distribution)
    {
        var normalizedDirectory = NormalizeWslPath(directory);
        var currentPath = normalizedDirectory;
        while (!string.IsNullOrWhiteSpace(currentPath))
        {
            var uncPath = ConvertToWslUncPath(currentPath, distribution);
            if (!string.IsNullOrWhiteSpace(uncPath) && Directory.Exists(uncPath))
            {
                if (Directory.Exists(Path.Combine(uncPath, ".git")) || File.Exists(Path.Combine(uncPath, ".git")))
                {
                    return currentPath;
                }
            }

            if (currentPath == "/")
            {
                break;
            }

            currentPath = GetWslParentPath(currentPath);
        }

        return normalizedDirectory;
    }

    public static string BuildVscodeFolderUri(string distro, string targetDir)
    {
        return $"vscode-remote://wsl+{Uri.EscapeDataString(distro)}{ConvertToVscodeRemotePath(targetDir)}";
    }

    public static string BuildWindowCacheKey(string distro, string path)
    {
        return $"{distro}|{NormalizeWslPath(path)}";
    }

    public static string BuildChromeCacheKey(int port, string userDataDir)
    {
        return $"{port}|{NormalizeWindowsPath(userDataDir)}";
    }

    public static string NormalizeWslPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        var normalized = path.Replace('\\', '/').Trim();
        if (normalized.Length > 1)
        {
            normalized = normalized.TrimEnd('/');
        }

        return string.IsNullOrWhiteSpace(normalized) ? "/" : normalized;
    }

    public static string NormalizeWindowsPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return string.Empty;
        }

        var normalized = path.Replace('/', '\\').Trim().Trim('"');
        if (normalized.Length > 3)
        {
            normalized = normalized.TrimEnd('\\');
        }

        return normalized;
    }

    public static string GetProcessNameFromExecutable(string executable, string fallback)
    {
        var processName = Path.GetFileNameWithoutExtension(executable);
        return string.IsNullOrWhiteSpace(processName) ? fallback : processName;
    }

    private static string ConvertToVscodeRemotePath(string path)
    {
        var normalized = path.Replace('\\', '/');
        var segments = normalized.Split('/', StringSplitOptions.None)
            .Select(Uri.EscapeDataString);
        return string.Join("/", segments);
    }

    private static string? GetWslParentPath(string path)
    {
        var normalized = NormalizeWslPath(path);
        if (string.IsNullOrWhiteSpace(normalized) || normalized == "/")
        {
            return null;
        }

        var lastSlash = normalized.LastIndexOf('/');
        if (lastSlash <= 0)
        {
            return "/";
        }

        return normalized[..lastSlash];
    }

    private static string? ConvertToWslUncPath(string path, string distribution)
    {
        var normalized = NormalizeWslPath(path);
        if (string.IsNullOrWhiteSpace(normalized) || !normalized.StartsWith('/'))
        {
            return null;
        }

        var relative = normalized.TrimStart('/').Replace('/', '\\');
        if (string.IsNullOrWhiteSpace(relative))
        {
            return @"\\wsl$\" + distribution + @"\";
        }

        return @"\\wsl$\" + distribution + @"\" + relative;
    }
}
