using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class SingleInstanceTests
{
    [Fact]
    public void EachDataFolderHasItsOwnWindow()
    {
        Assert.Equal("Fyke", SingleInstance.Key(null));
        Assert.Equal("Fyke", SingleInstance.Key(" "));

        var home = Path.Combine(Path.GetTempPath(), "fyke-home");
        var key = SingleInstance.Key(home);
        Assert.StartsWith("Fyke-", key, StringComparison.Ordinal);
        Assert.Equal(21, key.Length);
        Assert.Equal(key, SingleInstance.Key(home + Path.DirectorySeparatorChar));
        Assert.NotEqual(key, SingleInstance.Key(home + "-other"));
    }
}
