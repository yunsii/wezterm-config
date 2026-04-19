using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal static class HelperCtlResponseWriter
{
    public static void WriteEnv(HelperResponse? response, long elapsedMs)
    {
        if (response == null)
        {
            return;
        }

        var lines = new List<string>
        {
            $"version={response.Version}",
            $"message_type={Sanitize(response.MessageType)}",
            $"domain={Sanitize(response.Domain)}",
            $"action={Sanitize(response.Action)}",
            $"ok={(response.Ok ? "1" : "0")}",
            $"trace_id={Sanitize(response.TraceId)}",
            $"status={Sanitize(response.Status)}",
            $"decision_path={Sanitize(response.DecisionPath)}",
            $"helperctl_elapsed_ms={elapsedMs}",
        };

        if (!string.IsNullOrWhiteSpace(response.ResultType))
        {
            lines.Add($"result_type={Sanitize(response.ResultType)}");
        }

        AppendResultLines(lines, response.Result);

        if (!string.IsNullOrWhiteSpace(response.Error?.Code))
        {
            lines.Add($"error_code={Sanitize(response.Error.Code)}");
        }

        if (!string.IsNullOrWhiteSpace(response.Error?.Message))
        {
            lines.Add($"error_message={Sanitize(response.Error.Message)}");
        }

        Console.Out.Write(string.Join(Environment.NewLine, lines));
        Console.Out.Write(Environment.NewLine);
    }

    private static void AppendResultLines(List<string> lines, JsonElement? result)
    {
        if (result is not JsonElement element || element.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        foreach (var property in element.EnumerateObject())
        {
            var key = $"result_{property.Name}";
            var value = property.Value.ValueKind switch
            {
                JsonValueKind.String => property.Value.GetString(),
                JsonValueKind.Number => property.Value.ToString(),
                JsonValueKind.True => "1",
                JsonValueKind.False => "0",
                JsonValueKind.Null => null,
                _ => property.Value.ToString(),
            };

            if (!string.IsNullOrWhiteSpace(value))
            {
                lines.Add($"{key}={Sanitize(value)}");
            }
        }
    }

    private static string Sanitize(string? value)
    {
        return (value ?? string.Empty).Replace("\r", " ").Replace("\n", " ").Trim();
    }
}
