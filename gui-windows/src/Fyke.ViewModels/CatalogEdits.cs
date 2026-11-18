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

/// <summary>Edits subscriptions and folders through the daemon's management operations.</summary>
public sealed class CatalogEdits(IDaemonClient client)
{
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
}
