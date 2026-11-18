using System.Diagnostics;

namespace Fyke.Client.Tests;

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

            var view = await client.CallAsync("views.put", new { Name = "Windows smoke", Rule = new { } }, deadline.Token);
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
}

internal sealed class RealDaemonFactAttribute : FactAttribute
{
    public RealDaemonFactAttribute()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("FYKE_TEST_BIN")))
        {
            Skip = "Set FYKE_TEST_BIN to the built daemon executable.";
        }
    }
}
