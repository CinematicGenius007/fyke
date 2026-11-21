namespace Fyke.Client;

/// <summary>
/// Finds the data folder the way <c>homeDirectory</c> in src/main.zig does, so that the app and
/// <c>fyke.exe</c> always mean the same folder and the same socket.
/// </summary>
public static class FykeHome
{
    /// <summary>The daemon's socket, inside the data folder (<c>socket_name</c> in src/daemon.zig).</summary>
    public const string SocketFileName = "fyked.sock";

    /// <summary>The file in the default Windows folder that names the folder <c>fyke data move</c> chose.</summary>
    public const string LocationFileName = "location";

    /// <summary>The data folder for this machine and user.</summary>
    public static string Discover() => Resolve(Environment.GetEnvironmentVariable, OperatingSystem.IsWindows());

    /// <summary>
    /// <c>FYKE_HOME</c> wins. On Windows the default is <c>%LOCALAPPDATA%\Fyke</c>, unless a
    /// <c>location</c> file there names another folder. Elsewhere it is <c>~/.fyke</c>. The
    /// client never moves data left in an older folder: the <c>fyke</c> program does that.
    /// </summary>
    /// <exception cref="DaemonUnavailableException">There is no way to tell where the data is.</exception>
    public static string Resolve(Func<string, string?> environment, bool windows)
    {
        ArgumentNullException.ThrowIfNull(environment);

        var explicitPath = environment("FYKE_HOME");
        if (!string.IsNullOrEmpty(explicitPath))
        {
            return explicitPath;
        }

        if (windows)
        {
            var local = environment("LOCALAPPDATA");
            if (string.IsNullOrEmpty(local))
            {
                throw new DaemonUnavailableException(FailureReason.NotResponding, "Cannot find the local application data folder.");
            }

            var anchor = Path.Combine(local, "Fyke");
            return ReadLocation(anchor) ?? anchor;
        }

        var home = environment("HOME");
        if (string.IsNullOrEmpty(home))
        {
            home = environment("USERPROFILE");
        }

        if (string.IsNullOrEmpty(home))
        {
            throw new DaemonUnavailableException(FailureReason.NotResponding, "Cannot find the home folder.");
        }

        return Path.Combine(home, ".fyke");
    }

    /// <summary>
    /// The longest socket path, in UTF-8 bytes, that fits a socket address: 108 bytes with the
    /// terminating zero. <c>fyke data move</c> refuses a folder past it (src/data_move.zig).
    /// </summary>
    public const int MaxSocketPathBytes = 107;

    /// <summary>The socket for a data folder.</summary>
    public static string SocketPath(string dataFolder) => Path.Combine(dataFolder, SocketFileName);

    /// <summary>Fails at once for a socket no client can connect to, rather than waiting for a daemon.</summary>
    /// <exception cref="DaemonUnavailableException">The path is longer than <see cref="MaxSocketPathBytes"/>.</exception>
    public static void CheckSocketPath(string socketPath)
    {
        ArgumentNullException.ThrowIfNull(socketPath);
        var length = System.Text.Encoding.UTF8.GetByteCount(socketPath);
        if (length > MaxSocketPathBytes)
        {
            throw new DaemonUnavailableException(FailureReason.PathTooLong,
                $"The socket path {socketPath} is {length} bytes, and a socket path holds at most {MaxSocketPathBytes}.");
        }
    }

    // A pointer that exists but cannot be read must not fall back to the default folder: a
    // daemon started there would open a second, empty database.
    private static string? ReadLocation(string anchor)
    {
        var path = Path.Combine(anchor, LocationFileName);
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new DaemonUnavailableException(FailureReason.NotResponding, $"Cannot read {path}: {e.Message}", e);
        }

        var trimmed = text.Trim(' ', '\t', '\r', '\n');
        return trimmed.Length == 0 ? null : trimmed;
    }
}
