using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace Fyke.Client.Tests;

/// <summary>A reply the fake sends as raw text, for lines the real daemon would never write.</summary>
internal sealed record RawLine(string Text);

/// <summary>An error reply: the daemon's code, its <c>message</c> and <c>data</c>.</summary>
internal sealed record FakeError(int Code, string Message, object? Data = null);

/// <summary>
/// A daemon on a temporary Unix socket that speaks the protocol of docs/api.md: newline-delimited
/// JSON-RPC, <c>stats.get</c> with <c>api_version</c>, and <c>events.subscribe</c> as a stream.
/// <see cref="Kill"/> and <see cref="Restart"/> stand for the process dying and coming back.
/// </summary>
internal sealed class FakeDaemon : IAsyncDisposable
{
    private readonly object _lock = new();
    private readonly List<(long Seq, string Type, long? Subject)> _events = [];
    private readonly Dictionary<string, Func<JsonElement, Task<object?>>> _handlers = new(StringComparer.Ordinal);
    private readonly List<Socket> _connections = [];
    private Socket? _listener;
    private CancellationTokenSource _stop = new();

    public FakeDaemon(string? path = null)
    {
        Folder = Path.Combine(Path.GetTempPath(), "fk" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Folder);
        SocketPath = path ?? Path.Combine(Folder, "fyked.sock");
    }

    public string Folder { get; }

    public string SocketPath { get; }

    public long ApiVersion { get; set; } = DaemonClient.RequiredApiVersion;

    /// <summary>Null leaves <c>api_version</c> out, like a daemon that predates it.</summary>
    public bool SendApiVersion { get; set; } = true;

    public long LastEventSeq { get; set; }

    public int Accepted { get; private set; }

    public List<long> Subscriptions { get; } = [];

    /// <summary>Whether each subscription said the client posts notifications.</summary>
    public List<bool> SubscriptionsThatNotify { get; } = [];

    public bool Running => _listener is not null;

    public FakeDaemon On(string method, Func<JsonElement, object?> handler)
    {
        _handlers[method] = parameters => Task.FromResult(handler(parameters));
        return this;
    }

    public FakeDaemon On(string method, Func<JsonElement, Task<object?>> handler)
    {
        _handlers[method] = handler;
        return this;
    }

    public void Start()
    {
        lock (_lock)
        {
            if (_listener is not null)
            {
                return;
            }

            if (File.Exists(SocketPath))
            {
                File.Delete(SocketPath);
            }

            _stop = new CancellationTokenSource();
            var listener = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            listener.Bind(new UnixDomainSocketEndPoint(SocketPath));
            listener.Listen(32);
            _listener = listener;
            _ = Task.Run(() => AcceptLoopAsync(listener, _stop.Token), CancellationToken.None);
        }
    }

    public void Restart() => Start();

    /// <summary>Stops listening and drops every connection, as a crash does.</summary>
    public void Kill()
    {
        Socket[] open;
        lock (_lock)
        {
            _stop.Cancel();
            _listener?.Dispose();
            _listener = null;
            open = [.. _connections];
            _connections.Clear();
        }

        foreach (var socket in open)
        {
            socket.Dispose();
        }

        if (File.Exists(SocketPath))
        {
            File.Delete(SocketPath);
        }
    }

    public void Publish(long seq, string type, long? subject = null)
    {
        lock (_lock)
        {
            _events.Add((seq, type, subject));
            LastEventSeq = Math.Max(LastEventSeq, seq);
        }
    }

    /// <summary>Forgets events, as the daemon's weekly pruning does.</summary>
    public void Prune(Func<long, bool> remove)
    {
        lock (_lock)
        {
            _events.RemoveAll(e => remove(e.Seq));
        }
    }

    public void ResetEvents()
    {
        lock (_lock)
        {
            _events.Clear();
            LastEventSeq = 0;
        }
    }

    public async ValueTask DisposeAsync()
    {
        Kill();
        await Task.Yield();
        try
        {
            Directory.Delete(Folder, recursive: true);
        }
        catch (IOException)
        {
            // A temporary folder that stays is harmless.
        }
    }

    private async Task AcceptLoopAsync(Socket listener, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            Socket client;
            try
            {
                client = await listener.AcceptAsync(stop);
            }
            catch (Exception e) when (e is SocketException or ObjectDisposedException or OperationCanceledException)
            {
                return;
            }

            lock (_lock)
            {
                _connections.Add(client);
                Accepted++;
            }

            _ = Task.Run(() => ServeAsync(client, stop), CancellationToken.None);
        }
    }

    private async Task ServeAsync(Socket client, CancellationToken stop)
    {
        var buffer = new byte[64 * 1024];
        var pending = new List<byte>();
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var count = await client.ReceiveAsync(buffer, SocketFlags.None, stop);
                if (count == 0)
                {
                    return;
                }

                pending.AddRange(buffer.AsSpan(0, count).ToArray());
                int newline;
                while ((newline = pending.IndexOf((byte)'\n')) >= 0)
                {
                    var line = pending.GetRange(0, newline).ToArray();
                    pending.RemoveRange(0, newline + 1);
                    if (line.Length == 0)
                    {
                        continue;
                    }

                    if (await HandleAsync(client, line, stop))
                    {
                        return;
                    }
                }
            }
        }
        catch (Exception e) when (e is SocketException or ObjectDisposedException or OperationCanceledException)
        {
            // The client left, or the fake was killed.
        }
        finally
        {
            client.Dispose();
        }
    }

    /// <summary>Handles one request. True when the connection became a stream that has ended.</summary>
    private async Task<bool> HandleAsync(Socket client, byte[] line, CancellationToken stop)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        var id = root.GetProperty("id").Clone();
        var method = root.GetProperty("method").GetString()!;
        var parameters = root.GetProperty("params").Clone();

        if (method == "events.subscribe")
        {
            var since = parameters.TryGetProperty("since_seq", out var s) ? s.GetInt64() : 0;
            lock (_lock)
            {
                Subscriptions.Add(since);
                SubscriptionsThatNotify.Add(parameters.TryGetProperty("notifies", out var n) && n.GetBoolean());
            }

            await SendAsync(client, Reply(id, new { subscribed = true }), stop);
            await StreamAsync(client, since, stop);
            return true;
        }

        if (method == "stats.get" && !_handlers.ContainsKey(method))
        {
            var stats = new Dictionary<string, object?> { ["feeds"] = 0, ["last_event_seq"] = LastEventSeq };
            if (SendApiVersion)
            {
                stats["api_version"] = ApiVersion;
            }

            await SendAsync(client, Reply(id, stats), stop);
            return false;
        }

        if (!_handlers.TryGetValue(method, out var handler))
        {
            await SendAsync(client, Error(id, new FakeError(-32601, "UnknownMethod", new { kind = "UnknownMethod" })), stop);
            return false;
        }

        var result = await handler(parameters);
        switch (result)
        {
            case RawLine raw:
                await SendAsync(client, raw.Text + "\n", stop);
                break;
            case FakeError error:
                await SendAsync(client, Error(id, error), stop);
                break;
            default:
                await SendAsync(client, Reply(id, result), stop);
                break;
        }

        return false;
    }

    private async Task StreamAsync(Socket client, long since, CancellationToken stop)
    {
        var sent = since;
        while (!stop.IsCancellationRequested)
        {
            (long Seq, string Type, long? Subject)[] due;
            lock (_lock)
            {
                due = [.. _events.Where(e => e.Seq > sent).OrderBy(e => e.Seq)];
            }

            foreach (var e in due)
            {
                var message = JsonSerializer.Serialize(new
                {
                    jsonrpc = "2.0",
                    method = "event",
                    @params = new { seq = e.Seq, type = e.Type, subject_id = e.Subject },
                });
                await SendAsync(client, message + "\n", stop);
                sent = e.Seq;
            }

            await Task.Delay(5, stop);
        }
    }

    private static string Reply(JsonElement id, object? result) =>
        JsonSerializer.Serialize(new { jsonrpc = "2.0", id, result }) + "\n";

    private static string Error(JsonElement id, FakeError error) =>
        JsonSerializer.Serialize(new { jsonrpc = "2.0", id, error = new { code = error.Code, message = error.Message, data = error.Data } }) + "\n";

    private static async Task SendAsync(Socket client, string text, CancellationToken stop)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var sent = 0;
        while (sent < bytes.Length)
        {
            sent += await client.SendAsync(bytes.AsMemory(sent), SocketFlags.None, stop);
        }
    }
}
