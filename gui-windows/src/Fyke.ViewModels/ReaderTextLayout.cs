using System.Text.Json;

namespace Fyke.ViewModels;

public enum ReaderTextSetting { Size, LineSpacing, ColumnWidth }

/// <summary>The article layout stored in the shared reader profile.</summary>
public readonly record struct ReaderTextLayout(double Size, double LineSpacing, double ColumnWidth)
{
    public static ReaderTextLayout Default => new(19, 1.6, 640);

    public static (double Min, double Max, double Step) Range(ReaderTextSetting setting) => setting switch
    {
        ReaderTextSetting.Size => (14, 28, 1),
        ReaderTextSetting.LineSpacing => (1.2, 2, 0.1),
        ReaderTextSetting.ColumnWidth => (480, 800, 20),
        _ => throw new ArgumentOutOfRangeException(nameof(setting)),
    };

    public double Get(ReaderTextSetting setting) => setting switch
    {
        ReaderTextSetting.Size => Size,
        ReaderTextSetting.LineSpacing => LineSpacing,
        ReaderTextSetting.ColumnWidth => ColumnWidth,
        _ => throw new ArgumentOutOfRangeException(nameof(setting)),
    };

    public ReaderTextLayout With(ReaderTextSetting setting, double value) => setting switch
    {
        ReaderTextSetting.Size => this with { Size = Limit(setting, value) },
        ReaderTextSetting.LineSpacing => this with { LineSpacing = Limit(setting, value) },
        ReaderTextSetting.ColumnWidth => this with { ColumnWidth = Limit(setting, value) },
        _ => throw new ArgumentOutOfRangeException(nameof(setting)),
    };

    internal static string WireName(ReaderTextSetting setting) => setting switch
    {
        ReaderTextSetting.Size => "textSize",
        ReaderTextSetting.LineSpacing => "lineSpacing",
        ReaderTextSetting.ColumnWidth => "columnWidth",
        _ => throw new ArgumentOutOfRangeException(nameof(setting)),
    };

    internal static double Limit(ReaderTextSetting setting, double value)
    {
        var range = Range(setting);
        return double.IsFinite(value) ? Math.Clamp(value, range.Min, range.Max) : Default.Get(setting);
    }

    internal static ReaderTextLayout FromUi(JsonElement ui) => new(
        ReadProfileValue(ui, ReaderTextSetting.Size), ReadProfileValue(ui, ReaderTextSetting.LineSpacing),
        ReadProfileValue(ui, ReaderTextSetting.ColumnWidth));

    private static double ReadProfileValue(JsonElement ui, ReaderTextSetting setting) =>
        ui.ValueKind == JsonValueKind.Object && ui.TryGetProperty(WireName(setting), out var number)
            && number.ValueKind == JsonValueKind.Number && number.TryGetDouble(out var value)
                ? Limit(setting, value) : Default.Get(setting);
}
