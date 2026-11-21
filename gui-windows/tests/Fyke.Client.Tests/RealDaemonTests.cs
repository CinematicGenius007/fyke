using System.Text.Json.Nodes;
using System.Diagnostics;

namespace Fyke.Client.Tests;

[Collection("Daemon environment")]
public sealed class RealDaemonTests
{
    [RealDaemonFact]
    public async Task StartsDaemonAndReplaysViewEvent()
    {
        var program = Path.GetFullPath(Environment.GetEnvironmentVariable("FYKE_TEST_BIN")!);
        Assert.True(File.Exists(program), $"Daemon executable does not exist: {program}");

        // AF_UNIX has a short address limit. A space also exercises argv quoting.
        var folder = Path.Combine(Path.GetTempPath(), $"fyke {Guid.NewGuid():N}"[..13]);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            await using var client = new DaemonClient(new DaemonClientOptions
            {
                DataFolder = folder,
                ProcessStarter = new FykeProcessStarter(program),
            });

            await client.StartAsync(deadline.Token);
            Assert.Equal(ConnectionState.Connected, client.State);
            Assert.True(client.DaemonApiVersion >= DaemonClient.RequiredApiVersion);

            var view = await client.CallAsync("views.put", new JsonObject { ["name"] = "Windows smoke", ["rule"] = new JsonObject() }, deadline.Token);
            var id = view.GetProperty("id").GetInt64();

            // The write precedes subscription, so the event must arrive through replay.
            await foreach (var change in client.EventsAsync(deadline.Token))
            {
                if (change.Type == "view.changed")
                {
                    Assert.Equal(id, change.SubjectId);
                    return;
                }
            }

            Assert.Fail("The event subscription ended before replaying the view change.");
        }
        finally
        {
            if (Directory.Exists(folder))
            {
                var stop = new ProcessStartInfo(program) { UseShellExecute = false, CreateNoWindow = true };
                stop.ArgumentList.Add("daemon");
                stop.ArgumentList.Add("stop");
                stop.Environment["FYKE_HOME"] = folder;
                using var process = Process.Start(stop)!;
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                await process.WaitForExitAsync(cleanup.Token);
                while (File.Exists(Path.Combine(folder, "fyked.sock")))
                {
                    await Task.Delay(50, cleanup.Token);
                }

                Directory.Delete(folder, recursive: true);
            }
        }
    }

    [RealDaemonFact(windowsOnly: true)]
    public async Task DiscoversMovedDataThroughTheWindowsLocationFile()
    {
        var program = Path.GetFullPath(Environment.GetEnvironmentVariable("FYKE_TEST_BIN")!);
        var profile = Path.Combine(Path.GetTempPath(), $"fyke-{Guid.NewGuid():N}"[..13]);
        var target = Path.Combine(profile, "Données déplacées");
        var previousHome = Environment.GetEnvironmentVariable("FYKE_HOME");
        var previousLocal = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));

        // The client and CLI must discover the same location from the same isolated profile.
        Environment.SetEnvironmentVariable("FYKE_HOME", null);
        Environment.SetEnvironmentVariable("LOCALAPPDATA", profile);
        try
        {
            var options = new DaemonClientOptions { ProcessStarter = new FykeProcessStarter(program) };
            long viewId;
            await using (var original = new DaemonClient(options))
            {
                await original.StartAsync(deadline.Token);
                var view = await original.CallAsync("views.put", new JsonObject { ["name"] = "Before move", ["rule"] = new JsonObject() }, deadline.Token);
                viewId = view.GetProperty("id").GetInt64();
            }

            await RunFykeAsync(program, deadline.Token, "data", "move", target);

            await using var moved = new DaemonClient(options);
            await moved.StartAsync(deadline.Token);
            var preserved = await moved.CallAsync("views.get", new JsonObject { ["id"] = viewId }, deadline.Token);
            Assert.Equal("Before move", preserved.GetProperty("name").GetString());
            Assert.True(File.Exists(FykeHome.SocketPath(target)));
            Assert.Equal(new[] { FykeHome.LocationFileName }, Directory.GetFileSystemEntries(Path.Combine(profile, "Fyke")).Select(Path.GetFileName));
        }
        finally
        {
            try
            {
                if (Directory.Exists(profile))
                {
                    using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                    var socket = FykeHome.SocketPath(FykeHome.Discover());
                    if (File.Exists(socket))
                    {
                        await RunFykeAsync(program, cleanup.Token, "daemon", "stop");
                        while (File.Exists(socket))
                        {
                            await Task.Delay(50, cleanup.Token);
                        }
                    }

                    Directory.Delete(profile, recursive: true);
                }
            }
            finally
            {
                Environment.SetEnvironmentVariable("FYKE_HOME", previousHome);
                Environment.SetEnvironmentVariable("LOCALAPPDATA", previousLocal);
            }
        }
    }

    private static async Task RunFykeAsync(string program, CancellationToken ct, params string[] arguments)
    {
        var start = new ProcessStartInfo(program) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start fyke.");
        await process.WaitForExitAsync(ct);
        Assert.True(process.ExitCode == 0, $"fyke {string.Join(' ', arguments)} exited with code {process.ExitCode}.");
    }

}

[CollectionDefinition("Daemon environment", DisableParallelization = true)]
public sealed class DaemonEnvironmentTestsDefinition
{
}

internal sealed class RealDaemonFactAttribute : FactAttribute
{
    public RealDaemonFactAttribute(bool windowsOnly = false)
    {
        if (windowsOnly && !OperatingSystem.IsWindows())
        {
            Skip = "Requires Windows data-directory discovery.";
        }
        else if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("FYKE_TEST_BIN")))
        {
            Skip = "Set FYKE_TEST_BIN to the built daemon executable.";
        }
    }
}
