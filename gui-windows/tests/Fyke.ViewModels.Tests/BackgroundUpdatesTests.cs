using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class BackgroundUpdatesTests
{
    [Theory]
    [InlineData("installed\n", true)]
    [InlineData("not installed\r\n", false)]
    [InlineData("", null)]
    public void StatusIsReadFromTheCommand(string output, bool? expected) =>
        Assert.Equal(expected, BackgroundUpdates.ParseStatus(output));

    [Fact]
    public async Task AsksAndChangesThroughFykeService()
    {
        var calls = new List<string>();
        var service = new BackgroundUpdates("C:\\Fyke\\fyke.exe", (program, arguments, _) =>
        {
            calls.Add($"{program} {string.Join(' ', arguments)}");
            return Task.FromResult(arguments[1] == "status" ? (0, "not installed\n") : (0, "installed: the daemon now runs from login\n"));
        });

        Assert.False(await service.IsOnAsync(CancellationToken.None));
        Assert.Null(await service.SetAsync(true, CancellationToken.None));
        Assert.Null(await service.SetAsync(false, CancellationToken.None));

        Assert.Equal(
            ["C:\\Fyke\\fyke.exe service status", "C:\\Fyke\\fyke.exe service install", "C:\\Fyke\\fyke.exe service uninstall"],
            calls);
    }

    [Fact]
    public async Task AFailureSaysWhatDidNotHappenAndWhy()
    {
        var service = new BackgroundUpdates("fyke.exe", (_, _, _) => Task.FromResult((1, "error: RegistryFailed\n")));

        Assert.Null(await service.IsOnAsync(CancellationToken.None));
        Assert.Equal("Fyke couldn’t start updating in the background. error: RegistryFailed",
            await service.SetAsync(true, CancellationToken.None));
        Assert.Equal("Fyke couldn’t stop updating in the background. error: RegistryFailed",
            await service.SetAsync(false, CancellationToken.None));
    }
}
