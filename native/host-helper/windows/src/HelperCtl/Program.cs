using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal static class HelperCtlProgram
{
    private static int Main(string[] args)
    {
        var stopwatch = Stopwatch.StartNew();
        var stage = "parse_args";
        if (!HelperCtlArguments.TryParseRequest(args, out var request, out var parseError))
        {
            return HelperCtlBootstrapLog.ExitWithError(parseError, stage, stopwatch.ElapsedMilliseconds);
        }

        try
        {
            stage = "decode_payload";
            var payloadJson = Encoding.UTF8.GetString(Convert.FromBase64String(request!.PayloadBase64));

            stage = "connect_pipe";
            using var client = NamedPipeTransport.Connect(request.PipeEndpoint, request.TimeoutMs);

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
            HelperCtlResponseWriter.WriteEnv(response, stopwatch.ElapsedMilliseconds);
            return response?.Ok == true ? 0 : 1;
        }
        catch (Exception ex)
        {
            return HelperCtlBootstrapLog.ExitWithError(ex, stage, stopwatch.ElapsedMilliseconds);
        }
    }
}
