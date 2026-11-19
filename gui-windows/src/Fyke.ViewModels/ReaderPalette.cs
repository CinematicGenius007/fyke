using System.Globalization;
using System.Text.Json;

namespace Fyke.ViewModels;

/// <summary>A theme the user made on either platform, saved under <c>ui.themes</c>: a built-in
/// base with some of its colours replaced.</summary>
public sealed record ReaderCustomTheme(string Id, string Name, string Base, IReadOnlyDictionary<string, uint> Colors)
{
    internal static IReadOnlyList<ReaderCustomTheme> FromUi(JsonElement ui)
    {
        if (ui.ValueKind != JsonValueKind.Object || !ui.TryGetProperty("themes", out var themes)
            || themes.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        var found = new List<ReaderCustomTheme>();
        foreach (var theme in themes.EnumerateArray())
        {
            if (theme.ValueKind != JsonValueKind.Object || Text(theme, "id") is not { Length: > 0 } id
                || Text(theme, "name") is not { } name || found.Exists(other => other.Id == id))
            {
                continue;
            }

            var colors = new Dictionary<string, uint>(StringComparer.Ordinal);
            if (theme.TryGetProperty("tokens", out var tokens) && tokens.ValueKind == JsonValueKind.Object)
            {
                foreach (var token in ReaderPalette.TokenNames)
                {
                    if (Text(tokens, token) is { } hex && ReaderPalette.ParseHex(hex) is uint color)
                    {
                        colors[token] = color;
                    }
                }
            }

            found.Add(new ReaderCustomTheme(id, name, Text(theme, "base") ?? "light", colors));
        }

        return found;

        static string? Text(JsonElement value, string name) =>
            value.TryGetProperty(name, out var text) && text.ValueKind == JsonValueKind.String ? text.GetString() : null;
    }
}

/// <summary>The thirteen colours of one theme, each as RGBA like <c>gui/Sources/Reader/Tokens.swift</c>.</summary>
/// <remarks>Derives Newsprint, Terminal and the user's themes exactly as <c>gui/Sources/Reader/Theme.swift</c>
/// does, so a theme looks the same on both platforms.</remarks>
public sealed record ReaderPalette(string Id, bool IsDark,
    uint Ground, uint Surface, uint Selected, uint SelectedStrong, uint Hairline, uint Control,
    uint Ink, uint InkSoft, uint Muted, uint Unread, uint Read, uint OnAccent, uint Scrim)
{
    public static IReadOnlyList<string> BuiltIns { get; } = ["light", "dark", "newsprint", "terminal"];

    /// <summary>The token names used in <c>ui.themes[].tokens</c>, in the order the Mac lists them.</summary>
    public static IReadOnlyList<string> TokenNames { get; } =
        ["ground", "surface", "selected", "selectedStrong", "hairline", "control",
         "ink", "inkSoft", "muted", "unread", "read", "onAccent", "scrim"];

    private const uint Black = 0x000000FF;

    public static ReaderPalette Light { get; } = new("light", false,
        Tokens.ColorLightGround, Tokens.ColorLightSurface, Tokens.ColorLightSelected, Tokens.ColorLightSelectedStrong,
        Tokens.ColorLightHairline, Tokens.ColorLightControl, Tokens.ColorLightInk, Tokens.ColorLightInkSoft,
        Tokens.ColorLightMuted, Tokens.ColorLightUnread, Tokens.ColorLightRead, Tokens.ColorLightOnAccent, Tokens.ColorLightScrim);

    public static ReaderPalette Dark { get; } = new("dark", true,
        Tokens.ColorDarkGround, Tokens.ColorDarkSurface, Tokens.ColorDarkSelected, Tokens.ColorDarkSelectedStrong,
        Tokens.ColorDarkHairline, Tokens.ColorDarkControl, Tokens.ColorDarkInk, Tokens.ColorDarkInkSoft,
        Tokens.ColorDarkMuted, Tokens.ColorDarkUnread, Tokens.ColorDarkRead, Tokens.ColorDarkOnAccent, Tokens.ColorDarkScrim);

    /// <summary>Paper defines only three colours for Newsprint. The rest follow from them.</summary>
    public static ReaderPalette Newsprint { get; } = Light with
    {
        Id = "newsprint",
        Ground = Tokens.ColorNewsprintGround,
        Unread = Tokens.ColorNewsprintUnread,
        Read = Tokens.ColorNewsprintRead,
        Surface = Mix(Tokens.ColorNewsprintGround, Black, 0.04),
        Selected = Mix(Tokens.ColorNewsprintGround, Black, 0.07),
        SelectedStrong = Mix(Tokens.ColorNewsprintGround, Black, 0.11),
        Hairline = Mix(Tokens.ColorNewsprintGround, Black, 0.11),
        Muted = Tokens.ColorNewsprintRead,
        OnAccent = Tokens.ColorNewsprintGround,
    };

    /// <summary>Paper defines only three colours for Terminal. The rest follow from them.</summary>
    public static ReaderPalette Terminal { get; } = Dark with
    {
        Id = "terminal",
        Ground = Tokens.ColorTerminalGround,
        Unread = Tokens.ColorTerminalUnread,
        Read = Tokens.ColorTerminalRead,
        Ink = Tokens.ColorTerminalUnread,
        InkSoft = Mix(Tokens.ColorTerminalUnread, Black, 0.2),
        Muted = Tokens.ColorTerminalRead,
        Surface = Mix(Tokens.ColorTerminalUnread, Black, 0.93),
        Selected = Mix(Tokens.ColorTerminalUnread, Black, 0.86),
        SelectedStrong = Mix(Tokens.ColorTerminalUnread, Black, 0.8),
        Hairline = Mix(Tokens.ColorTerminalUnread, Black, 0.8),
        Control = Tokens.ColorTerminalRead,
        OnAccent = Tokens.ColorTerminalGround,
    };

    /// <summary>Each token's name, as the Windows resources spell it, with its colour.</summary>
    public IEnumerable<(string Token, uint Rgba)> Colors =>
    [
        ("Ground", Ground), ("Surface", Surface), ("Selected", Selected), ("SelectedStrong", SelectedStrong),
        ("Hairline", Hairline), ("Control", Control), ("Ink", Ink), ("InkSoft", InkSoft), ("Muted", Muted),
        ("Unread", Unread), ("Read", Read), ("OnAccent", OnAccent), ("Scrim", Scrim),
    ];

    public static ReaderPalette Named(string id) => id switch
    {
        "dark" => Dark,
        "newsprint" => Newsprint,
        "terminal" => Terminal,
        _ => Light,
    };

    /// <summary>Any theme, built-in or the user's. A name that is neither, such as a deleted theme, is Light.</summary>
    public static ReaderPalette Resolve(string id, IReadOnlyList<ReaderCustomTheme> themes)
    {
        foreach (var theme in themes)
        {
            if (theme.Id == id)
            {
                return Named(theme.Base).Applying(theme.Colors) with { Id = id };
            }
        }

        return Named(id);
    }

    /// <summary>The theme's name as the pickers show it, as macOS names it.</summary>
    public static string DisplayName(string id, IReadOnlyList<ReaderCustomTheme> themes)
    {
        foreach (var theme in themes)
        {
            if (theme.Id == id)
            {
                return theme.Name;
            }
        }

        return id.Length == 0 ? id : char.ToUpperInvariant(id[0]) + id[1..];
    }

    public ReaderPalette Applying(IReadOnlyDictionary<string, uint> colors)
    {
        var palette = this;
        foreach (var (token, color) in colors)
        {
            palette = token switch
            {
                "ground" => palette with { Ground = color },
                "surface" => palette with { Surface = color },
                "selected" => palette with { Selected = color },
                "selectedStrong" => palette with { SelectedStrong = color },
                "hairline" => palette with { Hairline = color },
                "control" => palette with { Control = color },
                "ink" => palette with { Ink = color },
                "inkSoft" => palette with { InkSoft = color },
                "muted" => palette with { Muted = color },
                "unread" => palette with { Unread = color },
                "read" => palette with { Read = color },
                "onAccent" => palette with { OnAccent = color },
                "scrim" => palette with { Scrim = color },
                _ => palette,
            };
        }

        return palette;
    }

    /// <summary><c>#RRGGBB</c> or <c>#RRGGBBAA</c>, the <c>#</c> optional, as macOS reads it.</summary>
    public static uint? ParseHex(string text)
    {
        var digits = text.StartsWith('#') ? text[1..] : text;
        if (digits.Length is not (6 or 8)
            || !uint.TryParse(digits, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var value))
        {
            return null;
        }

        return digits.Length == 6 ? (value << 8) | 0xFF : value;
    }

    /// <summary>Mixes two RGBA colours in Oklab, as SwiftUI's <c>Color.mix(with:by:)</c> does by default.</summary>
    public static uint Mix(uint from, uint to, double fraction)
    {
        var a = ToOklab(from);
        var b = ToOklab(to);
        double Lerp(double x, double y) => x + (y - x) * fraction;
        var (r, g, bl) = FromOklab(Lerp(a.L, b.L), Lerp(a.A, b.A), Lerp(a.B, b.B));
        var alpha = Lerp((from & 0xFF) / 255.0, (to & 0xFF) / 255.0);
        return (Byte(Encode(r)) << 24) | (Byte(Encode(g)) << 16) | (Byte(Encode(bl)) << 8) | Byte(alpha);
    }

    private static (double L, double A, double B) ToOklab(uint rgba)
    {
        var r = Decode(((rgba >> 24) & 0xFF) / 255.0);
        var g = Decode(((rgba >> 16) & 0xFF) / 255.0);
        var b = Decode(((rgba >> 8) & 0xFF) / 255.0);
        var l = Math.Cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
        var m = Math.Cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
        var s = Math.Cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
    }

    private static (double R, double G, double B) FromOklab(double lightness, double a, double b)
    {
        var l = Math.Pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3);
        var m = Math.Pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3);
        var s = Math.Pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3);
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    }

    private static double Decode(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);

    private static double Encode(double c)
    {
        c = Math.Clamp(c, 0, 1);
        return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;
    }

    private static uint Byte(double unit) => (uint)Math.Round(Math.Clamp(unit, 0, 1) * 255);
}
