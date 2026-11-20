using System.Text.Json;
using Fyke.ViewModels;
using Xunit;

namespace Fyke.ViewModels.Tests;

/// <summary>Fonts and radii resolve as <c>Prefs.currentFonts</c> and <c>Radii</c> do on the Mac.</summary>
public sealed class ReaderLookTests
{
    // The tokens, as the light theme has them.
    private static readonly ReaderLook Tokens = ReaderLook.Default;

    private static async Task<ReaderPreferences> Read(string json)
    {
        using var reply = JsonDocument.Parse(json);
        var root = reply.RootElement.Clone();
        return await new ReaderSettings(new FakeClient { OnCall = (_, _) => root }).ReadAsync(CancellationToken.None);
    }

    [Fact]
    public void ABuiltInThemeUsesTheTokens()
    {
        Assert.Equal(["Newsreader", "Inter", "JetBrains Mono"], [Tokens.Reading, Tokens.Ui, Tokens.Code]);
        var look = ReaderLook.Resolve("dark", [], new());
        Assert.Equal(Tokens.Reading, look.Reading);
        Assert.Equal(Tokens.Reading, look.Title);
        Assert.Equal(Tokens.Ui, look.Ui);
        Assert.Equal(Tokens.Code, look.Code);
        Assert.Equal(Tokens.Title, look.Title);
        Assert.Equal(Tokens.RadiusPanel, look.RadiusPanel);
    }

    [Fact]
    public void TerminalReadsInItsCodeFace()
    {
        var look = ReaderLook.Resolve("terminal", [], new());
        Assert.Equal(Tokens.Code, look.Reading);
        Assert.Equal(Tokens.Code, look.Title);
        Assert.Equal(Tokens.Ui, look.Ui);
    }

    [Fact]
    public async Task AThemeSetsFontsAndRadiiOverItsBaseAndChosenFontsGoOnTop()
    {
        var preferences = await Read("""
            {"full_text":true,"ui":{"theme":"custom-a","followSystem":false,
              "fonts":{"ui":"Segoe UI","code":""},
              "themes":[{"id":"custom-a","name":"A","base":"terminal",
                "fonts":{"title":"Georgia","code":7},
                "radii":{"panel":2,"sheet":-1,"control":"x"}}]}}
            """);
        var look = preferences.Look(systemIsDark: false);
        Assert.Equal(Tokens.Code, look.Reading); // from the terminal base
        Assert.Equal("Georgia", look.Title); // the theme's own
        Assert.Equal("Segoe UI", look.Ui); // chosen in Settings
        Assert.Equal(Tokens.Code, look.Code); // an empty or wrong value is ignored
        Assert.Equal(2, look.RadiusPanel);
        Assert.Equal(Tokens.RadiusSheet, look.RadiusSheet);
        Assert.Equal(Tokens.RadiusControl, look.RadiusControl);
    }

    [Fact]
    public async Task WithoutSavedFontsTheLookIsTheDefault()
    {
        var preferences = await Read("""{"full_text":true}""");
        Assert.Equal(ReaderLook.Default, preferences.Look(systemIsDark: false));
    }
}
