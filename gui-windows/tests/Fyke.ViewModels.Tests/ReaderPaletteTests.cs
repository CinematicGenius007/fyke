using System.Text.Json;
using Fyke.ViewModels;
using Xunit;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderPaletteTests
{
    // The expected values are what SwiftUI's Color.mix(with:by:) gives on macOS for the same
    // inputs, so the derived themes match the Mac reader.
    [Theory]
    [InlineData(0xF1EEE6FFu, 0.04, 0xE4E1DAFFu)]
    [InlineData(0xF1EEE6FFu, 0.07, 0xDBD8D1FFu)]
    [InlineData(0xF1EEE6FFu, 0.11, 0xCECCC5FFu)]
    [InlineData(0x39FF88FFu, 0.2, 0x28BE63FFu)]
    [InlineData(0x39FF88FFu, 0.8, 0x011606FFu)]
    [InlineData(0x39FF88FFu, 0.86, 0x000902FFu)]
    [InlineData(0x39FF88FFu, 0.93, 0x000100FFu)]
    public void MixesTowardBlackAsSwiftUIDoes(uint color, double fraction, uint expected) =>
        Assert.Equal(expected, ReaderPalette.Mix(color, 0x000000FF, fraction));

    [Fact]
    public void DerivesNewsprintFromItsThreePaperColours()
    {
        var newsprint = ReaderPalette.Newsprint;
        Assert.False(newsprint.IsDark);
        Assert.Equal(0xF1EEE6FFu, newsprint.Ground);
        Assert.Equal(0xE4E1DAFFu, newsprint.Surface);
        Assert.Equal(0xCECCC5FFu, newsprint.Hairline);
        Assert.Equal(newsprint.Read, newsprint.Muted);
        Assert.Equal(newsprint.Ground, newsprint.OnAccent);
        Assert.Equal(ReaderPalette.Light.Ink, newsprint.Ink);
    }

    [Fact]
    public void DerivesTerminalFromItsThreePaperColours()
    {
        var terminal = ReaderPalette.Terminal;
        Assert.True(terminal.IsDark);
        Assert.Equal(0x000000FFu, terminal.Ground);
        Assert.Equal(0x39FF88FFu, terminal.Ink);
        Assert.Equal(0x28BE63FFu, terminal.InkSoft);
        Assert.Equal(0x000100FFu, terminal.Surface);
        Assert.Equal(terminal.Read, terminal.Control);
        Assert.Equal(ReaderPalette.Dark.Scrim, terminal.Scrim);
    }

    [Fact]
    public async Task ReadsTheUsersThemesAndPutsTheirColoursOverTheBase()
    {
        using var reply = JsonDocument.Parse("""
            {"full_text":true,"ui":{"theme":"custom-ink","followSystem":false,"themes":[
              {"id":"custom-ink","name":"Ink","base":"dark","tokens":{"unread":"#FF8800","scrim":"#00000040","ink":"nonsense"}},
              {"id":"custom-ink","name":"Duplicate"},
              {"name":"No id"},
              {"id":"custom-plain","name":"Plain"}
            ]}}
            """);
        var preferences = await new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement })
            .ReadAsync(CancellationToken.None);
        var themes = preferences.Themes;

        Assert.Equal(["custom-ink", "custom-plain"], themes.Select(theme => theme.Id));
        var ink = preferences.Palette(systemIsDark: false);
        Assert.Equal("custom-ink", ink.Id);
        Assert.True(ink.IsDark);
        Assert.Equal(0xFF8800FFu, ink.Unread);
        Assert.Equal(0x00000040u, ink.Scrim);
        Assert.Equal(ReaderPalette.Dark.Ink, ink.Ink);
        Assert.Equal(ReaderPalette.Light with { Id = "custom-plain" }, ReaderPalette.Resolve("custom-plain", themes));
        Assert.Equal("Ink", ReaderPalette.DisplayName("custom-ink", themes));
        Assert.Equal("Newsprint", ReaderPalette.DisplayName("newsprint", themes));
    }

    [Fact]
    public void AThemeThatNoLongerExistsIsLight()
    {
        Assert.Same(ReaderPalette.Light, ReaderPalette.Resolve("custom-deleted", []));
        Assert.Same(ReaderPalette.Terminal, ReaderPalette.Resolve("terminal", []));
    }

    [Theory]
    [InlineData("#0A3CFF", 0x0A3CFFFFu)]
    [InlineData("0a3cff80", 0x0A3CFF80u)]
    [InlineData("#0A3CF", null)]
    [InlineData("#GGGGGG", null)]
    [InlineData("", null)]
    public void ReadsHexColoursAsMacOSDoes(string text, uint? expected) =>
        Assert.Equal(expected, ReaderPalette.ParseHex(text));
}
