using System.Text.Json;
using System.Text.Json.Nodes;
using Fyke.Client;

namespace Fyke.ViewModels;

public enum ReaderScrollbarMode { WhileScrolling, Always, Never }

public sealed record ReaderPreferences(bool FullText, bool LoadImages, ReaderTypography Typography,
    ReaderTextLayout TextLayout, ReaderScrollbarMode Scrollbars, IReadOnlyList<long> CollapsedFolderIds,
    ReaderAppearance Appearance, bool InvalidConfig);

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
            ReaderTextLayout.FromUi(ui), ReadScrollbars(ui), ReadCollapsedFolders(ui), ReaderAppearance.FromUi(ui), hasError);
    }

    private static long[] ReadCollapsedFolders(JsonElement ui)
    {
        if (ui.ValueKind != JsonValueKind.Object || !ui.TryGetProperty("collapsedFolders", out var folders)
            || folders.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        var ids = new HashSet<long>();
        foreach (var folder in folders.EnumerateArray())
        {
            if (folder.ValueKind == JsonValueKind.Number && folder.TryGetInt64(out var id) && id > 0)
            {
                ids.Add(id);
            }
        }

        return ids.Order().ToArray();
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
        client.CallAsync("config.set", new JsonObject { ["full_text"] = enabled }, ct);

    public Task SetLoadImagesAsync(bool enabled, CancellationToken ct) =>
        PatchUiAsync(new JsonObject { ["loadImages"] = enabled }, ct);

    public Task SetCollapsedFoldersAsync(IReadOnlyList<long> ids, CancellationToken ct) =>
        PatchUiAsync(new JsonObject { ["collapsedFolders"] = Wire.Ids(ids) }, ct);

    public Task SetFollowSystemAsync(bool enabled, CancellationToken ct) =>
        PatchUiAsync(new JsonObject { ["followSystem"] = enabled }, ct);

    public Task SetThemeAsync(ReaderThemeSlot slot, string theme, CancellationToken ct)
    {
        var patch = new JsonObject { [ReaderAppearance.WireName(slot)] = theme };
        if (slot == ReaderThemeSlot.Fixed)
        {
            patch["followSystem"] = false;
        }

        return PatchUiAsync(patch, ct);
    }

    public Task SetScrollbarsAsync(ReaderScrollbarMode mode, CancellationToken ct)
    {
        var value = mode switch
        {
            ReaderScrollbarMode.WhileScrolling => "scrolling",
            ReaderScrollbarMode.Always => "always",
            ReaderScrollbarMode.Never => "never",
            _ => throw new ArgumentOutOfRangeException(nameof(mode)),
        };
        return PatchUiAsync(new JsonObject { ["scrollbars"] = value }, ct);
    }

    public Task SetTextLayoutAsync(IReadOnlyDictionary<ReaderTextSetting, double> changes, CancellationToken ct)
    {
        var patch = new JsonObject();
        foreach (var (setting, value) in changes)
        {
            patch[ReaderTextLayout.WireName(setting)] = ReaderTextLayout.Limit(setting, value);
        }

        return PatchUiAsync(patch, ct);
    }

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
        return PatchUiAsync(new JsonObject { ["weights"] = new JsonObject { [name] = step } }, ct);
    }

    // The ui section keeps the macOS app's camelCase keys, so a patch names them as written.
    private Task<JsonElement> PatchUiAsync(JsonObject patch, CancellationToken ct) =>
        client.CallAsync("config.set", new JsonObject { ["ui_patch"] = patch }, ct);
}
