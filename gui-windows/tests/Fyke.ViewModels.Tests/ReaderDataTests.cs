using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderDataTests
{
    [Fact]
    public async Task CatalogNestsFeedsAndFoldersAndSummarizesUnreadCounts()
    {
        var fake = new FakeClient
        {
            OnCall = (method, _) => Parse(method switch
            {
                "feeds.list" => """
                    {"items":[
                      {"id":8,"folder_id":4,"title":"Café","url":"https://example.org","unread":3,"starred":1},
                      {"id":2,"folder_id":1,"title":"Systems","url":"https://example.net","unread":2,"starred":0},
                      {"id":3,"folder_id":null,"title":null,"url":"https://example.com","unread":1,"starred":3}
                    ]}
                    """,
                "folders.list" => """
                    {"items":[{"id":4,"parent_id":1,"name":"Databases"},{"id":1,"parent_id":null,"name":"Engineering"}]}
                    """,
                "views.list" => """
                    {"items":[{"id":1,"name":"Zig","rule":{"words":"zig"},"revision":2,"sentence":"Articles about zig","unread":2,"total":8}]}
                    """,
                _ => throw new InvalidOperationException(method),
            }),
        };

        var destinations = await new ReaderData(fake).DestinationsAsync(CancellationToken.None);

        Assert.Equal(
            [
                (ReaderScope.All, "All", 0, 6L),
                (ReaderScope.Starred, "Starred", 0, 4L),
                (ReaderScope.View, "Zig", 0, 2L),
                (ReaderScope.Folder, "Engineering", 0, 5L),
                (ReaderScope.Folder, "Databases", 1, 3L),
                (ReaderScope.Feed, "Café", 2, 3L),
                (ReaderScope.Feed, "Systems", 1, 2L),
                (ReaderScope.Feed, "https://example.com", 0, 1L),
            ],
            destinations.Select(row => (row.Scope, row.Title, row.Depth, row.Count)));
        var view = Assert.Single(destinations, row => row.Scope == ReaderScope.View);
        Assert.Equal("Articles about zig", view.RuleSummary);
    }

    [Theory]
    [InlineData(ReaderScope.All, null)]
    [InlineData(ReaderScope.Starred, "starred_only")]
    [InlineData(ReaderScope.Folder, "folder_id")]
    [InlineData(ReaderScope.Feed, "feed_id")]
    [InlineData(ReaderScope.View, "view_id")]
    public async Task TimelineSendsOnlyTheSelectedFilterAndKeepsTheCursor(ReaderScope scope, string? filter)
    {
        var fake = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.list", method);
                var sent = parameters.GetValueOrDefault();
                Assert.Equal("prior", sent.GetProperty("before").GetString());
                Assert.Equal(ReaderData.PageSize, sent.GetProperty("limit").GetInt32());
                foreach (var name in new[] { "feed_id", "folder_id", "starred_only", "view_id" })
                {
                    var given = sent.TryGetProperty(name, out var value);
                    Assert.Equal(name == filter, given);
                    if (given)
                    {
                        if (scope == ReaderScope.Starred)
                        {
                            Assert.True(value.GetBoolean());
                        }
                        else
                        {
                            Assert.Equal(42, value.GetInt64());
                        }
                    }
                }

                return Parse("""
                    {"items":[{"id":9,"title":null,"feed_title":"News","read":false}],"next_cursor":"next"}
                    """);
            },
        };

        var page = await new ReaderData(fake).TimelineAsync(new(scope, 42, "Selected", 0, 0), "prior", CancellationToken.None);

        Assert.Equal("next", page.NextCursor);
        Assert.Equal(new TimelineArticle(9, "Untitled article", "News", false), Assert.Single(page.Articles));
    }

    [Fact]
    public async Task ArticleRequestsStoredBlocksAndDecodesTheirStructure()
    {
        var fake = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.get", method);
                var sent = parameters.GetValueOrDefault();
                Assert.Equal(9, sent.GetProperty("id").GetInt64());
                Assert.Equal("blocks", sent.GetProperty("format").GetString());
                return JsonSerializer.SerializeToElement(new
                {
                    title = "Reader fixture", feed_title = "News", author = "Alex",
                    body = """
                        [
                          {"t":"h","level":2,"c":[{"t":"text","v":"Title"}]},
                          {"t":"list","ordered":true,"items":[[{"t":"strong","c":[{"t":"text","v":"Bold"}]}]]},
                          {"t":"table","rows":[[[{"t":"text","v":"Cell"}]]]},
                          {"t":"img","src":"https://example.com/a.png","alt":"Figure"},
                          {"t":"unknown"}
                        ]
                        """,
                });
            },
        };

        var article = await new ReaderData(fake).ArticleAsync(9, CancellationToken.None);

        Assert.Equal(("Reader fixture", "News", "Alex"), (article.Title, article.FeedTitle, article.Author));
        Assert.Equal("Title", Assert.Single(article.Blocks[0].Children!).Text);
        Assert.True(article.Blocks[1].Ordered);
        Assert.Equal("Bold", article.Blocks[1].Items![0][0].Children![0].Text);
        Assert.Equal("Cell", article.Blocks[2].Rows![0][0][0].Text);
        Assert.Equal("Figure", article.Blocks[3].Alt);
        Assert.Equal("unknown", article.Blocks[4].Kind);
    }

    [Theory]
    [InlineData("https://example.com/page", true)]
    [InlineData("http://example.com/image.png", true)]
    [InlineData("file:///C:/Windows/win.ini", false)]
    [InlineData("javascript:alert(1)", false)]
    [InlineData("https://user:secret@example.com", false)]
    [InlineData("/relative", false)]
    public void FeedAddressesAreLimitedToWebUrls(string value, bool allowed) =>
        Assert.Equal(allowed, ArticleBlock.WebAddress(value) is not null);

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
