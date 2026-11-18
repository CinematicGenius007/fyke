using System.Text.Json;
using Fyke.Client;

namespace Fyke.ViewModels;

public sealed record ReaderPreferences(bool FullText, bool LoadImages, ReaderTypography Typography, bool InvalidConfig);

public sealed class ReaderSettings(IDaemonClient client)
{
    public async Task<ReaderPreferences> ReadAsync(CancellationToken ct)
    {
        var config = await client.CallAsync("config.get", null, ct).ConfigureAwait(false);
        if (config.ValueKind != JsonValueKind.Object || !config.TryGetProperty("full_text", out var fullText)
            || fullText.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
        {
            throw new DaemonProtocolException("The daemon did not return the full-text setting.");
        }

        var hasError = config.TryGetProperty("config_error", out var error) && error.ValueKind == JsonValueKind.String;
        var autoImages = !hasError && config.TryGetProperty("ui", out var ui) && ui.ValueKind == JsonValueKind.Object
            && ui.TryGetProperty("loadImages", out var images) && images.ValueKind == JsonValueKind.True;
        return new ReaderPreferences(fullText.GetBoolean(), autoImages, ReaderTypography.FromConfig(config), hasError);
    }

    public Task SetFullTextAsync(bool enabled, CancellationToken ct) =>
        client.CallAsync("config.set", new { FullText = enabled }, ct);

    public Task SetLoadImagesAsync(bool enabled, CancellationToken ct) =>
        client.CallAsync("config.set", new { UiPatch = new Dictionary<string, bool> { ["loadImages"] = enabled } }, ct);
}
