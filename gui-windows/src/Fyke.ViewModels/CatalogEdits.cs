using System.Text.Json;
using System.Text.Json.Serialization;
using Fyke.Client;

namespace Fyke.ViewModels;

public sealed record FolderChoice(long? Id, string Name)
{
    /// <summary>Uses the catalog's depth-first order to display paths and omit a folder's subtree.</summary>
    public static IReadOnlyList<FolderChoice> FromCatalog(IReadOnlyList<ReaderDestination> catalog, string rootName,
        long? excludedFolder = null)
    {
        var choices = new List<FolderChoice> { new(null, rootName) };
        var path = new List<string>();
        int? hiddenBelow = null;
        foreach (var folder in catalog.Where(row => row.Scope == ReaderScope.Folder))
        {
            if (hiddenBelow is int depth && folder.Depth > depth)
            {
                continue;
            }

            hiddenBelow = null;
            if (folder.Id == excludedFolder)
            {
                hiddenBelow = folder.Depth;
                continue;
            }

            if (path.Count > folder.Depth)
            {
                path.RemoveRange(folder.Depth, path.Count - folder.Depth);
            }

            path.Add(folder.Title);
            choices.Add(new FolderChoice(folder.Id, string.Join(" / ", path)));
        }

        return choices;
    }
}

public sealed record CatalogRemoval(ReaderDestination Item, IReadOnlyList<ReaderDestination> Contents)
{
    public static CatalogRemoval FromCatalog(ReaderDestination item, IReadOnlyList<ReaderDestination> catalog)
    {
        var contents = item.Scope == ReaderScope.Folder
            ? catalog.SkipWhile(row => row.Scope != ReaderScope.Folder || row.Id != item.Id).Skip(1)
                .TakeWhile(row => row.Depth > item.Depth).ToArray()
            : [];
        return new(item, contents);
    }

    public IReadOnlyList<ReaderDestination> Removed(bool deleteContents) =>
        deleteContents ? [Item, .. Contents] : [Item];
}

public sealed record FeedRefresh(long Id, string Status, [property: JsonPropertyName("new")] int NewCount, int Updated);

public sealed record OpmlImportResult(int Added, int Existing);

/// <summary>Edits subscriptions and folders through the daemon's management operations.</summary>
public sealed class CatalogEdits(IDaemonClient client)
{
    private static readonly JsonSerializerOptions Wire = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public Task CreateFolderAsync(string name, long? parentId, CancellationToken ct) =>
        client.CallAsync("folders.add", new { Name = name.Trim(), ParentId = parentId }, ct);

    public Task RenameAsync(ReaderDestination item, string name, CancellationToken ct) => item.Scope switch
    {
        ReaderScope.Feed => client.CallAsync("feeds.update", new { item.Id, Title = name.Trim() }, ct),
        ReaderScope.Folder => client.CallAsync("folders.rename", new { item.Id, Name = name.Trim() }, ct),
        _ => throw new ArgumentException("Select a folder or feed to rename.", nameof(item)),
    };

    public Task MoveAsync(ReaderDestination item, long? folderId, CancellationToken ct) => item.Scope switch
    {
        ReaderScope.Feed => MoveFeedAsync(client, item.Id, folderId, ct),
        ReaderScope.Folder => client.CallAsync("folders.move", new { item.Id, ParentId = folderId }, ct),
        _ => throw new ArgumentException("Select a folder or feed to move.", nameof(item)),
    };

    internal static Task MoveFeedAsync(IDaemonClient client, long id, long? folderId, CancellationToken ct) =>
        client.CallAsync("feeds.update", new { Id = id, FolderId = folderId, TopLevel = folderId is null }, ct);

    public Task RemoveAsync(ReaderDestination item, bool deleteContents, CancellationToken ct) => item.Scope switch
    {
        ReaderScope.Feed => client.CallAsync("feeds.remove", new { item.Id }, ct),
        ReaderScope.Folder => client.CallAsync("folders.remove", new { item.Id, DeleteContents = deleteContents }, ct),
        _ => throw new ArgumentException("Select a folder or feed to remove.", nameof(item)),
    };

    public async Task<FeedRefresh> RefreshFeedAsync(long id, CancellationToken ct)
    {
        var reply = await client.CallAsync("feeds.refresh", new { Id = id }, ct).ConfigureAwait(false);
        return ReadRefresh(reply);
    }

    public async Task<int> RefreshAllAsync(CancellationToken ct)
    {
        var reply = await client.CallAsync("feeds.refresh_all", null, ct).ConfigureAwait(false);
        return reply.Deserialize<RefreshQueue>(Wire)?.Queued
            ?? throw new DaemonProtocolException("The daemon did not report how many feeds were queued.");
    }

    public async Task<OpmlImportResult> ImportOpmlAsync(string path, CancellationToken ct)
    {
        if (!Path.IsPathFullyQualified(path))
        {
            throw new ArgumentException("Select an absolute path to an OPML file.", nameof(path));
        }

        var reply = await client.CallAsync("opml.import", new { Path = path }, ct).ConfigureAwait(false);
        return reply.Deserialize<OpmlImportCounts>(Wire) is { Added: >= 0 and int added, Existing: >= 0 and int existing }
            ? new OpmlImportResult(added, existing)
            : throw new DaemonProtocolException("The daemon did not report the OPML import counts.");
    }

    public async Task<string> ExportOpmlAsync(CancellationToken ct)
    {
        var reply = await client.CallAsync("opml.export", null, ct).ConfigureAwait(false);
        return reply.Deserialize<OpmlDocument>(Wire) is { Opml.Length: > 0 } document ? document.Opml
            : throw new DaemonProtocolException("The daemon returned an empty OPML document.");
    }

    internal static FeedRefresh ReadRefresh(JsonElement reply)
    {
        var result = reply.Deserialize<FeedRefresh>(Wire);
        return result is { Id: > 0, Status.Length: > 0 } ? result
            : throw new DaemonProtocolException("The daemon returned an incomplete feed result.");
    }

    private sealed record RefreshQueue(int? Queued);

    private sealed record OpmlImportCounts(int? Added, int? Existing);

    private sealed record OpmlDocument(string Opml);
}
