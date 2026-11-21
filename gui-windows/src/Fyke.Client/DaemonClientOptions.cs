namespace Fyke.Client;

/// <summary>Settings for <see cref="DaemonClient"/>. The defaults suit the app.</summary>
public sealed class DaemonClientOptions
{
    /// <summary>The data folder. Null finds it with <see cref="FykeHome.Discover"/>, each time the client connects.</summary>
    public string? DataFolder { get; init; }

    /// <summary>The socket. Null means <c>fyked.sock</c> in the data folder.</summary>
    public string? SocketPath { get; init; }

    /// <summary>Starts the daemon when the socket does not answer. Null starts the real program.</summary>
    public IDaemonProcessStarter? ProcessStarter { get; init; }

    /// <summary>The oldest <c>api_version</c> the app can use. <c>api_version</c> in src/ops.zig.</summary>
    public long RequiredApiVersion { get; init; } = DaemonClient.RequiredApiVersion;

    /// <summary>Allow one graceful replacement of an older daemon on initial connection.</summary>
    public bool ReplaceOlderDaemon { get; init; }

    /// <summary>How long an ordinary call may take.</summary>
    public TimeSpan CallTimeout { get; init; } = TimeSpan.FromSeconds(35);

    /// <summary>How long a call that waits on the network may take.</summary>
    public TimeSpan SlowCallTimeout { get; init; } = TimeSpan.FromSeconds(120);

    /// <summary>The operations that get <see cref="SlowCallTimeout"/>: the ones the macOS app sends with <c>callSlow</c>.</summary>
    public IReadOnlySet<string> SlowMethods { get; init; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "writers.check",
        "feeds.refresh",
        "feeds.refresh_all",
        "feeds.preview",
        "feeds.add",
        "entries.fetch_full",
        "entries.discussion",
        "storage.get",
        "storage.free",
        "opml.import",
    };

    /// <summary>
    /// The app posts routine notifications itself, so the daemon leaves the events it
    /// receives to it. With no such app connected, the daemon starts one to post them
    /// (<c>src/notify.zig</c>).
    /// </summary>
    public bool PostsNotifications { get; init; }

    /// <summary>How long <c>StartAsync</c> keeps trying to reach a daemon, starting one if needed.</summary>
    public TimeSpan StartupTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>How long a dropped connection is retried before the client gives up.</summary>
    public TimeSpan ReconnectTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>The first wait between attempts. It doubles up to <see cref="MaxRetryDelay"/>.</summary>
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromMilliseconds(100);

    public TimeSpan MaxRetryDelay { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>How often the daemon is started again while it still does not answer.</summary>
    public TimeSpan StartRetryInterval { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>The longest line the client accepts from the daemon, without its newline.</summary>
    public int MaxLineBytes { get; init; } = 16 * 1024 * 1024;

    /// <summary>The longest request the client sends. The daemon closes a connection that sends more (1 MiB).</summary>
    public int MaxRequestBytes { get; init; } = 1024 * 1024;

    /// <summary>Calls that may run at once, each on its own connection.</summary>
    public int MaxConcurrentCalls { get; init; } = 8;

    /// <summary>Connections kept open between calls.</summary>
    public int MaxIdleConnections { get; init; } = 4;
}
