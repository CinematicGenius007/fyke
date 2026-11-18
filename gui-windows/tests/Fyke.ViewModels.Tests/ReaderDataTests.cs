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
                _ => throw new InvalidOperationException(method),
            }),
        };

        var destinations = await new ReaderData(fake).DestinationsAsync(CancellationToken.None);

        Assert.Equal(
            [
                (ReaderScope.All, "All", 0, 6L),
                (ReaderScope.Starred, "Starred", 0, 4L),
                (ReaderScope.Folder, "Engineering", 0, 5L),
                (ReaderScope.Folder, "Databases", 1, 3L),
                (ReaderScope.Feed, "Café", 2, 3L),
                (ReaderScope.Feed, "Systems", 1, 2L),
                (ReaderScope.Feed, "https://example.com", 0, 1L),
            ],
            destinations.Select(row => (row.Scope, row.Title, row.Depth, row.Count)));
    }

    [Theory]
    [InlineData(ReaderScope.All, null)]
    [InlineData(ReaderScope.Starred, "StarredOnly")]
    [InlineData(ReaderScope.Folder, "FolderId")]
    [InlineData(ReaderScope.Feed, "FeedId")]
    public async Task TimelineSendsOnlyTheSelectedFilterAndKeepsTheCursor(ReaderScope scope, string? filter)
    {
        var fake = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.list", method);
                var sent = JsonSerializer.SerializeToElement(parameters);
                Assert.Equal("prior", sent.GetProperty("Before").GetString());
                Assert.Equal(ReaderData.PageSize, sent.GetProperty("Limit").GetInt32());
                foreach (var name in new[] { "FeedId", "FolderId", "StarredOnly" })
                {
                    var value = sent.GetProperty(name);
                    if (name == filter)
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
                    else
                    {
                        Assert.Equal(JsonValueKind.Null, value.ValueKind);
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

    private static JsonElement Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }
}
