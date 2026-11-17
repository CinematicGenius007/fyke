using System.Net.Sockets;

namespace Fyke.Client;

/// <summary>One Unix-socket connection that reads and writes newline-delimited lines. One user at a time.</summary>
internal sealed class LineConnection : IDisposable
{
    private readonly Socket _socket;
    private readonly byte[] _buffer = new byte[64 * 1024];
    private readonly MemoryStream _pending = new();
    private int _start;
    private int _end;

    private LineConnection(Socket socket, int epoch)
    {
        _socket = socket;
        Epoch = epoch;
    }

    /// <summary>The connection generation it was opened in. A connection of an older one is not reused.</summary>
    public int Epoch { get; }

    public static async Task<LineConnection> ConnectAsync(string path, int epoch, CancellationToken ct)
    {
        var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
        try
        {
            await socket.ConnectAsync(new UnixDomainSocketEndPoint(path), ct).ConfigureAwait(false);
            return new LineConnection(socket, epoch);
        }
        catch (ArgumentOutOfRangeException e)
        {
            // The path does not fit in a socket address.
            socket.Dispose();
            throw new IOException($"The socket path is too long: {path}", e);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    public async Task WriteAsync(ReadOnlyMemory<byte> data, CancellationToken ct)
    {
        while (!data.IsEmpty)
        {
            var sent = await _socket.SendAsync(data, SocketFlags.None, ct).ConfigureAwait(false);
            if (sent <= 0)
            {
                throw new IOException("The daemon closed the connection.");
            }

            data = data[sent..];
        }
    }

    /// <summary>The next line without its newline.</summary>
    /// <exception cref="DaemonProtocolException">The line is longer than <paramref name="maxBytes"/>.</exception>
    /// <exception cref="IOException">The daemon closed the connection.</exception>
    public async Task<byte[]> ReadLineAsync(int maxBytes, CancellationToken ct)
    {
        _pending.SetLength(0);
        while (true)
        {
            if (_start < _end)
            {
                var available = _buffer.AsSpan(_start, _end - _start);
                var newline = available.IndexOf((byte)'\n');
                var take = newline < 0 ? available.Length : newline;
                if (_pending.Length + take > maxBytes)
                {
                    throw new DaemonProtocolException($"The daemon sent a line longer than {maxBytes} bytes.");
                }

                _pending.Write(available[..take]);
                if (newline >= 0)
                {
                    _start += newline + 1;
                    if (_start == _end)
                    {
                        _start = 0;
                        _end = 0;
                    }

                    return _pending.ToArray();
                }

                _start = 0;
                _end = 0;
            }

            var count = await _socket.ReceiveAsync(_buffer.AsMemory(), SocketFlags.None, ct).ConfigureAwait(false);
            if (count == 0)
            {
                throw new IOException("The daemon closed the connection.");
            }

            _start = 0;
            _end = count;
        }
    }

    public void Dispose()
    {
        _socket.Dispose();
        _pending.Dispose();
    }
}
