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
}
