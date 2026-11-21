using System.Text.Json;

namespace Fyke.ViewModels;

/// <summary>A font family for each kind of text. Null leaves the kind to whatever is under it.</summary>
public sealed record ReaderFonts(string? Reading = null, string? Title = null, string? Ui = null, string? Code = null)
{
    internal static ReaderFonts FromJson(JsonElement value) =>
        value.ValueKind != JsonValueKind.Object
            ? new()
            : new(Text(value, "reading"), Text(value, "title"), Text(value, "ui"), Text(value, "code"));

    private static string? Text(JsonElement value, string name) =>
        value.TryGetProperty(name, out var text) && text.ValueKind == JsonValueKind.String && text.GetString() is { Length: > 0 } family
            ? family
            : null;

    /// <summary>These fonts, with what this leaves unset taken from <paramref name="under"/>.</summary>
    public ReaderFonts Over(ReaderFonts under) =>
        new(Reading ?? under.Reading, Title ?? under.Title, Ui ?? under.Ui, Code ?? under.Code);
}

/// <summary>Corner radii in pixels. Null leaves the token's.</summary>
public sealed record ReaderRadii(double? Control = null, double? Panel = null, double? Sheet = null)
{
    internal static ReaderRadii FromJson(JsonElement value) =>
        value.ValueKind != JsonValueKind.Object
            ? new()
            : new(Number(value, "control"), Number(value, "panel"), Number(value, "sheet"));

    private static double? Number(JsonElement value, string name) =>
        value.TryGetProperty(name, out var number) && number.ValueKind == JsonValueKind.Number
            && number.TryGetDouble(out var radius) && radius >= 0
            ? radius
            : null;
}

/// <summary>
/// The typefaces and corner radii on screen: the active theme's, under any font chosen for
/// the moment in Settings. Resolved as <c>Prefs.fonts(of:)</c>, <c>currentFonts</c> and
/// <c>Radii</c> do in <c>gui/Sources/Reader/Prefs.swift</c>, so a theme looks the same on both.
/// </summary>
public sealed record ReaderLook(string Reading, string Title, string Ui, string Code,
    double RadiusControl, double RadiusPanel, double RadiusSheet)
{
    /// <summary>The fonts bundled with the app. Any other family is the system's, if installed.</summary>
    public static IReadOnlyList<string> Bundled { get; } = [Tokens.FontReading, Tokens.FontUi, Tokens.FontCode];

    public static ReaderLook Default { get; } = Resolve("light", [], new());

    /// <summary>A built-in theme's fonts. Terminal's look is its typeface as much as its colours.</summary>
    public static ReaderFonts BuiltInFonts(string id)
    {
        var text = id == "terminal" ? Tokens.FontCode : Tokens.FontReading;
        return new(text, text, Tokens.FontUi, Tokens.FontCode);
    }

    public static ReaderLook Resolve(string id, IReadOnlyList<ReaderCustomTheme> themes, ReaderFonts chosen)
    {
        var custom = themes.FirstOrDefault(theme => theme.Id == id);
        var theme = (custom?.Fonts ?? new()).Over(BuiltInFonts(custom?.Base ?? id));
        var fonts = chosen.Over(theme);
        var radii = custom?.Radii ?? new();
        return new(fonts.Reading!, fonts.Title!, fonts.Ui!, fonts.Code!,
            radii.Control ?? Tokens.RadiusControl, radii.Panel ?? Tokens.RadiusPanel, radii.Sheet ?? Tokens.RadiusSheet);
    }
}
