using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

public enum ReaderScope
{
    All,
    Starred,
    Folder,
    Feed,
    View,
}

public sealed record ReaderDestination(ReaderScope Scope, long Id, string Title, int Depth, long Count,
    long? ParentId = null, long Entries = 0, long Starred = 0, string? RuleSummary = null)
{
    public string Glyph => Scope switch
    {
        ReaderScope.All => "\uE8B7",
        ReaderScope.Starred => "\uE734",
        ReaderScope.View => "\uE71C",
        ReaderScope.Folder => string.Empty,
        _ => "\uE8A1",
    };

    public string CountText => Count > 0 ? Count.ToString(CultureInfo.CurrentCulture) : string.Empty;

    public string AccessibleName => Count > 0
        ? string.Format(CultureInfo.CurrentCulture, "{0}, {1} {2}", Title, Count, Scope == ReaderScope.Starred ? "starred" : "unread")
        : Title;
}

public sealed record TimelineArticle(long Id, string Title, string? FeedTitle, bool Read, bool Starred = false, long? FeedId = null)
{
    public string AccessibleName => Read ? Title : $"{Title}, unread";
}

public sealed record TimelinePage(IReadOnlyList<TimelineArticle> Articles, string? NextCursor);

/// <summary>Uses the daemon's reader operations without owning stored state.</summary>
public sealed class ReaderData(IDaemonClient client)
{
    public const int PageSize = 100;
    public const int SearchLimit = 100;
    public SavedViews Views { get; } = new(client);

    public async Task<IReadOnlyList<ReaderDestination>> DestinationsAsync(CancellationToken ct)
    {
        var feeds = (await ReadAsync("feeds.list", null, WireJson.Default.CatalogItemsFeed, ct).ConfigureAwait(false)).Items;
        var folders = (await ReadAsync("folders.list", null, WireJson.Default.CatalogItemsFolder, ct).ConfigureAwait(false)).Items;
        var views = await Views.ListAsync(ct).ConfigureAwait(false);
        var foldersByParent = folders.ToLookup(folder => folder.ParentId);
        var feedsByFolder = feeds.ToLookup(feed => feed.FolderId);
        var rows = new List<ReaderDestination>
        {
            new(ReaderScope.All, 0, "All", 0, feeds.Sum(feed => feed.Unread)),
            new(ReaderScope.Starred, 0, "Starred", 0, feeds.Sum(feed => feed.Starred)),
        };

        rows.AddRange(views.Select(view => new ReaderDestination(ReaderScope.View, view.Id, view.Name, 0,
            view.Unread, Entries: view.Total, RuleSummary: view.Sentence)));
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
                    depth, feed.Unread, feed.FolderId, feed.Entries, feed.Starred));
                unread += feed.Unread;
            }

            return unread;
        }
    }

    /// <param name="unreadOnly">Leaves out read articles, except in a saved view, whose rule decides.</param>
    public async Task<TimelinePage> TimelineAsync(ReaderDestination destination, string? before, CancellationToken ct,
        int limit = PageSize, bool unreadOnly = false)
    {
        var response = await EntryPageAsync(destination, before, unreadOnly, limit, ct).ConfigureAwait(false);
        return new TimelinePage(response.Items.Select(ToTimelineArticle).ToArray(), response.NextCursor);
    }

    private async Task<EntryPage> EntryPageAsync(ReaderDestination destination, string? before, bool unreadOnly,
        int limit, CancellationToken ct)
    {
        var filter = new JsonObject
        {
            ["feed_id"] = destination.Scope == ReaderScope.Feed ? destination.Id : null,
            ["folder_id"] = destination.Scope == ReaderScope.Folder ? destination.Id : null,
            ["view_id"] = destination.Scope == ReaderScope.View ? destination.Id : null,
            ["starred_only"] = destination.Scope == ReaderScope.Starred ? true : null,
            // A saved view supplies its own reading-state filter.
            ["unread_only"] = unreadOnly && destination.Scope != ReaderScope.View,
            ["limit"] = Math.Clamp(limit, PageSize, 1000),
            ["before"] = before,
        };
        return await ReadAsync("entries.list", filter, WireJson.Default.EntryPage, ct).ConfigureAwait(false);
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
                if (destination.Scope != ReaderScope.View || !entry.Read)
                {
                    ids.Add(entry.Id);
                }
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
        var result = await ReadAsync("entries.mark_many", new JsonObject { ["ids"] = Wire.Ids(ids), ["read"] = read },
            WireJson.Default.BulkMarkReply, ct).ConfigureAwait(false);
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

        var words = query.Trim();
        var parameters = new JsonObject
        {
            ["query"] = words,
            ["limit"] = Math.Clamp(limit, 1, SearchLimit),
            ["unread_only"] = unreadOnly,
        };
        var result = await ReadAsync("entries.search", parameters, WireJson.Default.CatalogItemsEntry, ct).ConfigureAwait(false);
        if (result.Items is null)
        {
            throw new DaemonProtocolException("The daemon returned an incomplete search response.");
        }

        return result.Items.Select(entry => new SearchHit(ToTimelineArticle(entry),
            SearchSnippet.Split(entry.Snippet ?? entry.Summary, words), entry.SortAt)).ToArray();
    }

    public async Task<ReaderArticle> ArticleAsync(long id, CancellationToken ct)
    {
        var response = await ReadAsync("entries.get", new JsonObject { ["id"] = id, ["format"] = "blocks" },
            WireJson.Default.ArticleBody, ct).ConfigureAwait(false);
        var blocks = JsonSerializer.Deserialize(response.Body, WireJson.Default.ArticleBlockArray)
            ?? throw new DaemonProtocolException("The daemon returned an empty article response.");
        return new ReaderArticle(response.Title, response.FeedTitle, response.Author, blocks,
            DiscussionLink.FromAddress(response.DiscussionUrl), response.Read, response.Starred,
            ArticleBlock.WebAddress(response.Url));
    }

    /// <summary>Fetches the article from its page now, whatever the full-text schedule says.</summary>
    public async Task<FullTextOutcome> FetchFullAsync(long id, CancellationToken ct)
    {
        var reply = await ReadAsync("entries.fetch_full", new JsonObject { ["id"] = id },
            WireJson.Default.FetchFullReply, ct).ConfigureAwait(false);
        return reply.Status switch
        {
            "done" => FullTextOutcome.Done,
            "skipped" => FullTextOutcome.Skipped,
            "later" => FullTextOutcome.Later,
            "failed" => FullTextOutcome.Failed,
            _ => throw new DaemonProtocolException("The daemon returned an unknown full-text status."),
        };
    }

    public async Task<ArticleMarks> MarkAsync(long id, bool? read, bool? starred, CancellationToken ct)
    {
        var response = await ReadAsync("entries.mark", new JsonObject { ["id"] = id, ["read"] = read, ["starred"] = starred },
            WireJson.Default.MarkReply, ct).ConfigureAwait(false);
        var previous = response.Previous
            ?? throw new DaemonProtocolException("The daemon returned incomplete article marks.");
        return new ArticleMarks(read ?? previous.Read, starred ?? previous.Starred);
    }

    public async Task<DiscussionThread> DiscussionAsync(long id, CancellationToken ct)
    {
        var thread = await ReadAsync("entries.discussion", new JsonObject { ["id"] = id },
            WireJson.Default.DiscussionThread, ct).ConfigureAwait(false);
        if (thread.Comments is null || thread.Comments.Any(comment => comment is null || comment.Blocks is null))
        {
            throw new DaemonProtocolException("The daemon returned an incomplete discussion.");
        }

        return thread;
    }

    private async Task<T> ReadAsync<T>(string method, JsonObject? parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);

    private static TimelineArticle ToTimelineArticle(Entry entry) => new(entry.Id,
        string.IsNullOrWhiteSpace(entry.Title) ? "Untitled article" : entry.Title, entry.FeedTitle,
        entry.Read, entry.Starred, entry.FeedId);

    internal sealed record CatalogItems<T>(T[] Items);
    internal sealed record Feed(long Id, long? FolderId, string? Title, string Url, long Unread, long Starred, long Entries);
    internal sealed record Folder(long Id, long? ParentId, string Name);
    internal sealed record Entry(long Id, string? Title, string? FeedTitle, bool Read, bool Starred,
        string? Snippet, string? Summary, long SortAt, long? FeedId);
    internal sealed record ArticleBody(string? Title, string? FeedTitle, string? Author, string? DiscussionUrl, string Body,
        bool Read, bool Starred, string? Url = null);
    internal sealed record FetchFullReply(string? Status);
    internal sealed record MarkReply(MarkState? Previous);
    internal sealed record MarkState(bool Read, bool Starred);
    internal sealed record BulkMarkReply(PreviousRead[]? Previous);
    internal sealed record PreviousRead(long Id, bool Read);
    internal sealed record EntryPage(Entry[] Items, string? NextCursor);
}
