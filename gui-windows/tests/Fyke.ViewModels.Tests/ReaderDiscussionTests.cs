using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderDiscussionTests
{
    [Theory]
    [InlineData("https://news.ycombinator.com/item?id=41")]
    [InlineData("http://NEWS.YCOMBINATOR.COM/item?p=2&id=41#comment")]
    public void RecognizesAThreadTheDaemonCanRead(string address)
    {
        Assert.Equal(41UL, DiscussionLink.FromAddress(address)?.HackerNewsItem);
    }

    [Theory]
    [InlineData("https://example.org/comments/41")]
    [InlineData("https://news.ycombinator.com/user?id=41")]
    [InlineData("https://news.ycombinator.com.evil.example/item?id=41")]
    [InlineData("https://news.ycombinator.com:443/item?id=41")]
    [InlineData("https://news.ycombinator.com/item?id=%34%31")]
    [InlineData("https://news.ycombinator.com/other/../item?id=41")]
    [InlineData("https://news.ycombinator.com/item?id=no&id=41")]
    public void OtherWebAddressesStayBrowserLinks(string address)
    {
        Assert.Null(Assert.IsType<DiscussionLink>(DiscussionLink.FromAddress(address)).HackerNewsItem);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("file:///tmp/discussion")]
    [InlineData("https://name@news.ycombinator.com/item?id=41")]
    public void RejectsNonWebDiscussionAddresses(string? address)
    {
        Assert.Null(DiscussionLink.FromAddress(address));
    }

    [Fact]
    public async Task ReadsTheThreadOnDemandWithTheSelectedEntryId()
    {
        using var article = JsonDocument.Parse("""
            {"title":"Story","discussion_url":"https://news.ycombinator.com/item?id=41","body":"[]"}
            """);
        using var discussion = JsonDocument.Parse("""
            {"truncated":true,"comments":[
                {"id":100,"author":null,"at":null,"depth":0,"blocks":[]},
                {"id":101,"author":"reader","at":123000,"depth":1,"blocks":[{"t":"text","v":"A reply"}]}
            ]}
            """);
        var calls = new List<string>();
        var fake = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal(6, JsonSerializer.SerializeToElement(parameters).GetProperty("Id").GetInt64());
                calls.Add(method);
                return method == "entries.get" ? article.RootElement : discussion.RootElement;
            },
        };
        var reader = new ReaderData(fake);

        var story = await reader.ArticleAsync(6, CancellationToken.None);

        Assert.Equal(41UL, story.Discussion?.HackerNewsItem);
        Assert.Equal("entries.get", Assert.Single(calls));

        var thread = await reader.DiscussionAsync(6, CancellationToken.None);

        Assert.Equal(["entries.get", "entries.discussion"], calls);
        Assert.True(thread.Truncated);
        Assert.Null(thread.Comments[0].Author);
        Assert.Equal(1, thread.Comments[1].Depth);
        Assert.Equal("A reply", Assert.Single(thread.Comments[1].Blocks).Text);
    }

    [Fact]
    public void HiddenRepliesStopAtTheNextSiblingAndRetainTheirOwnDisclosure()
    {
        DiscussionComment[] comments =
        [
            new(10, "One", null, 0, []),
            new(11, null, null, 1, []),
            new(12, "Nested", null, 2, []),
            new(13, "Sibling", null, 1, []),
            new(14, "Other", null, 0, []),
        ];
        var rows = DiscussionRows.FromComments(comments);
        var collapsed = new HashSet<int> { 0, 1 };

        Assert.Equal([3, 1, 0, 0, 0], rows.Select(row => row.ReplyCount));
        Assert.Equal([0, 4], DiscussionRows.Visible(rows, collapsed).Select(row => row.Index));

        collapsed.Remove(0);

        Assert.Equal([0, 1, 3, 4], DiscussionRows.Visible(rows, collapsed).Select(row => row.Index));
    }
}
