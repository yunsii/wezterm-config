using System.Diagnostics;
using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed class RequestRouter
{
    private readonly StructuredLogger logger;
    private readonly ClipboardRequestHandler clipboardHandler;
    private readonly VscodeRequestHandler vscodeHandler;
    private readonly ChromeRequestHandler chromeHandler;
    private readonly ImeRequestHandler imeHandler;

    public RequestRouter(
        StructuredLogger logger,
        ClipboardRequestHandler clipboardHandler,
        VscodeRequestHandler vscodeHandler,
        ChromeRequestHandler chromeHandler,
        ImeRequestHandler imeHandler)
    {
        this.logger = logger;
        this.clipboardHandler = clipboardHandler;
        this.vscodeHandler = vscodeHandler;
        this.chromeHandler = chromeHandler;
        this.imeHandler = imeHandler;
    }

    public string HandleRequestJson(string requestJson, string transport, Action<string> reportFailure)
    {
        var stopwatch = Stopwatch.StartNew();
        string requestDomain = "host";
        string requestAction = "unknown";
        var requestCategory = "host_helper";
        string traceId = string.Empty;

        try
        {
            var request = JsonSerializer.Deserialize<HelperRequest>(requestJson, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            }) ?? throw new InvalidOperationException("request payload was empty");

            if (!string.Equals(request.MessageType, "request", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"unsupported message_type: {request.MessageType}");
            }

            requestDomain = string.IsNullOrWhiteSpace(request.Domain) ? "host" : request.Domain;
            requestAction = string.IsNullOrWhiteSpace(request.Action) ? "unknown" : request.Action;
            traceId = string.IsNullOrWhiteSpace(request.TraceId) ? Guid.NewGuid().ToString("N") : request.TraceId;
            requestCategory = ResolveCategory(requestDomain);

            logger.Info(requestCategory, "helper received request", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["domain"] = requestDomain,
                ["action"] = requestAction,
                ["transport"] = transport,
            });

            var outcome = Dispatch(requestDomain, requestAction, request.Payload, traceId);
            logger.Info(requestCategory, "helper completed request", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["domain"] = outcome.Domain,
                ["action"] = outcome.Action,
                ["status"] = outcome.Status,
                ["decision_path"] = outcome.DecisionPath,
                ["result_type"] = outcome.ResultType,
                ["pid"] = outcome.ProcessId?.ToString(),
                ["hwnd"] = outcome.WindowHandle?.ToString(),
                ["transport"] = transport,
                ["elapsed_ms"] = stopwatch.ElapsedMilliseconds.ToString(),
            });

            return JsonSerializer.Serialize(HelperResponse.Success(traceId, outcome));
        }
        catch (Exception ex)
        {
            reportFailure(ex.Message);
            logger.Error(requestCategory, "helper request failed", new Dictionary<string, string?>
            {
                ["trace_id"] = traceId,
                ["domain"] = requestDomain,
                ["action"] = requestAction,
                ["error"] = ex.Message,
                ["transport"] = transport,
                ["elapsed_ms"] = stopwatch.ElapsedMilliseconds.ToString(),
                ["exception_type"] = ex.GetType().FullName,
                ["hresult"] = ex.HResult.ToString("X8"),
            });

            return JsonSerializer.Serialize(HelperResponse.Failure(traceId, requestDomain, requestAction, "request_failed", ex.Message));
        }
    }

    private RequestOutcome Dispatch(string requestDomain, string requestAction, JsonElement payload, string traceId)
    {
        return (requestDomain, requestAction) switch
        {
            ("vscode", "focus_or_open") => vscodeHandler.FocusOrOpen(payload, traceId),
            ("chrome", "focus_or_start") => chromeHandler.FocusOrStart(payload, traceId),
            ("clipboard", "resolve_for_paste") => clipboardHandler.ResolveForPaste(traceId),
            ("clipboard", "write_text") => clipboardHandler.WriteText(payload, traceId),
            ("clipboard", "write_image_file") => clipboardHandler.WriteImageFile(payload, traceId),
            ("ime", "query_state") => imeHandler.QueryState(payload, traceId),
            _ => throw new InvalidOperationException($"unknown request route: {requestDomain}/{requestAction}"),
        };
    }

    private static string ResolveCategory(string requestDomain)
    {
        return requestDomain switch
        {
            "chrome" => "chrome",
            "clipboard" => "clipboard",
            "vscode" => "vscode",
            "ime" => "ime",
            _ => "host_helper",
        };
    }
}
