using System.Text.Json;
using System.Text.Json.Serialization;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class SavedViewsTests
{
    private static readonly JsonSerializerOptions Wire = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [Fact]
    public async Task SaveRoundTripsTheRuleAndUsesTheLastReadRevision()
    {
        var payloads = new List<JsonElement>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("views.put", method);
                var request = JsonSerializer.SerializeToElement(parameters, Wire);
                payloads.Add(request);
                return JsonSerializer.SerializeToElement(new
                {
                    id = 7, name = request.GetProperty("name"), rule = request.GetProperty("rule"),
                    revision = payloads.Count, sentence = "Matching articles",
                });
            },
        };
        var views = new SavedViews(client);
        var rule = ViewRule.FromSearch(" news \t", unreadOnly: true) with
        {
            Feeds = [1],
            Folders = [8],
            AnyWords = true,
            Host = "example.com",
            Subdomains = true,
            PathPrefix = "/docs",
            ExcludePathPrefix = ["/docs/old"],
            WithinDays = 7,
        };

        var created = await views.SaveAsync(" News ", rule, null, CancellationToken.None);
        var updated = await views.SaveAsync("Current news", created.Rule, created, CancellationToken.None);

        Assert.False(payloads[0].TryGetProperty("id", out _));
        Assert.False(payloads[0].TryGetProperty("expected_revision", out _));
        Assert.Equal("News", created.Name);
        Assert.Equal(7, payloads[1].GetProperty("id").GetInt64());
        Assert.Equal(1, payloads[1].GetProperty("expected_revision").GetInt64());
        Assert.Equal(2, updated.Revision);
        Assert.Equal("Current news", updated.Name);
        Assert.Equal("news", updated.Rule.Words);
        Assert.Equal("unread", updated.Rule.State);
        Assert.Equal(JsonSerializer.Serialize(rule, Wire), JsonSerializer.Serialize(updated.Rule, Wire));
    }

    [Fact]
    public async Task OldDaemonWithoutViewsStillLoadsTheCatalog()
    {
        var client = new FakeClient
        {
            OnCall = (method, _) => method == "views.list"
                ? throw new DaemonRpcException("UnknownMethod", -32601, null, null)
                : JsonSerializer.SerializeToElement(new { items = Array.Empty<string>() }),
        };
        var destinations = await new ReaderData(client).DestinationsAsync(CancellationToken.None);

        Assert.Equal(new[] { ReaderScope.All, ReaderScope.Starred }, destinations.Select(row => row.Scope));
    }

    [Fact]
    public async Task BulkReadInAViewOnlyCollectsItsUnreadMatches()
    {
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                var request = JsonSerializer.SerializeToElement(parameters, Wire);
                if (method == "entries.list")
                {
                    Assert.Equal(7, request.GetProperty("view_id").GetInt64());
                    Assert.False(request.GetProperty("unread_only").GetBoolean());
                    return JsonSerializer.SerializeToElement(new
                    {
                        items = new[] { new { id = 1, read = true }, new { id = 2, read = false } },
                    });
                }

                Assert.Equal("entries.mark_many", method);
                Assert.Equal(2, Assert.Single(request.GetProperty("ids").EnumerateArray()).GetInt64());
                return JsonSerializer.SerializeToElement(new { previous = new[] { new { id = 2, read = false } } });
            },
        };
        var change = new BulkReadChange(new(ReaderScope.View, 7, "View", 0, 1));

        await change.ApplyAsync(new ReaderData(client), CancellationToken.None);

        Assert.Equal(1, change.RemainingCount);
        Assert.True(change.Includes(2));
    }

    [Fact]
    public async Task RemoveReportsDependentRoutinesWithoutDetachingThem()
    {
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("views.remove", method);
                var request = JsonSerializer.SerializeToElement(parameters, Wire);
                Assert.Equal(7, request.GetProperty("id").GetInt64());
                Assert.False(request.GetProperty("detach").GetBoolean());
                long[] routines = [8, 9];
                return JsonSerializer.SerializeToElement(new { kind = "in_use", routine_ids = routines });
            },
        };

        var result = await new SavedViews(client).RemoveAsync(7, detach: false, CancellationToken.None);

        Assert.False(result.Ok);
        Assert.Equal("in_use", result.Kind);
        Assert.NotNull(result.RoutineIds);
        Assert.Equal([8L, 9L], result.RoutineIds);
    }
}
