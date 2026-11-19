using System.Text.Json;

namespace Fyke.ViewModels;

public enum ReaderThemeSlot { Fixed, Day, Night }

/// <summary>Appearance slots shared by the macOS and Windows readers.</summary>
public readonly record struct ReaderAppearance(string Theme, bool FollowSystem, string DayTheme, string NightTheme)
{
    public static ReaderAppearance Default => new("light", true, "light", "dark");

    public string ActiveTheme(bool systemIsDark) => FollowSystem ? (systemIsDark ? NightTheme : DayTheme) : Theme;

    public string ThemeFor(ReaderThemeSlot slot) => slot switch
    {
        ReaderThemeSlot.Fixed => Theme,
        ReaderThemeSlot.Day => DayTheme,
        ReaderThemeSlot.Night => NightTheme,
        _ => throw new ArgumentOutOfRangeException(nameof(slot)),
    };

    internal static string WireName(ReaderThemeSlot slot) => slot switch
    {
        ReaderThemeSlot.Fixed => "theme",
        ReaderThemeSlot.Day => "dayTheme",
        ReaderThemeSlot.Night => "nightTheme",
        _ => throw new ArgumentOutOfRangeException(nameof(slot)),
    };

    internal static ReaderAppearance FromUi(JsonElement ui)
    {
        if (ui.ValueKind != JsonValueKind.Object)
        {
            return Default;
        }

        return new ReaderAppearance(ReadTheme(ReaderThemeSlot.Fixed),
            !ui.TryGetProperty("followSystem", out var follows) || follows.ValueKind != JsonValueKind.False,
            ReadTheme(ReaderThemeSlot.Day), ReadTheme(ReaderThemeSlot.Night));

        string ReadTheme(ReaderThemeSlot slot) => ui.TryGetProperty(WireName(slot), out var value)
            && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } theme
                ? theme : Default.ThemeFor(slot);
    }
}
