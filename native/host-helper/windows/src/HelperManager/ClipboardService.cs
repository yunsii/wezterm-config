using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WezTerm.WindowsHostHelper;

internal sealed class ClipboardService : IDisposable
{
    private readonly HelperConfig config;
    private readonly StructuredLogger logger;
    private readonly ManualResetEventSlim readySignal = new(initialState: false);
    private readonly object stateLock = new();
    private ClipboardState currentState;
    private Thread? thread;
    private HiddenClipboardForm? form;
    private bool disposed;

    public ClipboardService(HelperConfig config, StructuredLogger logger)
    {
        this.config = config;
        this.logger = logger;
        currentState = ClipboardState.Starting();
    }

    public void Start()
    {
        thread = new Thread(RunClipboardThread)
        {
            IsBackground = true,
            Name = "wezterm-clipboard-helper",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        if (form != null && form.IsHandleCreated)
        {
            try
            {
                form.BeginInvoke(new Action(() => form.Close()));
            }
            catch
            {
            }
        }
    }

    private void RunClipboardThread()
    {
        try
        {
            MirrorState(ClipboardState.Starting());

            form = new HiddenClipboardForm(this);
            _ = form.Handle;
            readySignal.Set();
            RefreshClipboardState();
            Application.Run(form);
        }
        catch (Exception ex)
        {
            logger.Error("clipboard", "clipboard service crashed", new Dictionary<string, string?>
            {
                ["error"] = ex.Message,
            });
            MirrorState(ClipboardState.Unknown(ex.Message));
        }
        finally
        {
            form?.Dispose();
        }
    }

    public void RefreshClipboardState()
    {
        try
        {
            MirrorState(ReadClipboardNow());
        }
        catch (Exception ex)
        {
            MirrorState(ClipboardState.Unknown(ex.Message));
        }
    }

    public ClipboardState ResolveForPaste()
    {
        return RunOnClipboardThread(() =>
        {
            var snapshot = ReadClipboardNow();
            MirrorState(snapshot);
            return snapshot;
        });
    }

    public ClipboardState WriteText(string text)
    {
        return RunOnClipboardThread(() =>
        {
            Clipboard.SetText(text ?? string.Empty, TextDataFormat.UnicodeText);
            var snapshot = ReadClipboardNow();
            MirrorState(snapshot);
            return snapshot;
        });
    }

    public ClipboardState WriteImageFromFile(string imagePath)
    {
        return RunOnClipboardThread(() =>
        {
            using var source = Image.FromFile(imagePath);
            using var bitmap = new Bitmap(source);
            var dibBytes = CreateDeviceIndependentBitmap(bitmap);
            using var pngStream = new MemoryStream();
            bitmap.Save(pngStream, ImageFormat.Png);
            var pngBytes = pngStream.ToArray();

            SetClipboardImageData(dibBytes, pngBytes);

            var snapshot = ReadClipboardNow();
            MirrorState(snapshot);
            return snapshot;
        });
    }

    private ClipboardState RunOnClipboardThread(Func<ClipboardState> action)
    {
        if (readySignal.Wait(TimeSpan.FromSeconds(5)) && form != null && form.IsHandleCreated)
        {
            var result = form.Invoke(action);
            if (result is ClipboardState clipboardState)
            {
                return clipboardState;
            }
        }

        lock (stateLock)
        {
            return currentState;
        }
    }

    private ClipboardState ReadClipboardNow()
    {
        var sequence = NativeMethods.GetClipboardSequenceNumber().ToString();
        var dataObject = Clipboard.GetDataObject();
        var formats = GetClipboardFormats(dataObject);
        if (!Clipboard.ContainsImage())
        {
            var text = Clipboard.ContainsText() ? Clipboard.GetText(TextDataFormat.UnicodeText) : string.Empty;
            return ClipboardState.Text(sequence, formats, text);
        }

        FileSystemUtil.EnsureDirectory(config.ClipboardOutputDir);
        using var image = GetClipboardImageWithRetry();
        if (image == null)
        {
            var message = "Clipboard reported an image, but no bitmap data was available.";
            return ClipboardState.Unknown(message, sequence, formats);
        }

        var fileName = $"clipboard-{DateTime.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}"[..34] + ".png";
        var windowsPath = Path.Combine(config.ClipboardOutputDir!, fileName);
        image.Save(windowsPath, ImageFormat.Png);
        var wslPath = ConvertWindowsPathToWsl(windowsPath);
        RemoveStaleExports();
        return ClipboardState.Image(sequence, formats, windowsPath, wslPath, config.ClipboardWslDistro);
    }

    private Image? GetClipboardImageWithRetry()
    {
        var attemptCount = Math.Max(config.ClipboardImageReadRetryCount, 1);
        var delayMs = Math.Max(config.ClipboardImageReadRetryDelayMs, 1);

        for (var attempt = 1; attempt <= attemptCount; attempt += 1)
        {
            try
            {
                var image = Clipboard.GetImage();
                if (image != null)
                {
                    return image;
                }
            }
            catch when (attempt < attemptCount)
            {
            }

            if (attempt < attemptCount)
            {
                Thread.Sleep(delayMs);
            }
        }

        return null;
    }

    private static void SetClipboardImageData(byte[] dibBytes, byte[] pngBytes)
    {
        if (dibBytes.Length == 0)
        {
            throw new InvalidOperationException("device independent bitmap payload was empty");
        }

        var pngFormat = NativeMethods.RegisterClipboardFormat("PNG");
        if (pngFormat == 0)
        {
            throw new InvalidOperationException("failed to register PNG clipboard format");
        }

        IntPtr dibHandle = IntPtr.Zero;
        IntPtr pngHandle = IntPtr.Zero;
        var dibOwnershipTransferred = false;
        var pngOwnershipTransferred = false;

        try
        {
            dibHandle = AllocHGlobalCopy(dibBytes);
            pngHandle = AllocHGlobalCopy(pngBytes);

            if (!NativeMethods.OpenClipboard(IntPtr.Zero))
            {
                throw new InvalidOperationException("failed to open clipboard");
            }

            try
            {
                if (!NativeMethods.EmptyClipboard())
                {
                    throw new InvalidOperationException("failed to clear clipboard");
                }

                if (NativeMethods.SetClipboardData(NativeMethods.CfDib, dibHandle) == IntPtr.Zero)
                {
                    throw new InvalidOperationException("failed to write CF_DIB clipboard data");
                }
                dibOwnershipTransferred = true;

                if (NativeMethods.SetClipboardData(pngFormat, pngHandle) == IntPtr.Zero)
                {
                    throw new InvalidOperationException("failed to write PNG clipboard data");
                }
                pngOwnershipTransferred = true;
            }
            finally
            {
                NativeMethods.CloseClipboard();
            }
        }
        finally
        {
            if (!dibOwnershipTransferred && dibHandle != IntPtr.Zero)
            {
                NativeMethods.GlobalFree(dibHandle);
            }

            if (!pngOwnershipTransferred && pngHandle != IntPtr.Zero)
            {
                NativeMethods.GlobalFree(pngHandle);
            }
        }
    }

    private static IntPtr AllocHGlobalCopy(byte[] bytes)
    {
        var handle = NativeMethods.GlobalAlloc(NativeMethods.GmemMoveable, (nuint)bytes.Length);
        if (handle == IntPtr.Zero)
        {
            throw new InvalidOperationException("GlobalAlloc failed");
        }

        var pointer = NativeMethods.GlobalLock(handle);
        if (pointer == IntPtr.Zero)
        {
            NativeMethods.GlobalFree(handle);
            throw new InvalidOperationException("GlobalLock failed");
        }

        try
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
        }
        finally
        {
            NativeMethods.GlobalUnlock(handle);
        }

        return handle;
    }

    private static string GetClipboardFormats(IDataObject? dataObject)
    {
        try
        {
            var formats = dataObject?.GetFormats() ?? Array.Empty<string>();
            return formats.Length == 0 ? string.Empty : string.Join(",", formats.OrderBy(value => value, StringComparer.OrdinalIgnoreCase));
        }
        catch
        {
            return string.Empty;
        }
    }

    private static byte[] CreateDeviceIndependentBitmap(Bitmap bitmap)
    {
        using var stream = new MemoryStream();
        bitmap.Save(stream, ImageFormat.Bmp);
        var bmpBytes = stream.ToArray();
        const int bitmapFileHeaderSize = 14;
        if (bmpBytes.Length <= bitmapFileHeaderSize)
        {
            return Array.Empty<byte>();
        }

        var dibBytes = new byte[bmpBytes.Length - bitmapFileHeaderSize];
        Buffer.BlockCopy(bmpBytes, bitmapFileHeaderSize, dibBytes, 0, dibBytes.Length);
        return dibBytes;
    }

    private void RemoveStaleExports()
    {
        if (string.IsNullOrWhiteSpace(config.ClipboardOutputDir) || !Directory.Exists(config.ClipboardOutputDir))
        {
            return;
        }

        var cutoff = DateTime.UtcNow.AddHours(-1 * Math.Max(config.ClipboardCleanupMaxAgeHours, 1));
        var files = new DirectoryInfo(config.ClipboardOutputDir)
            .EnumerateFiles("clipboard-*.png")
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ToArray();

        var keepCount = Math.Max(config.ClipboardCleanupMaxFiles, 1);
        for (var index = 0; index < files.Length; index += 1)
        {
            var file = files[index];
            if (file.LastWriteTimeUtc < cutoff || index >= keepCount)
            {
                try
                {
                    file.Delete();
                }
                catch
                {
                }
            }
        }
    }

    private void MirrorState(ClipboardState state)
    {
        lock (stateLock)
        {
            currentState = state with
            {
                ListenerPid = Environment.ProcessId.ToString(),
                ListenerStartedAtMs = currentState.ListenerStartedAtMs == string.Empty
                    ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString()
                    : currentState.ListenerStartedAtMs,
            };
        }
    }

    private static string ConvertWindowsPathToWsl(string windowsPath)
    {
        var normalized = windowsPath.Replace('\\', '/');
        if (normalized.Length >= 3 && char.IsLetter(normalized[0]) && normalized[1] == ':' && normalized[2] == '/')
        {
            return $"/mnt/{char.ToLowerInvariant(normalized[0])}/{normalized[3..]}";
        }

        return normalized;
    }
}
