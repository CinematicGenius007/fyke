using System.Globalization;
using System.Text.Json;
using Fyke.Client;

namespace Fyke.ViewModels;

public enum ReaderScope
{
    All,
    Starred,
    Folder,
    Feed,
}

public sealed record ReaderDestination(ReaderScope Scope, long Id, string Title, int Depth, long Count)
{
    public string Glyph => Scope switch
    {
        ReaderScope.All => "\uE8B7",
        ReaderScope.Starred => "\uE734",
        ReaderScope.Folder => string.Empty,
        _ => "\uE8A1",
    };

    public string CountText => Count > 0 ? Count.ToString(CultureInfo.CurrentCulture) : string.Empty;

    public string AccessibleName => Count > 0
        ? string.Format(CultureInfo.CurrentCulture, "{0}, {1} {2}", Title, Count, Scope == ReaderScope.Starred ? "starred" : "unread")
        : Title;
}

public sealed record TimelineArticle(long Id, string Title, string? FeedTitle, bool Read)
{
    public string AccessibleName => Read ? Title : $"{Title}, unread";
}

public sealed record TimelinePage(IReadOnlyList<TimelineArticle> Articles, string? NextCursor);

/// <summary>Reads the shared catalog and timeline without owning any daemon state.</summary>
public sealed class ReaderData(IDaemonClient client)
{
    private static readonly JsonSerializerOptions Wire = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
    public const int PageSize = 100;

    public async Task<ReaderTypography> TypographyAsync(CancellationToken ct) =>
        ReaderTypography.FromConfig(await client.CallAsync("config.get", null, ct).ConfigureAwait(false));

    public async Task<IReadOnlyList<ReaderDestination>> DestinationsAsync(CancellationToken ct)
    {
        var feeds = Read<CatalogItems<Feed>>(await client.CallAsync("feeds.list", null, ct).ConfigureAwait(false)).Items;
        var folders = Read<CatalogItems<Folder>>(await client.CallAsync("folders.list", null, ct).ConfigureAwait(false)).Items;
        var foldersByParent = folders.ToLookup(folder => folder.ParentId);
        var feedsByFolder = feeds.ToLookup(feed => feed.FolderId);
        var rows = new List<ReaderDestination>
        {
            new(ReaderScope.All, 0, "All", 0, feeds.Sum(feed => feed.Unread)),
            new(ReaderScope.Starred, 0, "Starred", 0, feeds.Sum(feed => feed.Starred)),
        };

        AddChildren(null, 0);
        return rows;

        long AddChildren(long? parent, int depth)
        {
            long unread = 0;
            foreach (var folder in foldersByParent[parent])
            {
                var index = rows.Count;
                rows.Add(new(ReaderScope.Folder, folder.Id, folder.Name, depth, 0));
                var childrenUnread = AddChildren(folder.Id, depth + 1);
                rows[index] = rows[index] with { Count = childrenUnread };
                unread += childrenUnread;
            }

            foreach (var feed in feedsByFolder[parent])
            {
                rows.Add(new(ReaderScope.Feed, feed.Id, string.IsNullOrWhiteSpace(feed.Title) ? feed.Url : feed.Title, depth, feed.Unread));
                unread += feed.Unread;
            }

            return unread;
        }
    }

    public async Task<TimelinePage> TimelineAsync(ReaderDestination destination, string? before, CancellationToken ct, int limit = PageSize)
    {
        var filter = new
        {
            FeedId = destination.Scope == ReaderScope.Feed ? (long?)destination.Id : null,
            FolderId = destination.Scope == ReaderScope.Folder ? (long?)destination.Id : null,
            StarredOnly = destination.Scope == ReaderScope.Starred ? (bool?)true : null,
            Limit = Math.Clamp(limit, PageSize, 1000),
            Before = before,
        };
        var response = Read<EntryPage>(await client.CallAsync("entries.list", filter, ct).ConfigureAwait(false));
        return new TimelinePage(
            response.Items.Select(entry => new TimelineArticle(entry.Id,
                string.IsNullOrWhiteSpace(entry.Title) ? "Untitled article" : entry.Title, entry.FeedTitle, entry.Read)).ToArray(),
            response.NextCursor);
    }

    public async Task<ReaderArticle> ArticleAsync(long id, CancellationToken ct)
    {
        var response = Read<ArticleBody>(
            await client.CallAsync("entries.get", new { Id = id, Format = "blocks" }, ct).ConfigureAwait(false));
        var blocks = JsonSerializer.Deserialize<ArticleBlock[]>(response.Body, Wire)
            ?? throw new DaemonProtocolException("The daemon returned an empty article response.");
        return new ReaderArticle(response.Title, response.FeedTitle, response.Author, blocks,
            DiscussionLink.FromAddress(response.DiscussionUrl));
    }

    public async Task<DiscussionThread> DiscussionAsync(long id, CancellationToken ct)
    {
        var thread = Read<DiscussionThread>(
            await client.CallAsync("entries.discussion", new { Id = id }, ct).ConfigureAwait(false));
        if (thread.Comments is null || thread.Comments.Any(comment => comment is null || comment.Blocks is null))
        {
            throw new DaemonProtocolException("The daemon returned an incomplete discussion.");
        }

        return thread;
    }

    private static T Read<T>(JsonElement result) =>
        result.Deserialize<T>(Wire) ?? throw new DaemonProtocolException("The daemon returned an empty reader response.");

    private sealed record CatalogItems<T>(T[] Items);
    private sealed record Feed(long Id, long? FolderId, string? Title, string Url, long Unread, long Starred);
    private sealed record Folder(long Id, long? ParentId, string Name);
    private sealed record Entry(long Id, string? Title, string? FeedTitle, bool Read);
    private sealed record ArticleBody(string? Title, string? FeedTitle, string? Author, string? DiscussionUrl, string Body);
    private sealed record EntryPage(Entry[] Items, string? NextCursor);
}
