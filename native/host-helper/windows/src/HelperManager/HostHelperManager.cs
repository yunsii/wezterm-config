namespace WezTerm.WindowsHostHelper;

internal sealed class HostHelperManager : IDisposable
{
    private readonly HelperConfig config;
    private readonly StructuredLogger logger;
    private readonly ManualResetEventSlim stopSignal = new(initialState: false);
    private readonly object stateFileWriteLock = new();
    private readonly long startedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private readonly ClipboardService? clipboardService;
    private readonly System.Threading.Timer heartbeatTimer;
    private readonly RequestRouter requestRouter;
    private string lastError = string.Empty;
    private int heartbeatTickActive;
    private bool disposed;
    private ImeStateSample currentImeSample = new("unknown", null, "uninitialized", "uninitialized");

    public HostHelperManager(HelperConfig config)
    {
        this.config = config;
        logger = new StructuredLogger(config.Diagnostics);

        var instanceRegistry = new InstanceRegistry(config.WindowCachePath ?? Path.Combine(config.RuntimeDir, "window-cache.json"));
        var windowReuseService = new WindowReuseService(instanceRegistry);
        clipboardService = new ClipboardService(config, logger);
        requestRouter = new RequestRouter(
            logger,
            new ClipboardRequestHandler(clipboardService, logger),
            new VscodeRequestHandler(logger, windowReuseService),
            new ChromeRequestHandler(logger, windowReuseService),
            new ImeRequestHandler(logger));

        heartbeatTimer = new System.Threading.Timer(_ => RunHeartbeatTick(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public void Run()
    {
        FileSystemUtil.EnsureDirectory(Path.GetDirectoryName(config.StatePath));

        WriteHelperState("1", string.Empty);
        logger.Info("host_helper", "helper manager started", new Dictionary<string, string?>
        {
            ["ipc_endpoint"] = config.IpcEndpoint,
            ["runtime_dir"] = config.RuntimeDir,
            ["state_path"] = config.StatePath,
        });

        clipboardService?.Start();
        heartbeatTimer.Change(config.HeartbeatIntervalMs, config.HeartbeatIntervalMs);
        StartRequestServer();

        stopSignal.Wait();
    }

    public void ReportFatalError(string message)
    {
        lastError = message ?? string.Empty;
        WriteHelperState("0", lastError);
        logger.Error("host_helper", "helper manager crashed", new Dictionary<string, string?>
        {
            ["error"] = lastError,
            ["runtime_dir"] = config.RuntimeDir,
        });
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        heartbeatTimer.Dispose();
        clipboardService?.Dispose();
        stopSignal.Dispose();
    }

    private void StartRequestServer()
    {
        var serverThread = new Thread(RequestServerLoop)
        {
            IsBackground = true,
            Name = "wezterm-host-helper-ipc",
        };
        serverThread.Start();
    }

    private void RunHeartbeatTick()
    {
        if (Interlocked.Exchange(ref heartbeatTickActive, 1) == 1)
        {
            return;
        }

        try
        {
            currentImeSample = ImeStateSampler.Sample();
            WriteHelperState("1", lastError);
        }
        catch (Exception ex)
        {
            logger.Warn("host_helper", "failed to refresh helper heartbeat", new Dictionary<string, string?>
            {
                ["error"] = ex.Message,
                ["state_path"] = config.StatePath,
                ["runtime_dir"] = config.RuntimeDir,
            });
        }
        finally
        {
            Interlocked.Exchange(ref heartbeatTickActive, 0);
        }
    }

    private void RequestServerLoop()
    {
        while (!stopSignal.IsSet)
        {
            try
            {
                using var server = NamedPipeTransport.CreateServer(config.IpcEndpoint);
                server.WaitForConnection();

                var requestJson = NamedPipeTransport.ReadMessage(server);
                var responseJson = requestRouter.HandleRequestJson(requestJson, $"pipe:{config.IpcEndpoint}", message =>
                {
                    lastError = message;
                    WriteHelperState("1", lastError);
                });
                NamedPipeTransport.WriteMessage(server, responseJson);
            }
            catch (Exception ex)
            {
                if (stopSignal.IsSet)
                {
                    return;
                }

                logger.Error("host_helper", "helper ipc server loop failed", new Dictionary<string, string?>
                {
                    ["error"] = ex.Message,
                    ["ipc_endpoint"] = config.IpcEndpoint,
                });
                Thread.Sleep(100);
            }
        }
    }

    private void WriteHelperState(string ready, string lastErrorValue)
    {
        lock (stateFileWriteLock)
        {
            FileSystemUtil.EnsureDirectory(Path.GetDirectoryName(config.StatePath));

            var sample = currentImeSample;
            var lines = new[]
            {
                "version=3",
                $"ready={FileSystemUtil.Sanitize(lastErrorValue == string.Empty ? ready : ready)}",
                $"pid={Environment.ProcessId}",
                $"started_at_ms={startedAtMs}",
                $"heartbeat_at_ms={DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}",
                $"ipc_endpoint={FileSystemUtil.Sanitize(config.IpcEndpoint)}",
                $"config_hash={FileSystemUtil.Sanitize(config.ConfigHash)}",
                $"runtime_dir={FileSystemUtil.Sanitize(config.RuntimeDir)}",
                $"last_error={FileSystemUtil.Sanitize(lastErrorValue)}",
                $"ime_mode={FileSystemUtil.Sanitize(sample.Mode)}",
                $"ime_lang={FileSystemUtil.Sanitize(sample.Lang ?? string.Empty)}",
                $"ime_reason={FileSystemUtil.Sanitize(sample.Reason ?? string.Empty)}",
            };

            FileSystemUtil.WriteAtomicTextFile(config.StatePath, string.Join("\r\n", lines) + "\r\n");
        }
    }
}
