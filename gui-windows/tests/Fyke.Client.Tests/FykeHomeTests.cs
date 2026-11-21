namespace Fyke.Client.Tests;

public sealed class FykeHomeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "fh" + Guid.NewGuid().ToString("N")[..8]);

    public FykeHomeTests() => Directory.CreateDirectory(_root);

    public void Dispose() => Directory.Delete(_root, recursive: true);

    private static Func<string, string?> Env(params (string Key, string Value)[] values) =>
        name => values.Where(v => v.Key == name).Select(v => v.Value).FirstOrDefault();

    [Fact]
    public void FykeHomeWinsOnEveryPlatform()
    {
        var env = Env(("FYKE_HOME", "/data/fyke"), ("LOCALAPPDATA", _root), ("HOME", "/home/me"));
        Assert.Equal("/data/fyke", FykeHome.Resolve(env, windows: true));
        Assert.Equal("/data/fyke", FykeHome.Resolve(env, windows: false));
    }

    [Fact]
    public void WindowsDefaultsToFykeInLocalAppData()
    {
        Assert.Equal(Path.Combine(_root, "Fyke"), FykeHome.Resolve(Env(("LOCALAPPDATA", _root)), windows: true));
    }

    [Fact]
    public void WindowsFollowsTheLocationPointer()
    {
        var anchor = Path.Combine(_root, "Fyke");
        Directory.CreateDirectory(anchor);
        File.WriteAllText(Path.Combine(anchor, FykeHome.LocationFileName), "  D:\\Elsewhere\\Fyke \r\n");
        Assert.Equal("D:\\Elsewhere\\Fyke", FykeHome.Resolve(Env(("LOCALAPPDATA", _root)), windows: true));
    }

    [Fact]
    public void AnEmptyPointerMeansTheDefaultFolder()
    {
        var anchor = Path.Combine(_root, "Fyke");
        Directory.CreateDirectory(anchor);
        File.WriteAllText(Path.Combine(anchor, FykeHome.LocationFileName), " \r\n");
        Assert.Equal(anchor, FykeHome.Resolve(Env(("LOCALAPPDATA", _root)), windows: true));
    }

    [Fact]
    public void FykeHomeBeatsThePointer()
    {
        var anchor = Path.Combine(_root, "Fyke");
        Directory.CreateDirectory(anchor);
        File.WriteAllText(Path.Combine(anchor, FykeHome.LocationFileName), "D:\\Elsewhere");
        Assert.Equal("E:\\Test", FykeHome.Resolve(Env(("FYKE_HOME", "E:\\Test"), ("LOCALAPPDATA", _root)), windows: true));
    }

    [Fact]
    public void WindowsWithoutLocalAppDataCannotSay()
    {
        var failure = Assert.Throws<DaemonUnavailableException>(() => FykeHome.Resolve(Env(), windows: true));
        Assert.Equal(FailureReason.NotResponding, failure.Reason);
    }

    [Fact]
    public void OtherSystemsUseDotFykeInTheHomeFolder()
    {
        Assert.Equal(Path.Combine("/home/me", ".fyke"), FykeHome.Resolve(Env(("HOME", "/home/me")), windows: false));
        Assert.Equal(Path.Combine("C:\\Users\\me", ".fyke"), FykeHome.Resolve(Env(("USERPROFILE", "C:\\Users\\me")), windows: false));
    }

    [Fact]
    public void TheSocketIsFykedSockInsideTheFolder()
    {
        Assert.Equal(Path.Combine("/data", "fyked.sock"), FykeHome.SocketPath("/data"));
    }

    [Fact]
    public void TheStarterFindsTheProgramNamedByTheEnvironmentOnly()
    {
        var program = Path.Combine(_root, "my-fyke");
        File.WriteAllText(program, string.Empty);
        Assert.Equal(program, new FykeProcessStarter(environment: Env(("FYKE_BIN", program)), appFolder: _root).FindProgram());
        Assert.Null(new FykeProcessStarter(environment: Env(("FYKE_BIN", Path.Combine(_root, "missing"))), appFolder: _root).FindProgram());
    }

    [Fact]
    public void TheStarterLooksBesideTheAppThenOnPath()
    {
        var name = OperatingSystem.IsWindows() ? "fyke.exe" : "fyke";
        var beside = Path.Combine(_root, "app");
        var onPath = Path.Combine(_root, "bin");
        Directory.CreateDirectory(beside);
        Directory.CreateDirectory(onPath);
        File.WriteAllText(Path.Combine(onPath, name), string.Empty);
        var path = onPath;
        Assert.Equal(Path.Combine(onPath, name), new FykeProcessStarter(environment: Env(("PATH", path)), appFolder: beside).FindProgram());
        File.WriteAllText(Path.Combine(beside, name), string.Empty);
        Assert.Equal(Path.Combine(beside, name), new FykeProcessStarter(environment: Env(("PATH", path)), appFolder: beside).FindProgram());
    }

    [Fact]
    public async Task TheStarterRefusesWithoutAProgram()
    {
        var starter = new FykeProcessStarter(environment: Env(), appFolder: _root);
        var failure = await Assert.ThrowsAsync<DaemonProgramNotFoundException>(() => starter.StartAsync(_root, CancellationToken.None));
        Assert.Equal(FailureReason.ProgramMissing, failure.Reason);
    }
}
