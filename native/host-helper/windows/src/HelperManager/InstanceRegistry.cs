using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed record InstanceRegistryState(
    Dictionary<string, Dictionary<string, PersistentWindowCacheEntry>>? Entries,
    Dictionary<string, PersistentWindowCacheEntry>? Vscode,
    Dictionary<string, PersistentWindowCacheEntry>? Chrome);

internal sealed class InstanceRegistry
{
    private readonly string statePath;
    private readonly object stateLock = new();
    private readonly Dictionary<string, Dictionary<string, WindowCacheEntry>> entries = new(StringComparer.OrdinalIgnoreCase);

    public InstanceRegistry(string statePath)
    {
        this.statePath = statePath;
        Load();
    }

    public WindowMatch? GetWindow(string instanceType, string key, string expectedProcessName)
    {
        WindowCacheEntry? entry;
        lock (stateLock)
        {
            if (!entries.TryGetValue(instanceType, out var typeEntries) || !typeEntries.TryGetValue(key, out entry))
            {
                return null;
            }
        }

        if (entry == null)
        {
            return null;
        }

        using var process = GetLiveProcess(entry.ProcessId, expectedProcessName, entry.ProcessStartTimeUtc);
        if (process == null || entry.WindowHandle == IntPtr.Zero || !NativeMethods.IsWindow(entry.WindowHandle))
        {
            ForgetWindow(instanceType, key);
            return null;
        }

        return new WindowMatch(entry.ProcessId, entry.WindowHandle);
    }

    public void RememberWindow(string instanceType, string key, WindowMatch window)
    {
        DateTime? startTimeUtc = null;
        try
        {
            using var process = Process.GetProcessById(window.ProcessId);
            startTimeUtc = process.StartTime.ToUniversalTime();
        }
        catch
        {
        }

        lock (stateLock)
        {
            GetOrCreateTypeEntries(instanceType)[key] = new WindowCacheEntry(window.ProcessId, window.WindowHandle, startTimeUtc);
            SaveLocked();
        }
    }

    public void ForgetWindow(string instanceType, string key)
    {
        lock (stateLock)
        {
            if (!entries.TryGetValue(instanceType, out var typeEntries) || !typeEntries.Remove(key))
            {
                return;
            }

            if (typeEntries.Count == 0)
            {
                entries.Remove(instanceType);
            }

            SaveLocked();
        }
    }

    private Dictionary<string, WindowCacheEntry> GetOrCreateTypeEntries(string instanceType)
    {
        if (!entries.TryGetValue(instanceType, out var typeEntries))
        {
            typeEntries = new Dictionary<string, WindowCacheEntry>(StringComparer.OrdinalIgnoreCase);
            entries[instanceType] = typeEntries;
        }

        return typeEntries;
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(statePath))
            {
                return;
            }

            var json = File.ReadAllText(statePath, new UTF8Encoding(false));
            var state = JsonSerializer.Deserialize<InstanceRegistryState>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });
            if (state == null)
            {
                return;
            }

            lock (stateLock)
            {
                entries.Clear();

                foreach (var typeEntry in state.Entries ?? new Dictionary<string, Dictionary<string, PersistentWindowCacheEntry>>(StringComparer.OrdinalIgnoreCase))
                {
                    LoadTypeEntries(typeEntry.Key, typeEntry.Value);
                }

                if (state.Vscode != null)
                {
                    LoadTypeEntries("vscode", state.Vscode);
                }

                if (state.Chrome != null)
                {
                    LoadTypeEntries("chrome", state.Chrome);
                }
            }
        }
        catch
        {
        }
    }

    private void LoadTypeEntries(string instanceType, Dictionary<string, PersistentWindowCacheEntry> persistedEntries)
    {
        var typeEntries = GetOrCreateTypeEntries(instanceType);
        foreach (var item in persistedEntries)
        {
            typeEntries[item.Key] = new WindowCacheEntry(
                item.Value.ProcessId,
                new IntPtr(item.Value.WindowHandle),
                item.Value.ProcessStartTimeUtc);
        }
    }

    private void SaveLocked()
    {
        var state = new InstanceRegistryState(
            Entries: entries.ToDictionary(
                typeEntry => typeEntry.Key,
                typeEntry => typeEntry.Value.ToDictionary(
                    item => item.Key,
                    item => new PersistentWindowCacheEntry(
                        item.Value.ProcessId,
                        item.Value.WindowHandle.ToInt64(),
                        item.Value.ProcessStartTimeUtc),
                    StringComparer.OrdinalIgnoreCase),
                StringComparer.OrdinalIgnoreCase),
            Vscode: null,
            Chrome: null);

        try
        {
            FileSystemUtil.EnsureDirectory(Path.GetDirectoryName(statePath));
            var json = JsonSerializer.Serialize(state, new JsonSerializerOptions
            {
                WriteIndented = false,
            });
            FileSystemUtil.WriteAtomicTextFile(statePath, json + Environment.NewLine);
        }
        catch
        {
        }
    }

    private static Process? GetLiveProcess(int processId, string expectedProcessName, DateTime? expectedStartTimeUtc)
    {
        try
        {
            var process = Process.GetProcessById(processId);
            if (!string.Equals(process.ProcessName, expectedProcessName, StringComparison.OrdinalIgnoreCase))
            {
                process.Dispose();
                return null;
            }

            if (expectedStartTimeUtc.HasValue)
            {
                var actualStartTime = process.StartTime.ToUniversalTime();
                if (actualStartTime != expectedStartTimeUtc.Value)
                {
                    process.Dispose();
                    return null;
                }
            }

            return process;
        }
        catch
        {
            return null;
        }
    }
}
