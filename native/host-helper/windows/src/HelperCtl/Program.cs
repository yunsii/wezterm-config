using System.Text;
using System.Text.Json;
using System.Diagnostics;

namespace WezTerm.WindowsHostHelper;

internal static class HelperCtlProgram
{
    private static int Main(string[] args)
    {
        var stopwatch = Stopwatch.StartNew();
        var stage = "parse_args";
        if (!TryParseRequestArgs(args, out var pipeEndpoint, out var payloadBase64, out var timeoutMs, out var parseError))
        {
            return ExitWithError(parseError, stage, stopwatch.ElapsedMilliseconds);
        }

        try
        {
            stage = "decode_payload";
            var payloadJson = Encoding.UTF8.GetString(Convert.FromBase64String(payloadBase64!));

            stage = "connect_pipe";
            using var client = NamedPipeTransport.Connect(pipeEndpoint!, timeoutMs);

            stage = "write_request";
            NamedPipeTransport.WriteMessage(client, payloadJson);

            stage = "read_response";
            var responseJson = NamedPipeTransport.ReadMessage(client);

            stage = "parse_response";
            var response = JsonSerializer.Deserialize<HelperResponse>(responseJson, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true,
            });

            stage = "write_env";
            WriteResponseEnv(response, stopwatch.ElapsedMilliseconds);
            return response?.Ok == true ? 0 : 1;
        }
        catch (Exception ex)
        {
            return ExitWithError(ex, stage, stopwatch.ElapsedMilliseconds);
        }
    }

    private static bool TryParseRequestArgs(string[] args, out string? pipeEndpoint, out string? payloadBase64, out int timeoutMs, out string? error)
    {
        pipeEndpoint = null;
        payloadBase64 = null;
        timeoutMs = 5000;
        error = null;

        for (var index = 0; index < args.Length; index += 1)
        {
            var arg = args[index];
            if (string.Equals(arg, "request", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (string.Equals(arg, "--pipe", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 >= args.Length)
                {
                    error = "missing value for --pipe";
                    return false;
                }

                pipeEndpoint = args[index + 1];
                index += 1;
                continue;
            }

            if (string.Equals(arg, "--payload-base64", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 >= args.Length)
                {
                    error = "missing value for --payload-base64";
                    return false;
                }

                payloadBase64 = args[index + 1];
                index += 1;
                continue;
            }

            if (string.Equals(arg, "--timeout-ms", StringComparison.OrdinalIgnoreCase))
            {
                if (index + 1 >= args.Length || !int.TryParse(args[index + 1], out timeoutMs) || timeoutMs <= 0)
                {
                    error = "missing or invalid value for --timeout-ms";
                    return false;
                }

                index += 1;
            }
        }

        if (string.IsNullOrWhiteSpace(pipeEndpoint) || string.IsNullOrWhiteSpace(payloadBase64))
        {
            error = "usage: helperctl.exe request --pipe <endpoint> --payload-base64 <payload> [--timeout-ms 5000]";
            return false;
        }

        return true;
    }

    private static void WriteResponseEnv(HelperResponse? response, long elapsedMs)
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

    private static int ExitWithError(Exception ex, string stage, long elapsedMs)
    {
        return ExitWithError(
            $"request failed at {stage}: {ex.Message}",
            stage,
            elapsedMs,
            ex.GetType().FullName,
            ex.HResult.ToString("X8"));
    }

    private static int ExitWithError(string? message, string stage, long elapsedMs, string? exceptionType = null, string? hresult = null)
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
            File.AppendAllText(
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wezterm-runtime-helper", "helperctl-bootstrap.log"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {fullText}{Environment.NewLine}",
                new UTF8Encoding(false));
        }
        catch
        {
        }

        return 1;
    }
}
