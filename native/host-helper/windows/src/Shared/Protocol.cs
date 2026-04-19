using System.Text.Json;
using System.Text.Json.Serialization;

namespace WezTerm.WindowsHostHelper;

internal sealed class HelperRequest
{
    [JsonPropertyName("version")]
    public int Version { get; init; } = 2;

    [JsonPropertyName("trace_id")]
    public string? TraceId { get; init; }

    [JsonPropertyName("message_type")]
    public string MessageType { get; init; } = "request";

    [JsonPropertyName("domain")]
    public string? Domain { get; init; }

    [JsonPropertyName("action")]
    public string? Action { get; init; }

    [JsonPropertyName("payload")]
    public JsonElement Payload { get; init; }
}

internal sealed class HelperResponse
{
    [JsonPropertyName("version")]
    public int Version { get; init; } = 2;

    [JsonPropertyName("trace_id")]
    public string TraceId { get; init; } = string.Empty;

    [JsonPropertyName("message_type")]
    public string MessageType { get; init; } = "response";

    [JsonPropertyName("domain")]
    public string Domain { get; init; } = string.Empty;

    [JsonPropertyName("action")]
    public string Action { get; init; } = string.Empty;

    [JsonPropertyName("ok")]
    public bool Ok { get; init; }

    [JsonPropertyName("status")]
    public string Status { get; init; } = string.Empty;

    [JsonPropertyName("decision_path")]
    public string DecisionPath { get; init; } = string.Empty;

    [JsonPropertyName("result_type")]
    public string? ResultType { get; init; }

    [JsonPropertyName("result")]
    public JsonElement? Result { get; init; }

    [JsonPropertyName("error")]
    public HelperError? Error { get; init; }

    public static HelperResponse Success(string traceId, RequestOutcome outcome)
    {
        return new HelperResponse
        {
            TraceId = traceId,
            Domain = outcome.Domain,
            Action = outcome.Action,
            Ok = true,
            Status = outcome.Status,
            DecisionPath = outcome.DecisionPath,
            ResultType = outcome.ResultType,
            Result = outcome.Result is null
                ? null
                : JsonSerializer.SerializeToElement(outcome.Result, outcome.Result.GetType()),
        };
    }

    public static HelperResponse Failure(string traceId, string domain, string action, string code, string message)
    {
        return new HelperResponse
        {
            TraceId = traceId,
            Domain = domain,
            Action = action,
            Ok = false,
            Status = "failed",
            DecisionPath = "error",
            Error = new HelperError
            {
                Code = code,
                Message = message,
            },
        };
    }
}

internal sealed class HelperWindowRefResult
{
    [JsonPropertyName("pid")]
    public int? Pid { get; init; }

    [JsonPropertyName("hwnd")]
    public long? Hwnd { get; init; }
}

internal sealed class HelperClipboardTextResult
{
    [JsonPropertyName("sequence")]
    public string? Sequence { get; init; }

    [JsonPropertyName("formats")]
    public string? Formats { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }
}

internal sealed class HelperClipboardImageResult
{
    [JsonPropertyName("sequence")]
    public string? Sequence { get; init; }

    [JsonPropertyName("formats")]
    public string? Formats { get; init; }

    [JsonPropertyName("windows_path")]
    public string? WindowsPath { get; init; }

    [JsonPropertyName("wsl_path")]
    public string? WslPath { get; init; }

    [JsonPropertyName("distro")]
    public string? Distro { get; init; }

    [JsonPropertyName("last_error")]
    public string? LastError { get; init; }
}

internal sealed class HelperError
{
    [JsonPropertyName("code")]
    public string Code { get; init; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; init; } = string.Empty;
}

internal sealed record RequestOutcome(
    string Domain,
    string Action,
    string Status,
    string DecisionPath,
    string? ResultType = null,
    object? Result = null,
    int? ProcessId = null,
    long? WindowHandle = null);
