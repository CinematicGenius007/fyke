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

public sealed record ReaderDestination(ReaderScope Scope, long Id, string Title, int Depth, long Count, long? ParentId = null)
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

public sealed record TimelineArticle(long Id, string Title, string? FeedTitle, bool Read, bool Starred = false)
{
    public string AccessibleName => Read ? Title : $"{Title}, unread";
}

public sealed record TimelinePage(IReadOnlyList<TimelineArticle> Articles, string? NextCursor);

/// <summary>Uses the daemon's reader operations without owning stored state.</summary>
public sealed class ReaderData(IDaemonClient client)
{
    private static readonly JsonSerializerOptions Wire = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
    public const int PageSize = 100;
    public const int SearchLimit = 100;

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
                rows.Add(new(ReaderScope.Folder, folder.Id, folder.Name, depth, 0, folder.ParentId));
                var childrenUnread = AddChildren(folder.Id, depth + 1);
                rows[index] = rows[index] with { Count = childrenUnread };
                unread += childrenUnread;
            }

            foreach (var feed in feedsByFolder[parent])
            {
                rows.Add(new(ReaderScope.Feed, feed.Id, string.IsNullOrWhiteSpace(feed.Title) ? feed.Url : feed.Title,
                    depth, feed.Unread, feed.FolderId));
                unread += feed.Unread;
            }

            return unread;
        }
    }

    public async Task<TimelinePage> TimelineAsync(ReaderDestination destination, string? before, CancellationToken ct, int limit = PageSize)
    {
        var response = await EntryPageAsync(destination, before, unreadOnly: false, limit, ct).ConfigureAwait(false);
        return new TimelinePage(response.Items.Select(ToTimelineArticle).ToArray(), response.NextCursor);
    }

    private async Task<EntryPage> EntryPageAsync(ReaderDestination destination, string? before, bool unreadOnly,
        int limit, CancellationToken ct)
    {
        var filter = new
        {
            FeedId = destination.Scope == ReaderScope.Feed ? (long?)destination.Id : null,
            FolderId = destination.Scope == ReaderScope.Folder ? (long?)destination.Id : null,
            StarredOnly = destination.Scope == ReaderScope.Starred ? (bool?)true : null,
            UnreadOnly = unreadOnly,
            Limit = Math.Clamp(limit, PageSize, 1000),
            Before = before,
        };
        return Read<EntryPage>(await client.CallAsync("entries.list", filter, ct).ConfigureAwait(false));
    }

    internal async Task<(IReadOnlyCollection<long> Ids, bool ReachedLimit)> UnreadScopeAsync(
        ReaderDestination destination, CancellationToken ct)
    {
        const int maxEntries = 20_000;
        var ids = new HashSet<long>();
        string? before = null;
        for (var offset = 0; offset < maxEntries; offset += BulkReadChange.BatchSize)
        {
            var page = await EntryPageAsync(destination, before, unreadOnly: true, BulkReadChange.BatchSize, ct)
                .ConfigureAwait(false);
            foreach (var entry in page.Items)
            {
                ids.Add(entry.Id);
            }

            if (page.NextCursor is null)
            {
                return (ids, false);
            }

            if (page.NextCursor == before)
            {
                throw new DaemonProtocolException("The unread article cursor did not advance.");
            }

            before = page.NextCursor;
        }

        return (ids, true);
    }

    internal async Task<long[]> SetReadBatchAsync(long[] ids, bool read, CancellationToken ct)
    {
        var result = Read<BulkMarkReply>(await client.CallAsync("entries.mark_many", new { Ids = ids, Read = read }, ct)
            .ConfigureAwait(false));
        var previous = result.Previous;
        if (previous is null || previous.Any(entry => entry is null) || !previous.Select(entry => entry.Id).SequenceEqual(ids))
        {
            throw new DaemonProtocolException("The daemon returned incomplete bulk article marks.");
        }

        return previous.Where(entry => !entry.Read).Select(entry => entry.Id).ToArray();
    }

    public async Task<IReadOnlyList<SearchHit>> SearchAsync(string query, bool unreadOnly, CancellationToken ct,
        int limit = SearchLimit)
    {
        if (string.IsNullOrWhiteSpace(query))
        {
            return [];
        }

        var parameters = new { Query = query.Trim(), Limit = Math.Clamp(limit, 1, SearchLimit), UnreadOnly = unreadOnly };
        var result = Read<CatalogItems<Entry>>(
            await client.CallAsync("entries.search", parameters, ct).ConfigureAwait(false));
        if (result.Items is null)
        {
            throw new DaemonProtocolException("The daemon returned an incomplete search response.");
        }

        return result.Items.Select(entry => new SearchHit(ToTimelineArticle(entry),
            SearchSnippet.Split(entry.Snippet ?? entry.Summary, parameters.Query), entry.SortAt)).ToArray();
    }

    public async Task<ReaderArticle> ArticleAsync(long id, CancellationToken ct)
    {
        var response = Read<ArticleBody>(
            await client.CallAsync("entries.get", new { Id = id, Format = "blocks" }, ct).ConfigureAwait(false));
        var blocks = JsonSerializer.Deserialize<ArticleBlock[]>(response.Body, Wire)
            ?? throw new DaemonProtocolException("The daemon returned an empty article response.");
        return new ReaderArticle(response.Title, response.FeedTitle, response.Author, blocks,
            DiscussionLink.FromAddress(response.DiscussionUrl), response.Read, response.Starred);
    }

    public async Task<ArticleMarks> MarkAsync(long id, bool? read, bool? starred, CancellationToken ct)
    {
        var response = Read<MarkReply>(await client.CallAsync("entries.mark",
            new { Id = id, Read = read, Starred = starred }, ct).ConfigureAwait(false));
        var previous = response.Previous
            ?? throw new DaemonProtocolException("The daemon returned incomplete article marks.");
        return new ArticleMarks(read ?? previous.Read, starred ?? previous.Starred);
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

    private static TimelineArticle ToTimelineArticle(Entry entry) => new(entry.Id,
        string.IsNullOrWhiteSpace(entry.Title) ? "Untitled article" : entry.Title, entry.FeedTitle, entry.Read, entry.Starred);

    private sealed record CatalogItems<T>(T[] Items);
    private sealed record Feed(long Id, long? FolderId, string? Title, string Url, long Unread, long Starred);
    private sealed record Folder(long Id, long? ParentId, string Name);
    private sealed record Entry(long Id, string? Title, string? FeedTitle, bool Read, bool Starred,
        string? Snippet, string? Summary, long SortAt);
    private sealed record ArticleBody(string? Title, string? FeedTitle, string? Author, string? DiscussionUrl, string Body, bool Read, bool Starred);
    private sealed record MarkReply(MarkState? Previous);
    private sealed record MarkState(bool Read, bool Starred);
    private sealed record BulkMarkReply(PreviousRead[]? Previous);
    private sealed record PreviousRead(long Id, bool Read);
    private sealed record EntryPage(Entry[] Items, string? NextCursor);
}
