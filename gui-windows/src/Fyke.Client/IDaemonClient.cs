using System.Text.Json;

namespace Fyke.Client;

/// <summary>Where the client stands with the daemon.</summary>
public enum ConnectionState
{
    /// <summary>Starting: looking for the daemon, starting it if it is not running.</summary>
    Connecting,

    /// <summary>The daemon answers and speaks a version this app understands.</summary>
    Connected,

    /// <summary>The connection dropped and the client is getting it back.</summary>
    Reconnecting,

    /// <summary>The client gave up. <see cref="FailureReason"/> says why. Calling <c>StartAsync</c> again retries.</summary>
    Failed,
}

/// <summary>
/// One change the daemon announced. <see cref="Type"/> is the daemon's name for it, such as
/// <c>entry.new</c>. A client-made event of type <see cref="GapType"/> means events were
/// missed, so the app must reload what it shows.
/// </summary>
public sealed record DaemonEvent(long Seq, string Type, long? SubjectId)
{
    /// <summary>
    /// The type of the event the client inserts when it cannot prove it saw every change:
    /// the daemon pruned the ones it missed, or the daemon's event log started over.
    /// </summary>
    public const string GapType = "events.gap";

    /// <summary>True for the client-made gap event.</summary>
    public bool IsGap => Type == GapType;
}

/// <summary>The app's only way to the data. See docs/api.md.</summary>
public interface IDaemonClient : IAsyncDisposable
{
    ConnectionState State { get; }

    /// <summary>
    /// Raised on whatever thread changed the state. The second argument is a
    /// <see cref="FailureReason"/> code when the state is <see cref="ConnectionState.Failed"/>, and null otherwise.
    /// Handlers must not block.
    /// </summary>
    event Action<ConnectionState, string?>? StateChanged;

    /// <summary>
    /// Finds the daemon, starting it if needed, and checks its version. Completes when connected.
    /// Throws <see cref="DaemonUnavailableException"/> (the state is then Failed) when it cannot.
    /// Calling it again from Failed retries; calling it while connected does nothing.
    /// </summary>
    Task StartAsync(CancellationToken ct);

    /// <summary>
    /// One request and its reply: the <c>result</c> member. Parameter names are written in
    /// snake_case. Throws <see cref="DaemonRpcException"/> for an error reply,
    /// <see cref="TimeoutException"/> when the daemon does not answer in time, and
    /// <see cref="DaemonUnavailableException"/> when the daemon cannot be reached.
    /// </summary>
    Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken ct);

    /// <summary>
    /// Live changes, resuming after the last event seen whenever the stream drops. The
    /// sequence has one reader at a time and ends only when <paramref name="ct"/> is cancelled
    /// or the client is disposed.
    /// </summary>
    IAsyncEnumerable<DaemonEvent> EventsAsync(CancellationToken ct);
}
