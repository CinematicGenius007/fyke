using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace Fyke.Client;

/// <summary>
/// The daemon client: newline-delimited JSON-RPC over the daemon's Unix socket, as
/// <c>gui/Sources/Reader/Daemon.swift</c> does it. Calls share a small pool of connections,
/// and the event stream has a connection of its own, so a long call never delays events.
/// </summary>
public sealed class DaemonClient : IDaemonClient
{
    /// <summary><c>api_version</c> in src/ops.zig, the oldest daemon this app works with.</summary>
    public const long RequiredApiVersion = 2;

    private static readonly JsonSerializerOptions ParameterOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly DaemonClientOptions _options;
    private readonly IDaemonProcessStarter _starter;
    private readonly CancellationTokenSource _lifetime = new();

    // Serializes StartAsync and the reconnect, so only one of them talks to the daemon's startup.
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly SemaphoreSlim _slots;
    private readonly object _stateLock = new();
    private readonly object _reconnectLock = new();
    private readonly object _idleLock = new();
    private readonly object _seqLock = new();
    private readonly Stack<LineConnection> _idle = new();

    private ConnectionState _state = ConnectionState.Connecting;
    private string? _reason;
    private string? _failureMessage;
    private TaskCompletionSource _changed = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private Task? _reconnect;
    private string _socketPath = string.Empty;
    private string _dataFolder = string.Empty;
    private int _epoch;
    private long _nextId;
    private bool _started;
    private bool _disposed;
    private long? _lastSeq;
    private bool _gapPending;

    public DaemonClient(DaemonClientOptions? options = null)
    {
        _options = options ?? new DaemonClientOptions();
        _starter = _options.ProcessStarter ?? new FykeProcessStarter();
        _slots = new SemaphoreSlim(Math.Max(1, _options.MaxConcurrentCalls));
    }

    public event Action<ConnectionState, string?>? StateChanged;

    public ConnectionState State
    {
        get
        {
            lock (_stateLock)
            {
                return _state;
            }
        }
    }

    /// <summary>The daemon's <c>api_version</c> from the last handshake, or null before the first.</summary>
    public long? DaemonApiVersion { get; private set; }

    /// <summary>The sentence the last failure carried, for a log or a details line.</summary>
    public string? FailureMessage
    {
        get
        {
            lock (_stateLock)
            {
                return _failureMessage;
            }
        }
    }

    public async Task StartAsync(CancellationToken ct)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _lifetime.Token);
        await _gate.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            _started = true;
            if (State == ConnectionState.Connected)
            {
                return;
            }

            SetState(ConnectionState.Connecting, null);
            await ConnectAsync(_options.StartupTimeout, linked.Token, _options.ReplaceOlderDaemon).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            SetState(ConnectionState.Failed, FailureReason.Cancelled, "The attempt to reach the daemon was cancelled.");
            throw;
        }
        catch (DaemonUnavailableException e)
        {
            SetState(ConnectionState.Failed, e.Reason, e.Message);
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrEmpty(method);
        ObjectDisposedException.ThrowIf(_disposed, this);
        var timeout = _options.SlowMethods.Contains(method) ? _options.SlowCallTimeout : _options.CallTimeout;
        var request = BuildRequest(method, parameters);

        for (var attempt = 0; ; attempt++)
        {
            var epoch = await WaitUntilUsableAsync(ct).ConfigureAwait(false);
            try
            {
                return await CallOnceAsync(request, method, timeout, epoch, ct).ConfigureAwait(false);
            }
            catch (Exception e) when (IsTransportFailure(e))
            {
                // A lost reply can follow a committed write. Only replay operations known to read.
                if (method is not ("ping" or "stats.get" or "entries.list" or "entries.get"
                    or "entries.search" or "entries.discussion" or "feeds.list" or "feeds.preview"
                    or "folders.list" or "config.get" or "opml.export"
                    or "views.list" or "views.get" or "views.preview"))
                {
                    await TryReconnectAsync(epoch, ct).ConfigureAwait(false);
                    throw new DaemonOutcomeUnknownException(method, e);
                }
                await ReconnectAsync(epoch, ct).ConfigureAwait(false);
                if (attempt >= 1)
                {
                    throw new DaemonUnavailableException(FailureReason.NotResponding, "The connection to the daemon was lost.", e);
                }
            }
        }
    }

    public async IAsyncEnumerable<DaemonEvent> EventsAsync([EnumeratorCancellation] CancellationToken ct)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _lifetime.Token);
        LineConnection? connection = null;
        var epoch = 0;
        var failures = 0;
        try
        {
            while (!_disposed)
            {
                ct.ThrowIfCancellationRequested();
                if (connection is null)
                {
                    try
                    {
                        (connection, epoch) = await OpenSubscriptionAsync(failures, linked.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (_disposed && !ct.IsCancellationRequested)
                    {
                        yield break;
                    }

                    if (connection is null)
                    {
                        failures++;
                        continue;
                    }
                }

                if (TakeGap(out var gapSeq))
                {
                    yield return new DaemonEvent(gapSeq, DaemonEvent.GapType, null);
                }

                DaemonEvent? next;
                try
                {
                    next = await ReadEventAsync(connection, linked.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (_disposed && !ct.IsCancellationRequested)
                {
                    yield break;
                }
                if (next is null)
                {
                    // The stream dropped: the daemon went away or restarted. Get a connection back, then resume.
                    connection.Dispose();
                    connection = null;
                    failures++;
                    try
                    {
                        await TryReconnectAsync(epoch, linked.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (_disposed && !ct.IsCancellationRequested)
                    {
                        yield break;
                    }

                    continue;
                }

                failures = 0;
                if (CheckGap(next, out var gap))
                {
                    yield return gap;
                }

                yield return next;
            }
        }
        finally
        {
            connection?.Dispose();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await _lifetime.CancelAsync().ConfigureAwait(false);
        Task? reconnect;
        lock (_reconnectLock)
        {
            reconnect = _reconnect;
        }

        if (reconnect is not null)
        {
            try
            {
                await reconnect.ConfigureAwait(false);
            }
            catch (Exception e) when (e is DaemonException or OperationCanceledException)
            {
                // Nobody waits for it any more.
            }
        }

        DisposeIdle();
        // _lifetime is not disposed: it has no timer, and a reconnect may still read its token.
    }

    // ----- calls -----

    private byte[] BuildRequest(string method, object? parameters)
    {
        var id = Interlocked.Increment(ref _nextId);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("jsonrpc", "2.0");
            writer.WriteNumber("id", id);
            writer.WriteString("method", method);
            writer.WritePropertyName("params");
            if (parameters is null)
            {
                writer.WriteStartObject();
                writer.WriteEndObject();
            }
            else
            {
                JsonSerializer.Serialize(writer, parameters, parameters.GetType(), ParameterOptions);
            }

            writer.WriteEndObject();
        }

        stream.WriteByte((byte)'\n');
        if (stream.Length > _options.MaxRequestBytes)
        {
            throw new DaemonProtocolException($"The request for {method} is {stream.Length} bytes, and the daemon accepts {_options.MaxRequestBytes}.");
        }

        return stream.ToArray();
    }

    private async Task<JsonElement> CallOnceAsync(byte[] request, string method, TimeSpan timeout, int epoch, CancellationToken ct)
    {
        await _slots.WaitAsync(ct).ConfigureAwait(false);
        LineConnection? connection = null;
        var reuse = false;
        try
        {
            connection = TakeIdle(epoch) ?? await LineConnection.ConnectAsync(_socketPath, epoch, ct).ConfigureAwait(false);
            var result = await ExchangeAsync(connection, request, method, timeout, ct).ConfigureAwait(false);
            reuse = true;
            return result;
        }
        catch (DaemonRpcException)
        {
            // The daemon answered, so the stream is still in step.
            reuse = true;
            throw;
        }
        finally
        {
            if (connection is not null)
            {
                if (reuse)
                {
                    ReturnIdle(connection);
                }
                else
                {
                    connection.Dispose();
                }
            }

            _slots.Release();
        }
    }

    private async Task<JsonElement> ExchangeAsync(LineConnection connection, byte[] request, string method, TimeSpan timeout, CancellationToken ct)
    {
        using var limited = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limited.CancelAfter(timeout);
        try
        {
            await connection.WriteAsync(request, limited.Token).ConfigureAwait(false);
            while (true)
            {
                var line = await connection.ReadLineAsync(_options.MaxLineBytes, limited.Token).ConfigureAwait(false);
                if (line.Length == 0)
                {
                    continue;
                }

                return ParseReply(line);
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && limited.IsCancellationRequested)
        {
            throw new TimeoutException($"The daemon did not answer {method} within {timeout.TotalSeconds:0.#} seconds.");
        }
    }

    private static JsonElement ParseReply(byte[] line)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line);
        }
        catch (JsonException e)
        {
            throw new DaemonProtocolException("The daemon sent a line that is not JSON.", e);
        }

        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                throw new DaemonProtocolException("The daemon sent a reply that is not an object.");
            }

            if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
            {
                var message = error.TryGetProperty("message", out var text) && text.ValueKind == JsonValueKind.String
                    ? text.GetString() ?? "The daemon refused the request."
                    : "The daemon refused the request.";
                var code = error.TryGetProperty("code", out var number) && number.TryGetInt32(out var parsed) ? parsed : 0;
                JsonElement? data = null;
                string? kind = null;
                if (error.TryGetProperty("data", out var extra))
                {
                    data = extra.Clone();
                    if (extra.ValueKind == JsonValueKind.Object && extra.TryGetProperty("kind", out var name) && name.ValueKind == JsonValueKind.String)
                    {
                        kind = name.GetString();
                    }
                }

                throw new DaemonRpcException(message, code, kind, data);
            }

            if (root.TryGetProperty("result", out var result))
            {
                return result.Clone();
            }

            throw new DaemonProtocolException("The daemon sent an empty reply.");
        }
    }

    private LineConnection? TakeIdle(int epoch)
    {
        lock (_idleLock)
        {
            while (_idle.Count > 0)
            {
                var candidate = _idle.Pop();
                if (candidate.Epoch == epoch)
                {
                    return candidate;
                }

                candidate.Dispose();
            }
        }

        return null;
    }

    private void ReturnIdle(LineConnection connection)
    {
        lock (_idleLock)
        {
            if (connection.Epoch == Volatile.Read(ref _epoch) && !_disposed && _idle.Count < _options.MaxIdleConnections)
            {
                _idle.Push(connection);
                return;
            }
        }

        connection.Dispose();
    }

    private void DisposeIdle()
    {
        lock (_idleLock)
        {
            while (_idle.Count > 0)
            {
                _idle.Pop().Dispose();
            }
        }
    }

    private static bool IsTransportFailure(Exception e) => e is IOException or System.Net.Sockets.SocketException or ObjectDisposedException;

    /// <summary>Waits while a start or reconnect is under way, and returns the connection generation to use.</summary>
    private async Task<int> WaitUntilUsableAsync(CancellationToken ct)
    {
        while (true)
        {
            Task changed;
            lock (_stateLock)
            {
                switch (_state)
                {
                    case ConnectionState.Connected:
                        return Volatile.Read(ref _epoch);
                    case ConnectionState.Failed:
                        throw new DaemonUnavailableException(_reason ?? FailureReason.NotResponding, _failureMessage ?? "The daemon is not available.");
                    default:
                        if (!_started)
                        {
                            throw new InvalidOperationException("Call StartAsync before using the client.");
                        }

                        changed = _changed.Task;
                        break;
                }
            }

            await changed.WaitAsync(ct).ConfigureAwait(false);
        }
    }

    private async Task WaitForConnectedAsync(CancellationToken ct)
    {
        while (true)
        {
            Task changed;
            lock (_stateLock)
            {
                if (_state == ConnectionState.Connected)
                {
                    return;
                }

                changed = _changed.Task;
            }

            using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _lifetime.Token);
            try
            {
                await changed.WaitAsync(linked.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // The client was disposed.
                return;
            }
        }
    }

    // ----- connecting -----

    private void SetState(ConnectionState state, string? reason, string? message = null)
    {
        lock (_stateLock)
        {
            if (_state == state && _reason == reason)
            {
                return;
            }

            _state = state;
            _reason = reason;
            _failureMessage = state == ConnectionState.Failed ? message : null;
            var old = _changed;
            _changed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            old.TrySetResult();
        }

        StateChanged?.Invoke(state, reason);
    }

    /// <summary>
    /// Opens a connection, starting the daemon when the socket does not answer, and checks the
    /// daemon's version. Retries with backoff until <paramref name="budget"/> runs out. Must hold the gate.
    /// </summary>
    private async Task ConnectAsync(TimeSpan budget, CancellationToken ct, bool replaceOlder = false)
    {
        _dataFolder = _options.DataFolder ?? FykeHome.Discover();
        _socketPath = _options.SocketPath ?? FykeHome.SocketPath(_dataFolder);

        var clock = Stopwatch.StartNew();
        var delay = _options.RetryDelay;
        TimeSpan? lastStart = null;
        var detail = string.Empty;
        DaemonTooOldException? replacement = null;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var epoch = Volatile.Read(ref _epoch) + 1;
            LineConnection? connection = null;
            try
            {
                connection = await LineConnection.ConnectAsync(_socketPath, epoch, ct).ConfigureAwait(false);
                var handshake = await HandshakeAsync(connection, ct).ConfigureAwait(false);
                Accept(handshake);
                DisposeIdle();
                Volatile.Write(ref _epoch, epoch);
                ReturnIdle(connection);
                SetState(ConnectionState.Connected, null);
                return;
            }
            catch (DaemonTooOldException e) when (replaceOlder && lastStart is null)
            {
                var refused = false;
                using (connection)
                {
                    var remaining = budget - clock.Elapsed;
                    if (replacement is null && remaining > TimeSpan.Zero)
                    {
                        replacement = e;
                        try
                        {
                            var request = BuildRequest("daemon.stop", null);
                            await ExchangeAsync(connection!, request, "daemon.stop", remaining, ct).ConfigureAwait(false);
                        }
                        catch (Exception failure) when (failure is DaemonRpcException or DaemonProtocolException or TimeoutException)
                        {
                            refused = true;
                        }
                        catch (Exception failure) when (IsTransportFailure(failure))
                        {
                            // Shutdown can close the socket before the reply arrives.
                        }
                    }
                }

                if (refused || clock.Elapsed + delay >= budget)
                {
                    throw;
                }

                await Task.Delay(delay, ct).ConfigureAwait(false);
                delay = TimeSpan.FromTicks(Math.Min(delay.Ticks * 2, _options.MaxRetryDelay.Ticks));
                continue;
            }
            catch (Exception e) when (IsTransportFailure(e) || e is TimeoutException or DaemonProtocolException)
            {
                connection?.Dispose();
                detail = e.Message;
            }
            catch
            {
                connection?.Dispose();
                throw;
            }

            if (lastStart is null || clock.Elapsed - lastStart >= _options.StartRetryInterval)
            {
                lastStart = clock.Elapsed;
                try
                {
                    await _starter.StartAsync(_dataFolder, ct).ConfigureAwait(false);
                }
                catch (Exception e) when (e is not OperationCanceledException and not DaemonUnavailableException)
                {
                    throw new DaemonUnavailableException(FailureReason.NotResponding, $"Could not start the daemon: {e.Message}", e);
                }
            }

            if (clock.Elapsed + delay >= budget)
            {
                if (replacement is not null)
                {
                    throw replacement;
                }

                throw new DaemonUnavailableException(FailureReason.NotResponding, $"The daemon did not answer within {budget.TotalSeconds:0.#} seconds. {detail}".TrimEnd());
            }

            await Task.Delay(delay, ct).ConfigureAwait(false);
            delay = TimeSpan.FromTicks(Math.Min(delay.Ticks * 2, _options.MaxRetryDelay.Ticks));
        }
    }

    private readonly record struct Handshake(long ApiVersion, long LastEventSeq);

    // `api_version` comes with `stats.get` (docs/api.md: "Counts, queue depth, uptime and api_version"),
    // not `ops.list`, whose reply is only the list of operations.
    private async Task<Handshake> HandshakeAsync(LineConnection connection, CancellationToken ct)
    {
        JsonElement stats;
        try
        {
            stats = await ExchangeAsync(connection, BuildRequest("stats.get", null), "stats.get", _options.CallTimeout, ct).ConfigureAwait(false);
        }
        catch (DaemonRpcException e) when (e.IsUnknownMethod)
        {
            throw new DaemonTooOldException(0, _options.RequiredApiVersion);
        }
        catch (DaemonRpcException e)
        {
            throw new DaemonUnavailableException(FailureReason.NotResponding, $"The daemon refused the version check: {e.Message}", e);
        }

        long version = 1; // A daemon that predates api_version does not send one.
        long last = 0;
        if (stats.ValueKind == JsonValueKind.Object)
        {
            if (stats.TryGetProperty("api_version", out var v) && v.TryGetInt64(out var parsedVersion))
            {
                version = parsedVersion;
            }

            if (stats.TryGetProperty("last_event_seq", out var s) && s.TryGetInt64(out var parsedSeq))
            {
                last = parsedSeq;
            }
        }

        if (version < _options.RequiredApiVersion)
        {
            throw new DaemonTooOldException(version, _options.RequiredApiVersion);
        }

        return new Handshake(version, last);
    }

    private void Accept(Handshake handshake)
    {
        DaemonApiVersion = handshake.ApiVersion;
        lock (_seqLock)
        {
            if (_lastSeq is null)
            {
                // Changes from here on are new to this client; what came before is in the lists it loads.
                _lastSeq = handshake.LastEventSeq;
            }
            else if (handshake.LastEventSeq < _lastSeq)
            {
                // The daemon's event log is behind what this client saw: it started over.
                _lastSeq = handshake.LastEventSeq;
                _gapPending = true;
            }
        }
    }

    /// <summary>Gets the connection back after a failure seen in <paramref name="epoch"/>. One attempt serves every caller.</summary>
    private async Task ReconnectAsync(int epoch, CancellationToken ct)
    {
        Task task;
        lock (_reconnectLock)
        {
            if (Volatile.Read(ref _epoch) != epoch)
            {
                return; // Someone already reconnected.
            }

            if (State == ConnectionState.Failed)
            {
                throw new DaemonUnavailableException(_reason ?? FailureReason.NotResponding, _failureMessage ?? "The daemon is not available.");
            }

            _reconnect ??= Task.Run(() => RunReconnectAsync(epoch), CancellationToken.None);
            task = _reconnect;
        }

        await task.WaitAsync(ct).ConfigureAwait(false);
    }

    private async Task RunReconnectAsync(int epoch)
    {
        try
        {
            await _gate.WaitAsync(_lifetime.Token).ConfigureAwait(false);
            try
            {
                if (Volatile.Read(ref _epoch) != epoch || State == ConnectionState.Failed)
                {
                    return;
                }

                SetState(ConnectionState.Reconnecting, null);
                DisposeIdle();
                await ConnectAsync(_options.ReconnectTimeout, _lifetime.Token).ConfigureAwait(false);
            }
            catch (DaemonUnavailableException e)
            {
                SetState(ConnectionState.Failed, e.Reason, e.Message);
                throw;
            }
            catch (OperationCanceledException)
            {
                SetState(ConnectionState.Failed, FailureReason.Cancelled, "The client was closed.");
                throw;
            }
            finally
            {
                _gate.Release();
            }
        }
        finally
        {
            lock (_reconnectLock)
            {
                _reconnect = null;
            }
        }
    }

    private async Task TryReconnectAsync(int epoch, CancellationToken ct)
    {
        try
        {
            await ReconnectAsync(epoch, ct).ConfigureAwait(false);
        }
        catch (DaemonUnavailableException)
        {
            // The state is Failed. The event stream waits there until StartAsync succeeds.
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // The client was disposed.
        }
    }

    // ----- events -----

    private async Task<(LineConnection? Connection, int Epoch)> OpenSubscriptionAsync(int failures, CancellationToken ct)
    {
        if (failures > 1)
        {
            var wait = TimeSpan.FromTicks(Math.Min(_options.RetryDelay.Ticks << Math.Min(failures - 2, 20), _options.MaxRetryDelay.Ticks));
            await DelayAsync(wait, ct).ConfigureAwait(false);
        }

        await WaitForConnectedAsync(ct).ConfigureAwait(false);
        if (_disposed)
        {
            return (null, 0);
        }

        var epoch = Volatile.Read(ref _epoch);
        LineConnection? connection = null;
        try
        {
            connection = await LineConnection.ConnectAsync(_socketPath, epoch, ct).ConfigureAwait(false);
            long since;
            lock (_seqLock)
            {
                since = _lastSeq ?? 0;
            }

            var request = BuildRequest("events.subscribe", new { SinceSeq = since });
            _ = await ExchangeAsync(connection, request, "events.subscribe", _options.CallTimeout, ct).ConfigureAwait(false);
            return (connection, epoch);
        }
        catch (Exception e) when (IsTransportFailure(e) || e is TimeoutException or DaemonProtocolException)
        {
            connection?.Dispose();
            await TryReconnectAsync(epoch, ct).ConfigureAwait(false);
            return (null, epoch);
        }
        catch
        {
            connection?.Dispose();
            throw;
        }
    }

    private async Task DelayAsync(TimeSpan wait, CancellationToken ct)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _lifetime.Token);
        try
        {
            await Task.Delay(wait, linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // The client was disposed.
        }
    }

    /// <summary>The next event, or null when the stream dropped or sent something that is not the protocol.</summary>
    private async Task<DaemonEvent?> ReadEventAsync(LineConnection connection, CancellationToken ct)
    {
        try
        {
            while (true)
            {
                // The stream is quiet when nothing happens, so there is no read timeout.
                var line = await connection.ReadLineAsync(_options.MaxLineBytes, ct).ConfigureAwait(false);
                if (line.Length == 0)
                {
                    continue;
                }

                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (root.ValueKind == JsonValueKind.Object
                    && root.TryGetProperty("method", out var method) && method.ValueKind == JsonValueKind.String && method.GetString() == "event"
                    && root.TryGetProperty("params", out var parameters) && parameters.ValueKind == JsonValueKind.Object
                    && parameters.TryGetProperty("seq", out var seq) && seq.ValueKind == JsonValueKind.Number
                    && seq.TryGetInt64(out var number)
                    && parameters.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String)
                {
                    long? subject = parameters.TryGetProperty("subject_id", out var id) && id.ValueKind == JsonValueKind.Number && id.TryGetInt64(out var parsed) ? parsed : null;
                    return new DaemonEvent(number, type.GetString() ?? string.Empty, subject);
                }
            }
        }
        catch (Exception e) when (IsTransportFailure(e) || e is DaemonProtocolException or JsonException)
        {
            return null;
        }
    }

    private bool TakeGap(out long seq)
    {
        lock (_seqLock)
        {
            seq = _lastSeq ?? 0;
            var pending = _gapPending;
            _gapPending = false;
            return pending;
        }
    }

    /// <summary>
    /// Events carry consecutive numbers (a SQLite AUTOINCREMENT key, pruned only from the old end),
    /// so a jump means the daemon dropped some, and a number that does not advance means its
    /// log started over. The daemon sends no gap marker of its own.
    /// </summary>
    private bool CheckGap(DaemonEvent next, out DaemonEvent gap)
    {
        lock (_seqLock)
        {
            var last = _lastSeq ?? next.Seq - 1;
            _lastSeq = next.Seq;
            if (next.Seq != last + 1)
            {
                gap = new DaemonEvent(next.Seq, DaemonEvent.GapType, null);
                return true;
            }
        }

        gap = next;
        return false;
    }
}
