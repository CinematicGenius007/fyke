using System.Text.Json;

namespace Fyke.Client.Tests;

/// <summary>A starter that records its calls and, if given, brings a fake daemon up.</summary>
internal sealed class RecordingStarter : IDaemonProcessStarter
{
    private readonly Action<string>? _action;
    private int _calls;

    public RecordingStarter(Action<string>? action = null) => _action = action;

    public int Calls => Volatile.Read(ref _calls);

    public Task StartAsync(string dataFolder, CancellationToken ct)
    {
        Interlocked.Increment(ref _calls);
        _action?.Invoke(dataFolder);
        return Task.CompletedTask;
    }
}

internal sealed class ThrowingStarter : IDaemonProcessStarter
{
    public Task StartAsync(string dataFolder, CancellationToken ct) =>
        throw new DaemonProgramNotFoundException("Cannot find the fyke program.");
}

internal static class TestSupport
{
    public static readonly TimeSpan Patience = TimeSpan.FromSeconds(10);

    /// <summary>Options for a client of <paramref name="fake"/>, with waits short enough for a test.</summary>
    public static DaemonClientOptions Options(FakeDaemon fake, IDaemonProcessStarter? starter = null, bool replaceOlder = false) => new()
    {
        DataFolder = fake.Folder,
        ReplaceOlderDaemon = replaceOlder,
        SocketPath = fake.SocketPath,
        ProcessStarter = starter ?? new RecordingStarter(),
        RetryDelay = TimeSpan.FromMilliseconds(10),
        MaxRetryDelay = TimeSpan.FromMilliseconds(40),
        StartupTimeout = TimeSpan.FromSeconds(3),
        ReconnectTimeout = TimeSpan.FromSeconds(3),
        StartRetryInterval = TimeSpan.FromMilliseconds(200),
        CallTimeout = TimeSpan.FromSeconds(5),
    };

    public static List<(ConnectionState State, string? Reason)> Record(IDaemonClient client)
    {
        var seen = new List<(ConnectionState, string?)>();
        client.StateChanged += (state, reason) =>
        {
            lock (seen)
            {
                seen.Add((state, reason));
            }
        };
        return seen;
    }

    /// <summary>Takes <paramref name="count"/> events, failing instead of hanging.</summary>
    public static async Task<List<DaemonEvent>> TakeAsync(IAsyncEnumerator<DaemonEvent> events, int count)
    {
        using var timeout = new CancellationTokenSource(Patience);
        var taken = new List<DaemonEvent>();
        while (taken.Count < count)
        {
            var next = events.MoveNextAsync().AsTask();
            await next.WaitAsync(timeout.Token);
            if (!next.Result)
            {
                break;
            }

            taken.Add(events.Current);
        }

        return taken;
    }

    public static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow + Patience;
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException("The condition did not become true.");
            }

            await Task.Delay(10);
        }
    }

    public static string Json(JsonElement element) => element.GetRawText();
}
