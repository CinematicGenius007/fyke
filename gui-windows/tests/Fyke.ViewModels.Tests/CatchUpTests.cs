using System.Globalization;
using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class CatchUpTests
{
    private const string PageReply = """
        {"items":[
          {"id":1,"title":"First","feed_title":"Engineering","read":false,"starred":false,"snippet":"","summary":"A summary.","sort_at":1795154168586,"feed_id":2},
          {"id":2,"title":" ","feed_title":null,"read":false,"starred":false,"snippet":"A snippet.","summary":null,"sort_at":0,"feed_id":2},
          {"id":3,"title":"Read already","feed_title":"Engineering","read":true,"starred":false,"snippet":null,"summary":null,"sort_at":1,"feed_id":2}],
         "next_cursor":null}
        """;

    private static CatchUpCard Card(long id) => new(id, $"Article {id}", "Feed", 0, null);

    [Fact]
    public async Task QueueReadsUnreadArticlesOfTheDestination()
    {
        JsonElement? sent = null;
        var reader = new ReaderData(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.list", method);
                sent = parameters;
                return JsonElement.Parse(PageReply);
            },
        });

        var queue = await reader.CatchUpQueueAsync(new ReaderDestination(ReaderScope.Folder, 5, "Work", 0, 0),
            CancellationToken.None);

        Assert.Equal(5, sent!.Value.GetProperty("folder_id").GetInt64());
        Assert.True(sent.Value.GetProperty("unread_only").GetBoolean());
        Assert.Equal(ReaderData.CatchUpLimit, sent.Value.GetProperty("limit").GetInt32());
        Assert.Equal([1L, 2L], queue.Select(card => card.Id));
        Assert.Equal("A summary.", queue[0].Preview);
        Assert.Equal("Untitled", queue[1].Title);
        Assert.Equal("A snippet.", queue[1].Preview);
    }

    [Theory]
    [InlineData(CatchUpDecision.Skip, "read")]
    [InlineData(CatchUpDecision.Read, "read")]
    [InlineData(CatchUpDecision.Later, "later")]
    public async Task MarkSetsOneFlagAndReturnsTheStateBefore(CatchUpDecision decision, string flag)
    {
        JsonElement? sent = null;
        var reader = new ReaderData(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.mark_many", method);
                sent = parameters;
                return JsonElement.Parse("""{"previous":[{"id":4,"read":false,"starred":true,"later":true,"hidden":false}]}""");
            },
        });

        var before = await reader.CatchUpMarkAsync(4, decision, CancellationToken.None);

        Assert.Equal(new CatchUpMarks(false, true), before);
        Assert.Equal([4L], sent!.Value.GetProperty("ids").EnumerateArray().Select(id => id.GetInt64()));
        Assert.True(sent.Value.GetProperty(flag).GetBoolean());
        Assert.False(sent.Value.TryGetProperty(flag == "read" ? "later" : "read", out var other)
            && other.ValueKind != JsonValueKind.Null);
    }

    [Fact]
    public async Task RestorePutsBothFlagsBack()
    {
        var sent = new List<JsonElement>();
        var reader = new ReaderData(new FakeClient
        {
            OnCall = (_, parameters) =>
            {
                sent.Add(parameters!.Value);
                return JsonElement.Parse("""{"previous":[]}""");
            },
        });

        await reader.RestoreCatchUpAsync(4, new CatchUpMarks(false, true), CancellationToken.None);
        await reader.RestoreCatchUpAsync(4, null, CancellationToken.None);

        Assert.False(sent[0].GetProperty("read").GetBoolean());
        Assert.True(sent[0].GetProperty("later").GetBoolean());
        Assert.False(sent[1].GetProperty("read").GetBoolean());
        Assert.False(sent[1].GetProperty("later").GetBoolean());
    }

    [Fact]
    public void SessionDecidesInOrderAndUndoes()
    {
        var session = new CatchUpSession([Card(1), Card(2), Card(3)]);

        Assert.Equal(0, session.Progress);
        Assert.True(session.HasMoreAfterCurrent);
        Assert.Equal(1, session.Decide(CatchUpDecision.Skip)!.Id);
        Assert.Equal(2, session.Decide(CatchUpDecision.Later)!.Id);
        Assert.Equal(3, session.Current!.Id);
        Assert.False(session.HasMoreAfterCurrent);
        Assert.Equal((2L, CatchUpDecision.Later), session.Undo());
        Assert.Equal(2, session.Current!.Id);
        Assert.Equal(2, session.Decide(CatchUpDecision.Read)!.Id);
        Assert.Equal(3, session.Decide(CatchUpDecision.Skip)!.Id);
        Assert.Null(session.Current);
        Assert.Null(session.Decide(CatchUpDecision.Skip));
        Assert.Equal(1, session.Progress);
        Assert.Equal(2, session.Count(CatchUpDecision.Skip));
        Assert.Equal(0, session.Count(CatchUpDecision.Later));
        Assert.Equal(1, session.Count(CatchUpDecision.Read));
    }

    [Fact]
    public void UndoWithNothingDecidedDoesNothing()
    {
        var session = new CatchUpSession([Card(1)]);

        Assert.Null(session.Undo());
        Assert.Equal(0, session.Index);
        Assert.False(session.HasHistory);
    }

    [Fact]
    public void WordsMatchMacOs()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        try
        {
            var empty = new CatchUpSession([]);
            Assert.Equal(string.Empty, CatchUpText.Position(empty));
            Assert.Equal("Nothing unread here", CatchUpText.FinishedTitle(empty));
            Assert.Equal("Every article in Work is read.", CatchUpText.FinishedDetail(empty, "Work"));

            var session = new CatchUpSession([Card(1), Card(2)]);
            Assert.Equal("1 of 2", CatchUpText.Position(session));
            session.Decide(CatchUpDecision.Skip);
            session.Decide(CatchUpDecision.Later);
            Assert.Equal("2 of 2", CatchUpText.Position(session));
            Assert.Equal("You’re caught up", CatchUpText.FinishedTitle(session));
            Assert.Equal("Skipped 1 · Later 1 · Read 0. Articles saved for Later wait in their feeds.",
                CatchUpText.FinishedDetail(session, "Work"));
            Assert.Equal("Catching up on Work", CatchUpText.Heading("Work"));
            Assert.Equal("All", CatchUpText.Title(new ReaderDestination(ReaderScope.Today, 0, "Today", 0, 0)));
            Assert.Equal("Feed", CatchUpText.Detail(Card(1), DateTimeOffset.Now));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }
}
