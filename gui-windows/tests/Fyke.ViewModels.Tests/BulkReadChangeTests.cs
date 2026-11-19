using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class BulkReadChangeTests
{
    [Fact]
    public async Task PagesTheFolderAndRestoresOnlyArticlesThatWereUnreadAtTheWrite()
    {
        var listCalls = 0;
        var writes = new List<(bool Read, long[] Ids)>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                var sent = parameters.GetValueOrDefault();
                if (method == "entries.list")
                {
                    Assert.True(sent.GetProperty("unread_only").GetBoolean());
                    Assert.Equal(6, sent.GetProperty("folder_id").GetInt64());
                    Assert.Equal(1000, sent.GetProperty("limit").GetInt32());
                    Assert.Equal(listCalls++ == 0 ? null : "next", sent.Optional("before").GetString());
                    return listCalls == 1 ? Page([1], "next") : Page([2], null);
                }

                Assert.Equal("entries.mark_many", method);
                var read = sent.GetProperty("read").GetBoolean();
                var ids = ReadIds(sent);
                writes.Add((read, ids));
                return Reply(ids, id => !read || id == 1);
            },
        };
        var reader = new ReaderData(client);
        var change = new BulkReadChange(new(ReaderScope.Folder, 6, "News", 0, 2));

        await change.ApplyAsync(reader, CancellationToken.None);
        Assert.Equal(1, change.RemainingCount);
        Assert.False(change.Includes(1));
        Assert.True(change.Includes(2));

        await change.UndoAsync(reader, CancellationToken.None);
        Assert.Equal(2, writes.Count);
        Assert.True(writes[0].Read);
        Assert.Equal([1L, 2L], writes[0].Ids.Order());
        Assert.False(writes[1].Read);
        Assert.Equal([2L], writes[1].Ids);
        Assert.Equal(0, change.RemainingCount);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task RetainsOnlyTheBatchesStillToUndoAfterAnInterruptedWrite(bool interruptMark)
    {
        var fail = true;
        var undoBatches = new List<int>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                var sent = parameters.GetValueOrDefault();
                if (method == "entries.list")
                {
                    return !sent.TryGetProperty("before", out _)
                        ? Page(Enumerable.Range(1, 1000).Select(id => (long)id), "next")
                        : Page([1001], null);
                }

                var ids = ReadIds(sent);
                var read = sent.GetProperty("read").GetBoolean();
                if (fail && ids.Length == 1 && read == interruptMark)
                {
                    throw new DaemonProtocolException("Interrupted batch");
                }

                if (!read)
                {
                    undoBatches.Add(ids.Length);
                }

                return Reply(ids, _ => !read);
            },
        };
        var reader = new ReaderData(client);
        var change = new BulkReadChange(new(ReaderScope.All, 0, "All", 0, 1001));

        if (interruptMark)
        {
            await Assert.ThrowsAsync<DaemonProtocolException>(() => change.ApplyAsync(reader, CancellationToken.None));
            Assert.Equal(1000, change.RemainingCount);
        }
        else
        {
            await change.ApplyAsync(reader, CancellationToken.None);
            await Assert.ThrowsAsync<DaemonProtocolException>(() => change.UndoAsync(reader, CancellationToken.None));
            Assert.Equal(1, change.RemainingCount);
        }

        fail = false;
        await change.UndoAsync(reader, CancellationToken.None);
        if (interruptMark)
        {
            Assert.Equal(1000, Assert.Single(undoBatches));
        }
        else
        {
            Assert.Equal([1000, 1], undoBatches);
        }
        Assert.Equal(0, change.RemainingCount);
    }

    private static long[] ReadIds(JsonElement request) =>
        request.GetProperty("ids").EnumerateArray().Select(id => id.GetInt64()).ToArray();

    private static JsonElement Page(IEnumerable<long> ids, string? cursor) =>
        JsonSerializer.SerializeToElement(new { items = ids.Select(id => new { id, read = false }), next_cursor = cursor });

    private static JsonElement Reply(long[] ids, Func<long, bool> wasRead) =>
        JsonSerializer.SerializeToElement(new { previous = ids.Select(id => new { id, read = wasRead(id) }) });
}
