using System.Text.Json;
using Fyke.Client;

namespace Fyke.ViewModels;

public enum ReaderScrollbarMode { WhileScrolling, Always, Never }

public sealed record ReaderPreferences(bool FullText, bool LoadImages, ReaderTypography Typography,
    ReaderTextLayout TextLayout, ReaderScrollbarMode Scrollbars, bool InvalidConfig);

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
        var ui = !hasError && config.TryGetProperty("ui", out var savedUi) ? savedUi : default;
        var autoImages = ui.ValueKind == JsonValueKind.Object
            && ui.TryGetProperty("loadImages", out var images) && images.ValueKind == JsonValueKind.True;
        return new ReaderPreferences(fullText.GetBoolean(), autoImages, ReaderTypography.FromConfig(config),
            ReaderTextLayout.FromUi(ui), ReadScrollbars(ui), hasError);
    }

    private static ReaderScrollbarMode ReadScrollbars(JsonElement ui)
    {
        if (ui.ValueKind != JsonValueKind.Object || !ui.TryGetProperty("scrollbars", out var mode)
            || mode.ValueKind != JsonValueKind.String)
        {
            return ReaderScrollbarMode.WhileScrolling;
        }

        return mode.GetString() switch
        {
            "always" => ReaderScrollbarMode.Always,
            "never" => ReaderScrollbarMode.Never,
            _ => ReaderScrollbarMode.WhileScrolling,
        };
    }

    public Task SetFullTextAsync(bool enabled, CancellationToken ct) =>
        client.CallAsync("config.set", new { FullText = enabled }, ct);

    public Task SetLoadImagesAsync(bool enabled, CancellationToken ct) =>
        client.CallAsync("config.set", new { UiPatch = new Dictionary<string, bool> { ["loadImages"] = enabled } }, ct);

    public Task SetScrollbarsAsync(ReaderScrollbarMode mode, CancellationToken ct)
    {
        var value = mode switch
        {
            ReaderScrollbarMode.WhileScrolling => "scrolling",
            ReaderScrollbarMode.Always => "always",
            ReaderScrollbarMode.Never => "never",
            _ => throw new ArgumentOutOfRangeException(nameof(mode)),
        };
        return client.CallAsync("config.set", new { UiPatch = new { Scrollbars = value } }, ct);
    }

    public Task SetTextLayoutAsync(IReadOnlyDictionary<ReaderTextSetting, double> changes, CancellationToken ct) =>
        client.CallAsync("config.set", new
        {
            UiPatch = changes.ToDictionary(change => ReaderTextLayout.WireName(change.Key),
                change => ReaderTextLayout.Limit(change.Key, change.Value)),
        }, ct);

    public Task SetFontWeightAsync(ReaderFontRole role, int step, CancellationToken ct)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(step, -2);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(step, 2);
        var name = role switch
        {
            ReaderFontRole.Reading => "reading",
            ReaderFontRole.Title => "title",
            ReaderFontRole.Ui => "ui",
            ReaderFontRole.Code => "code",
            _ => throw new ArgumentOutOfRangeException(nameof(role)),
        };
        return client.CallAsync("config.set", new { UiPatch = new { Weights = new Dictionary<string, int> { [name] = step } } }, ct);
    }
}
