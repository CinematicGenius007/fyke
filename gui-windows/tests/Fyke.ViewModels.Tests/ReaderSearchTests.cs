using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderSearchTests
{
    [Theory]
    [InlineData(100)]
    [InlineData(4)]
    public async Task SendsTheLimitAndUnreadFilterAndKeepsReturnedOrderAndMetadata(int limit)
    {
        using var response = JsonDocument.Parse("""
            {"items":[
              {"id":2,"title":"Second","feed_title":"News","read":false,"sort_at":800,"snippet":"…Zig tools."},
              {"id":1,"title":null,"feed_title":"Zig","read":false,"sort_at":200,"summary":"Builds"}
            ]}
            """);
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.search", method);
                var request = JsonSerializer.SerializeToElement(parameters);
                Assert.Equal("zig", request.GetProperty("Query").GetString());
                Assert.Equal(limit, request.GetProperty("Limit").GetInt32());
                Assert.True(request.GetProperty("UnreadOnly").GetBoolean());
                return response.RootElement;
            },
        };

        var results = await new ReaderData(client).SearchAsync("  zig  ", true, CancellationToken.None, limit);

        Assert.Equal([2L, 1L], results.Select(hit => hit.Article.Id));
        Assert.Equal("Second, unread", results[0].AccessibleName);
        Assert.Equal(800, results[0].SortAt);
        Assert.Equal("News", results[0].FeedTitle);
        Assert.Equal(
            [new("…", false), new("Zig", true), new(" tools.", false)],
            results[0].Snippet);
        Assert.Equal("Untitled article", results[1].Title);
        Assert.Equal(new SearchSnippetRun("Builds", false), Assert.Single(results[1].Snippet));
    }

    [Fact]
    public async Task BlankQueryMakesNoRequest()
    {
        var results = await new ReaderData(new FakeClient()).SearchAsync("  \t", false, CancellationToken.None);

        Assert.Empty(results);
    }

    [Fact]
    public void HighlightingMergesOverlappingMatchesAndKeepsOriginalText()
    {
        var runs = SearchSnippet.Split("...banana and ZIG", "AnA na zig");

        Assert.Equal(
            [new("…b", false), new("anana", true), new(" and ", false), new("ZIG", true)],
            runs);
    }
}
