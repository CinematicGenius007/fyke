using System.Text.Json;
using System.Text.Json.Nodes;
using Fyke.Client;

namespace Fyke.ViewModels;

public sealed record FeedCandidate(string Url, string? Title, string[] Latest)
{
    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "Untitled feed" : Title;
}

public sealed record FeedSubscriptionRequest(FeedCandidate Candidate, string? Title);

/// <summary>Resumes a group of subscriptions at the first unconfirmed step.</summary>
public sealed class FeedSubscriptionBatch(IEnumerable<FeedSubscriptionRequest> requests, bool allowPrivateNetwork)
{
    private readonly Queue<FeedSubscriptionRequest> remaining = new(requests);
    private long? feedAwaitingFolder;

    public int AddedCount { get; private set; }
    public int FetchWarningCount { get; private set; }

    public async Task CompleteAsync(FeedSubscriptions subscriptions, long? folderId, CancellationToken ct)
    {
        while (remaining.TryPeek(out var request))
        {
            if (feedAwaitingFolder is null)
            {
                var added = await subscriptions.SubscribeAsync(request, allowPrivateNetwork, ct).ConfigureAwait(false);
                feedAwaitingFolder = added.Id;
                AddedCount++;
                if (added.Status is "failed" or "gone")
                {
                    FetchWarningCount++;
                }
            }

            if (folderId is long folder)
            {
                await subscriptions.PlaceAsync(feedAwaitingFolder.Value, folder, ct).ConfigureAwait(false);
            }

            // A failed move keeps the feed's confirmed ID so retry can place it directly.
            remaining.Dequeue();
            feedAwaitingFolder = null;
        }
    }
}

public sealed class FeedSubscriptions(IDaemonClient client)
{
    public static Uri? Address(string input)
    {
        var address = input.Trim();
        if (address.Length == 0 || address.Any(char.IsWhiteSpace))
        {
            return null;
        }

        if (ArticleBlock.WebAddress(address) is { } web)
        {
            return web;
        }

        return address.Contains("://", StringComparison.Ordinal) ? null : ArticleBlock.WebAddress($"https://{address}");
    }

    public async Task<IReadOnlyList<FeedCandidate>> DiscoverAsync(Uri address, bool allowPrivateNetwork, CancellationToken ct)
    {
        var reply = await client.CallAsync("feeds.preview",
                new JsonObject { ["url"] = address.AbsoluteUri, ["allow_private_network"] = allowPrivateNetwork }, ct)
            .ConfigureAwait(false);
        var catalog = reply.Deserialize(WireJson.Default.FeedPreview);
        if (catalog?.Items is not { } items)
        {
            throw new DaemonProtocolException("The daemon returned an incomplete feed preview.");
        }

        return items.Where(candidate => candidate is not null && ArticleBlock.WebAddress(candidate.Url) is not null)
            .DistinctBy(candidate => candidate.Url, StringComparer.Ordinal).ToArray();
    }

    internal async Task<FeedRefresh> SubscribeAsync(FeedSubscriptionRequest request, bool allowPrivateNetwork, CancellationToken ct)
    {
        var parameters = new JsonObject
        {
            ["url"] = request.Candidate.Url,
            ["title"] = request.Title,
            ["allow_private_network"] = allowPrivateNetwork,
        };
        var reply = await client.CallAsync("feeds.add", parameters, ct).ConfigureAwait(false);
        return CatalogEdits.ReadRefresh(reply);
    }

    internal Task PlaceAsync(long id, long folderId, CancellationToken ct) => CatalogEdits.MoveFeedAsync(client, id, folderId, ct);

    internal sealed record FeedPreview(FeedCandidate[]? Items);
}
