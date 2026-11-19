using System.Text.Json;

namespace Fyke.ViewModels;

public enum ReaderFontRole { Reading, Title, Ui, Code }

/// <summary>The shared macOS and Windows font-weight steps stored under ui.weights.</summary>
public readonly record struct ReaderTypography(int Reading, int Title, int Ui, int Code)
{
    public const ushort Regular = 400;
    public const ushort Medium = 500;
    public const ushort Semibold = 600;

    public int StepFor(ReaderFontRole role) => role switch
    {
        ReaderFontRole.Reading => Reading,
        ReaderFontRole.Title => Title,
        ReaderFontRole.Ui => Ui,
        ReaderFontRole.Code => Code,
        _ => throw new ArgumentOutOfRangeException(nameof(role)),
    };

    public static ReaderTypography FromConfig(JsonElement config)
    {
        if (config.ValueKind != JsonValueKind.Object
            || (config.TryGetProperty("config_error", out var error) && error.ValueKind == JsonValueKind.String)
            || !config.TryGetProperty("ui", out var ui) || ui.ValueKind != JsonValueKind.Object
            || !ui.TryGetProperty("weights", out var weights) || weights.ValueKind != JsonValueKind.Object)
        {
            return default;
        }

        return new(Step("reading"), Step("title"), Step("ui"), Step("code"));

        int Step(string key) => weights.TryGetProperty(key, out var value)
            && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var step)
            ? (int)Math.Clamp(step, -2, 2)
            : 0;
    }

    /// <summary>Moves by the same named weights as SwiftUI, from ultralight to black.</summary>
    public static ushort Shift(ushort baseline, int step) =>
        (ushort)Math.Clamp(baseline + Math.Clamp(step, -2, 2) * 100, 100, 900);
}
