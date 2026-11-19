using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderSettingsTests
{
    [Theory]
    [InlineData("null", "null", false, false)]
    [InlineData("{\"loadImages\":\"true\"}", "null", false, false)]
    [InlineData("{\"loadImages\":true}", "null", true, false)]
    [InlineData("{\"loadImages\":true}", "\"SyntaxError\"", false, true)]
    public async Task AutomaticImagesRequireAnExplicitSavedBoolean(string ui, string error, bool automatic, bool invalid)
    {
        using var reply = JsonDocument.Parse($$"""{"full_text":false,"ui":{{ui}},"config_error":{{error}}}""");
        var settings = new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement });

        var preferences = await settings.ReadAsync(CancellationToken.None);

        Assert.False(preferences.FullText);
        Assert.Equal(automatic, preferences.LoadImages);
        Assert.Equal(invalid, preferences.InvalidConfig);
    }

    [Fact]
    public async Task WritesOneSettingAtATimeAndPreservesTheSharedImageKey()
    {
        var calls = new List<string>();
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                calls.Add(JsonSerializer.Serialize(parameters, wire));
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        await settings.SetFullTextAsync(false, CancellationToken.None);
        await settings.SetLoadImagesAsync(true, CancellationToken.None);

        Assert.Equal(["{\"full_text\":false}", "{\"ui_patch\":{\"loadImages\":true}}"], calls);
    }

    [Theory]
    [InlineData(ReaderFontRole.Reading, "reading", 1)]
    [InlineData(ReaderFontRole.Title, "title", 2)]
    [InlineData(ReaderFontRole.Ui, "ui", -1)]
    [InlineData(ReaderFontRole.Code, "code", -2)]
    public async Task UpdatesOnlyTheChosenFontRole(ReaderFontRole role, string key, int step)
    {
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                var weights = JsonSerializer.SerializeToElement(parameters, wire).GetProperty("ui_patch").GetProperty("weights");
                var field = Assert.Single(weights.EnumerateObject());
                Assert.Equal(key, field.Name);
                Assert.Equal(step, field.Value.GetInt32());
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        Assert.Equal(step, new ReaderTypography(1, 2, -1, -2).StepFor(role));
        await settings.SetFontWeightAsync(role, step, CancellationToken.None);
    }

    [Theory]
    [InlineData("{}", 19, 1.6, 640)]
    [InlineData("{\"textSize\":24,\"lineSpacing\":1.8,\"columnWidth\":720}", 24, 1.8, 720)]
    [InlineData("{\"textSize\":40,\"lineSpacing\":1e999,\"columnWidth\":\"720\"}", 28, 1.6, 640)]
    public async Task ReadsAndBoundsSharedTextSettings(string ui, double size, double spacing, double width)
    {
        using var reply = JsonDocument.Parse($$"""{"full_text":true,"ui":{{ui}}}""");
        var settings = new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement });

        var preferences = await settings.ReadAsync(CancellationToken.None);

        Assert.Equal(new ReaderTextLayout(size, spacing, width), preferences.TextLayout);
    }

    [Fact]
    public async Task TextLayoutPatchUsesOnlyEditedProfileKeys()
    {
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                var patch = JsonSerializer.SerializeToElement(parameters, wire).GetProperty("ui_patch");
                Assert.Equal(24, patch.GetProperty("textSize").GetDouble());
                Assert.Equal(800, patch.GetProperty("columnWidth").GetDouble());
                Assert.Equal(2, patch.EnumerateObject().Count());
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        await settings.SetTextLayoutAsync(new Dictionary<ReaderTextSetting, double>
        {
            [ReaderTextSetting.Size] = 24,
            [ReaderTextSetting.ColumnWidth] = 1000,
        }, CancellationToken.None);
    }

    [Theory]
    [InlineData("{}", ReaderScrollbarMode.WhileScrolling)]
    [InlineData("{\"scrollbars\":\"scrolling\"}", ReaderScrollbarMode.WhileScrolling)]
    [InlineData("{\"scrollbars\":\"always\"}", ReaderScrollbarMode.Always)]
    [InlineData("{\"scrollbars\":\"never\"}", ReaderScrollbarMode.Never)]
    [InlineData("{\"scrollbars\":\"system\"}", ReaderScrollbarMode.WhileScrolling)]
    public async Task ReadsTheSharedScrollbarValues(string ui, ReaderScrollbarMode expected)
    {
        using var reply = JsonDocument.Parse($$"""{"full_text":true,"ui":{{ui}}}""");
        var settings = new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement });

        Assert.Equal(expected, (await settings.ReadAsync(CancellationToken.None)).Scrollbars);
    }

    [Theory]
    [InlineData(ReaderScrollbarMode.WhileScrolling, "scrolling")]
    [InlineData(ReaderScrollbarMode.Always, "always")]
    [InlineData(ReaderScrollbarMode.Never, "never")]
    public async Task WritesOnlyTheSharedScrollbarField(ReaderScrollbarMode mode, string value)
    {
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                var patch = JsonSerializer.SerializeToElement(parameters, wire).GetProperty("ui_patch");
                var field = Assert.Single(patch.EnumerateObject());
                Assert.Equal("scrollbars", field.Name);
                Assert.Equal(value, field.Value.GetString());
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        await settings.SetScrollbarsAsync(mode, CancellationToken.None);
    }

    [Fact]
    public async Task ReadsDistinctPositiveFolderIdsFromTheSharedProfile()
    {
        using var reply = JsonDocument.Parse("""
            {"full_text":true,"ui":{"collapsedFolders":[4294967296,2,2,-1,0,"3",1.2]}}
            """);
        var settings = new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement });

        Assert.Equal([2L, 4294967296L], (await settings.ReadAsync(CancellationToken.None)).CollapsedFolderIds);
    }

    [Fact]
    public async Task CollapsedFolderWritesPatchTheSharedArray()
    {
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                var patch = JsonSerializer.SerializeToElement(parameters, wire).GetProperty("ui_patch");
                var field = Assert.Single(patch.EnumerateObject());
                Assert.Equal("collapsedFolders", field.Name);
                Assert.Equal([2L, 4294967296L], field.Value.EnumerateArray().Select(item => item.GetInt64()));
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        await settings.SetCollapsedFoldersAsync([2, 4294967296], CancellationToken.None);
    }

    [Fact]
    public async Task ReadsAppearanceSlotsAndResolvesTheActiveTheme()
    {
        using var reply = JsonDocument.Parse("""
            {"full_text":true,"ui":{"theme":"custom-ink","followSystem":true,"dayTheme":"newsprint","nightTheme":"terminal"}}
            """);
        var settings = new ReaderSettings(new FakeClient { OnCall = (_, _) => reply.RootElement });

        var appearance = (await settings.ReadAsync(CancellationToken.None)).Appearance;

        Assert.Equal("newsprint", appearance.ActiveTheme(systemIsDark: false));
        Assert.Equal("terminal", appearance.ActiveTheme(systemIsDark: true));
        Assert.Equal("custom-ink", (appearance with { FollowSystem = false }).ActiveTheme(systemIsDark: true));
        Assert.Equal("light", ReaderAppearance.Default.ActiveTheme(systemIsDark: false));
        Assert.Equal("dark", ReaderAppearance.Default.ActiveTheme(systemIsDark: true));
    }

    [Fact]
    public async Task WritesTheChosenAppearanceSlotAndPinsAnExplicitTheme()
    {
        var patches = new List<string>();
        var wire = new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("config.set", method);
                patches.Add(JsonSerializer.SerializeToElement(parameters, wire).GetProperty("ui_patch").GetRawText());
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        });

        await settings.SetThemeAsync(ReaderThemeSlot.Fixed, "dark", CancellationToken.None);
        await settings.SetThemeAsync(ReaderThemeSlot.Day, "light", CancellationToken.None);
        await settings.SetThemeAsync(ReaderThemeSlot.Night, "dark", CancellationToken.None);
        await settings.SetFollowSystemAsync(true, CancellationToken.None);

        Assert.Equal(["{\"theme\":\"dark\",\"followSystem\":false}", "{\"dayTheme\":\"light\"}",
            "{\"nightTheme\":\"dark\"}", "{\"followSystem\":true}"], patches);
    }
}
