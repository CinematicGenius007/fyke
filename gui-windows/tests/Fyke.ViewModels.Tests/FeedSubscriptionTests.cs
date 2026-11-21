using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class FeedSubscriptionTests
{
    [Theory]
    [InlineData(" example.org/feed ", "https://example.org/feed")]
    [InlineData("http://localhost:9000/feed", "http://localhost:9000/feed")]
    [InlineData("file:///tmp/feed.xml", null)]
    [InlineData("https://owner@example.org/feed", null)]
    [InlineData("example.org two", null)]
    public void AcceptsWebAddressesAndAddsHttpsToBareSites(string input, string? expected)
    {
        Assert.Equal(expected, FeedSubscriptions.Address(input)?.AbsoluteUri);
    }

    [Fact]
    public async Task DiscoversDistinctWebFeedsWithTheChosenNetworkPolicy()
    {
        using var response = JsonDocument.Parse("""
            {"items":[
              {"url":"https://example.org/news","title":"News","latest":["Today"]},
              {"url":"https://example.org/news","title":"Duplicate","latest":[]},
              {"url":"file:///tmp/rss.xml","title":"A file","latest":[]}
            ]}
            """);
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("feeds.preview", method);
                var request = parameters.GetValueOrDefault();
                Assert.Equal("https://example.org/", request.GetProperty("url").GetString());
                Assert.False(request.GetProperty("allow_private_network").GetBoolean());
                return response.RootElement;
            },
        };

        var items = await new FeedSubscriptions(client).DiscoverAsync(new Uri("https://example.org"), false, CancellationToken.None);

        var candidate = Assert.Single(items);
        Assert.Equal("News", candidate.DisplayTitle);
        Assert.Equal("Today", Assert.Single(candidate.Latest));
    }

    [Fact]
    public async Task RetryPlacesAnAddedFeedWithoutSubscribingToItAgain()
    {
        var additions = new List<string?>();
        var placements = new List<(long Id, long Folder)>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                var request = parameters.GetValueOrDefault();
                if (method == "feeds.add")
                {
                    Assert.True(request.GetProperty("allow_private_network").GetBoolean());
                    additions.Add(request.GetProperty("url").GetString());
                    Assert.Equal(additions.Count == 1 ? "Renamed" : null, request.Optional("title").GetString());
                    return JsonSerializer.SerializeToElement(new { id = 40 + additions.Count, status = "updated" });
                }

                Assert.Equal("feeds.update", method);
                placements.Add((request.GetProperty("id").GetInt64(), request.GetProperty("folder_id").GetInt64()));
                if (placements.Count == 1)
                {
                    throw new DaemonRpcException("NoSuchFolder", -32000, "NoSuchFolder", null);
                }

                return JsonSerializer.SerializeToElement(new { ok = true });
            },
        };
        var requests = new FeedSubscriptionRequest[]
        {
            new(new("http://localhost:9000/news", "News", []), "Renamed"),
            new(new("http://localhost:9000/alerts", "Alerts", []), null),
        };
        var subscriptions = new FeedSubscriptions(client);
        var batch = new FeedSubscriptionBatch(requests, allowPrivateNetwork: true);

        await Assert.ThrowsAsync<DaemonRpcException>(() => batch.CompleteAsync(subscriptions, 4, CancellationToken.None));
        Assert.Equal(1, batch.AddedCount);

        await batch.CompleteAsync(subscriptions, 5, CancellationToken.None);

        Assert.Equal(2, batch.AddedCount);
        Assert.Equal(requests.Select(request => request.Candidate.Url), additions);
        Assert.Equal([(41L, 4L), (41L, 5L), (42L, 5L)], placements);
    }
}
