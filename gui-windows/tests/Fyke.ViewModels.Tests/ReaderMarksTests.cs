using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderMarksTests
{
    [Theory]
    [InlineData(false, null, false, true)]
    [InlineData(null, false, true, false)]
    public async Task SendsAnExplicitMarkAndPreservesTheOtherFlag(
        bool? read, bool? starred, bool expectedRead, bool expectedStarred)
    {
        using var response = JsonDocument.Parse("""{"ok":true,"previous":{"read":true,"starred":true}}""");
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("entries.mark", method);
                var sent = JsonSerializer.SerializeToElement(parameters);
                Assert.Equal(42, sent.GetProperty("Id").GetInt64());
                Assert.Equal(read, sent.GetProperty("Read").Deserialize<bool?>());
                Assert.Equal(starred, sent.GetProperty("Starred").Deserialize<bool?>());
                return response.RootElement;
            },
        };

        var result = await new ReaderData(client).MarkAsync(42, read, starred, CancellationToken.None);

        Assert.Equal(new ArticleMarks(expectedRead, expectedStarred), result);
    }
}
