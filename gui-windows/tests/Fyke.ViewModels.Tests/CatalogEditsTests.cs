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
                calls.Add((method, JsonSerializer.SerializeToElement(parameters)));
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
        Assert.Equal("Child", calls[0].Parameters.GetProperty("Name").GetString());
        Assert.Equal(1, calls[0].Parameters.GetProperty("ParentId").GetInt64());
        Assert.Equal("News", calls[1].Parameters.GetProperty("Name").GetString());
        Assert.Equal(3, calls[2].Parameters.GetProperty("ParentId").GetInt64());
        Assert.Equal(string.Empty, calls[3].Parameters.GetProperty("Title").GetString());
        Assert.True(calls[4].Parameters.GetProperty("TopLevel").GetBoolean());
    }
}
