using System.Text.Json;

namespace WezTerm.WindowsHostHelper;

internal sealed class ClipboardRequestHandler
{
    private readonly ClipboardService? clipboardService;
    private readonly StructuredLogger logger;

    public ClipboardRequestHandler(ClipboardService? clipboardService, StructuredLogger logger)
    {
        this.clipboardService = clipboardService;
        this.logger = logger;
    }

    public RequestOutcome ResolveForPaste(string traceId)
    {
        if (clipboardService == null)
        {
            throw new InvalidOperationException("clipboard service is unavailable");
        }

        var state = clipboardService.ResolveForPaste();
        logger.Info("clipboard", "resolved clipboard state for paste", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["kind"] = state.Kind,
            ["sequence"] = state.Sequence,
            ["formats"] = state.Formats,
            ["text_length"] = string.IsNullOrEmpty(state.TextValue) ? "0" : state.TextValue.Length.ToString(),
            ["windows_path"] = state.WindowsPath,
            ["wsl_path"] = state.WslPath,
            ["last_error"] = state.LastError,
            ["decision_path"] = "clipboard_service",
        });

        return new RequestOutcome(
            Domain: "clipboard",
            Action: "resolve_for_paste",
            Status: state.Kind == "image" ? "resolved_image" : "resolved_text",
            DecisionPath: "clipboard_service",
            ResultType: state.Kind == "image" ? "clipboard_image" : "clipboard_text",
            Result: state.Kind == "image"
                ? new HelperClipboardImageResult
                {
                    Sequence = state.Sequence,
                    Formats = state.Formats,
                    WindowsPath = state.WindowsPath,
                    WslPath = state.WslPath,
                    Distro = state.Distro,
                    LastError = state.LastError,
                }
                : new HelperClipboardTextResult
                {
                    Sequence = state.Sequence,
                    Formats = state.Formats,
                    Text = state.TextValue,
                });
    }

    public RequestOutcome WriteText(JsonElement payload, string traceId)
    {
        if (clipboardService == null)
        {
            throw new InvalidOperationException("clipboard service is unavailable");
        }

        var text = RequestPayloadReader.RequireString(payload, "text");
        var state = clipboardService.WriteText(text);
        logger.Info("clipboard", "wrote text to clipboard", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["text_length"] = text.Length.ToString(),
            ["kind"] = state.Kind,
            ["sequence"] = state.Sequence,
            ["formats"] = state.Formats,
            ["decision_path"] = "clipboard_service_write_text",
        });

        return new RequestOutcome(
            Domain: "clipboard",
            Action: "write_text",
            Status: "clipboard_written_text",
            DecisionPath: "clipboard_service_write_text",
            ResultType: "clipboard_text",
            Result: new HelperClipboardTextResult
            {
                Sequence = state.Sequence,
                Formats = state.Formats,
                Text = state.TextValue,
            });
    }

    public RequestOutcome WriteImageFile(JsonElement payload, string traceId)
    {
        if (clipboardService == null)
        {
            throw new InvalidOperationException("clipboard service is unavailable");
        }

        var imagePath = RequestPayloadReader.RequireString(payload, "image_path");
        var state = clipboardService.WriteImageFromFile(imagePath);
        logger.Info("clipboard", "wrote image file to clipboard", new Dictionary<string, string?>
        {
            ["trace_id"] = traceId,
            ["image_path"] = imagePath,
            ["kind"] = state.Kind,
            ["sequence"] = state.Sequence,
            ["formats"] = state.Formats,
            ["decision_path"] = "clipboard_service_write_image_file",
        });

        return new RequestOutcome(
            Domain: "clipboard",
            Action: "write_image_file",
            Status: "clipboard_written_image",
            DecisionPath: "clipboard_service_write_image_file",
            ResultType: "clipboard_image",
            Result: new HelperClipboardImageResult
            {
                Sequence = state.Sequence,
                Formats = state.Formats,
                WindowsPath = state.WindowsPath,
                WslPath = state.WslPath,
                Distro = state.Distro,
                LastError = state.LastError,
            });
    }
}
