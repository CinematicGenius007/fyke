using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class CatalogEditsTests
{
    [Fact]
    public void FolderPathsExcludeTheMovingFolderAndItsDescendants()
    {
        ReaderDestination[] catalog =
        [
            new(ReaderScope.Folder, 1, "News", 0, 0),
            new(ReaderScope.Folder, 2, "Local", 1, 0, 1),
            new(ReaderScope.Folder, 3, "City", 2, 0, 2),
            new(ReaderScope.Feed, 4, "City feed", 3, 0, 3),
            new(ReaderScope.Folder, 5, "World", 1, 0, 1),
            new(ReaderScope.Folder, 6, "Other", 0, 0),
            new(ReaderScope.Folder, 7, "Local", 1, 0, 6),
        ];

        var choices = FolderChoice.FromCatalog(catalog, "Top level", excludedFolder: 2);

        Assert.Equal(
            [new(null, "Top level"), new(1, "News"), new(5, "News / World"), new(6, "Other"), new(7, "Other / Local")],
            choices);
    }

    [Fact]
    public async Task SendsFolderParentsAndUsesTopLevelForFeedsOnly()
    {
        var calls = new List<(string Method, JsonElement Parameters)>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add((method, parameters.GetValueOrDefault()));
                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        };
        var edits = new CatalogEdits(client);
        var ct = CancellationToken.None;
        var folder = new ReaderDestination(ReaderScope.Folder, 1, "Parent", 0, 0);
        var feed = new ReaderDestination(ReaderScope.Feed, 2, "Feed", 1, 0, 1);

        await edits.CreateFolderAsync(" Child ", folder.Id, ct);
        await edits.RenameAsync(folder, " News ", ct);
        await edits.MoveAsync(folder, 3, ct);
        await edits.RenameAsync(feed, " ", ct);
        await edits.MoveAsync(feed, null, ct);

        Assert.Equal(["folders.add", "folders.rename", "folders.move", "feeds.update", "feeds.update"],
            calls.Select(call => call.Method));
        Assert.Equal("Child", calls[0].Parameters.GetProperty("name").GetString());
        Assert.Equal(1, calls[0].Parameters.GetProperty("parent_id").GetInt64());
        Assert.Equal("News", calls[1].Parameters.GetProperty("name").GetString());
        Assert.Equal(3, calls[2].Parameters.GetProperty("parent_id").GetInt64());
        Assert.Equal(string.Empty, calls[3].Parameters.GetProperty("title").GetString());
        Assert.True(calls[4].Parameters.GetProperty("top_level").GetBoolean());
    }

    [Fact]
    public void RemovalKeepsFolderContentsUnlessTheyWereExplicitlySelected()
    {
        var folder = new ReaderDestination(ReaderScope.Folder, 1, "News", 0, 0);
        var child = new ReaderDestination(ReaderScope.Folder, 2, "Local", 1, 0, 1);
        var feed = new ReaderDestination(ReaderScope.Feed, 1, "Local feed", 2, 0, 2);
        var other = new ReaderDestination(ReaderScope.Feed, 3, "Other feed", 0, 0);
        var removal = CatalogRemoval.FromCatalog(folder, [folder, child, feed, other]);

        Assert.Equal([folder], removal.Removed(false));
        Assert.Equal([folder, child, feed], removal.Removed(true));
        Assert.Equal([other], CatalogRemoval.FromCatalog(other, [folder, child, feed, other]).Removed(true));
    }

    [Fact]
    public async Task RefreshAndRemovalUseTheirOwnOperationsAndDecodeRefreshCounts()
    {
        var calls = new List<(string Method, JsonElement Parameters)>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add((method, parameters.GetValueOrDefault()));
                return method switch
                {
                    "feeds.refresh" => JsonSerializer.SerializeToElement(new { id = 2, status = "updated", @new = 3, updated = 1 }),
                    "feeds.refresh_all" => JsonSerializer.SerializeToElement(new { queued = 5 }),
                    _ => JsonSerializer.SerializeToElement(new { ok = true }),
                };
            },
        };
        var edits = new CatalogEdits(client);
        var ct = CancellationToken.None;
        var folder = new ReaderDestination(ReaderScope.Folder, 1, "News", 0, 0);
        var feed = new ReaderDestination(ReaderScope.Feed, 2, "Feed", 1, 0, 1);

        Assert.Equal(new FeedRefresh(2, "updated", 3, 1), await edits.RefreshFeedAsync(feed.Id, ct));
        Assert.Equal(5, await edits.RefreshAllAsync(ct));
        await edits.RemoveAsync(feed, false, ct);
        await edits.RemoveAsync(folder, false, ct);
        await edits.RemoveAsync(folder, true, ct);

        Assert.Equal(["feeds.refresh", "feeds.refresh_all", "feeds.remove", "folders.remove", "folders.remove"],
            calls.Select(call => call.Method));
        Assert.Equal(2, calls[0].Parameters.GetProperty("id").GetInt64());
        Assert.Equal(2, calls[2].Parameters.GetProperty("id").GetInt64());
        Assert.False(calls[3].Parameters.GetProperty("delete_contents").GetBoolean());
        Assert.True(calls[4].Parameters.GetProperty("delete_contents").GetBoolean());
    }
}
