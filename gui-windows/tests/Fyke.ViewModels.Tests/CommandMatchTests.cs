using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class CommandMatchTests
{
    [Theory]
    [InlineData("dsf", "Desktop fixture", true)]
    [InlineData("F S", "Focus sidebar", true)]
    [InlineData("dsk", "Desktop fixture", true)]
    [InlineData("fdt", "Desktop fixture", false)]
    public void MatchesLettersInOrderRegardlessOfCaseAndSpaces(string query, string title, bool matches)
    {
        Assert.Equal(matches, CommandMatch.Score(query, title).HasValue);
    }

    [Fact]
    public void FavorsWordStartsAndShortPrefixes()
    {
        Assert.True(CommandMatch.Score("rf", "Refresh feeds") > CommandMatch.Score("rf", "Transfer files"));
        Assert.True(CommandMatch.Score("read", "Read") > CommandMatch.Score("read", "Read article"));
        Assert.Equal(0, CommandMatch.Score(" ", "Starred"));
    }
}
