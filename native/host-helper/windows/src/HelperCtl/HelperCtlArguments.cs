namespace WezTerm.WindowsHostHelper;

internal sealed record HelperCtlRequestArgs(
    string PipeEndpoint,
    string PayloadBase64,
    int TimeoutMs);

internal static class HelperCtlArguments
{
    public static bool TryParseRequest(string[] args, out HelperCtlRequestArgs? request, out string? error)
    {
        string? pipeEndpoint = null;
        string? payloadBase64 = null;
        var timeoutMs = 5000;
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
                    request = null;
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
                    request = null;
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
                    request = null;
                    return false;
                }

                index += 1;
            }
        }

        if (string.IsNullOrWhiteSpace(pipeEndpoint) || string.IsNullOrWhiteSpace(payloadBase64))
        {
            error = "usage: helperctl.exe request --pipe <endpoint> --payload-base64 <payload> [--timeout-ms 5000]";
            request = null;
            return false;
        }

        request = new HelperCtlRequestArgs(pipeEndpoint, payloadBase64, timeoutMs);
        return true;
    }
}
