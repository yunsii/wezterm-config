using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed class ImeRequestHandler
{
    private readonly StructuredLogger logger;

    public ImeRequestHandler(StructuredLogger logger)
    {
        this.logger = logger;
    }

    public RequestOutcome QueryState(JsonElement payload, string traceId)
    {
        var sample = ImeStateSampler.Sample();
        logger.Info("ime", "ime query resolved", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["lang"] = sample.Lang,
            ["mode"] = sample.Mode,
            ["reason"] = sample.Reason,
            ["decision_path"] = sample.DecisionPath,
        });
        return new RequestOutcome(
            Domain: "ime",
            Action: "query_state",
            Status: "ok",
            DecisionPath: sample.DecisionPath,
            ResultType: "ime_state",
            Result: new HelperImeStateResult
            {
                Mode = sample.Mode,
                Lang = sample.Lang,
                Reason = sample.Reason,
            });
    }
}
