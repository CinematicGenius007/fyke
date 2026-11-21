using System.Text.Json;

namespace Fyke.Client;

/// <summary>Anything the client reports about the daemon.</summary>
public class DaemonException : Exception
{
    public DaemonException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}

/// <summary>The daemon is not usable: it does not answer, cannot be started, or is too old.</summary>
public class DaemonUnavailableException : DaemonException
{
    public DaemonUnavailableException(string reason, string message, Exception? inner = null) : base(message, inner)
    {
        Reason = reason;
    }

    /// <summary>A <see cref="FailureReason"/> code.</summary>
    public string Reason { get; }
}

/// <summary>The connection was lost before the client could confirm the request's outcome.</summary>
public sealed class DaemonOutcomeUnknownException : DaemonException
{
    public DaemonOutcomeUnknownException(string method, Exception inner)
        : base($"The connection was lost during {method}. Refresh to check whether it completed.", inner)
    {
    }
}

/// <summary>The daemon speaks an older <c>api_version</c> than the app needs.</summary>
public sealed class DaemonTooOldException : DaemonUnavailableException
{
    public DaemonTooOldException(long found, long required)
        : base(FailureReason.DaemonTooOld, $"The daemon speaks API version {found}, and this app needs {required}.")
    {
        Found = found;
        Required = required;
    }

    public long Found { get; }

    public long Required { get; }
}

/// <summary>The <c>fyke</c> program was not found, so no daemon could be started.</summary>
public sealed class DaemonProgramNotFoundException : DaemonUnavailableException
{
    public DaemonProgramNotFoundException(string message) : base(FailureReason.ProgramMissing, message)
    {
    }
}

/// <summary>The bytes on the socket are not the protocol: a line over the limit, or one that is not JSON.</summary>
public sealed class DaemonProtocolException : DaemonException
{
    public DaemonProtocolException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}

/// <summary>An error reply from the daemon, with its JSON-RPC code and <c>data.kind</c>.</summary>
public sealed class DaemonRpcException : DaemonException
{
    public DaemonRpcException(string message, int code, string? kind, JsonElement? data) : base(message)
    {
        Code = code;
        Kind = kind;
        ErrorData = data;
    }

    public int Code { get; }

    /// <summary>The daemon's name for the refusal, such as <c>NoSuchEntry</c> or <c>revision_conflict</c>.</summary>
    public string? Kind { get; }

    /// <summary>Anything else the refusal carries, such as the current definition after a revision conflict.</summary>
    public JsonElement? ErrorData { get; }

    /// <summary>Compares names whatever their spelling: <c>in_use</c>, <c>InUse</c> and <c>inUse</c> are one.</summary>
    public bool Is(string name)
    {
        var wanted = Flatten(name);
        return Flatten(Kind) == wanted || Flatten(Message) == wanted;
    }

    /// <summary>A daemon older than the operation answers that it does not know it.</summary>
    public bool IsUnknownMethod => Code == -32601 || Is("UnknownMethod");

    private static string Flatten(string? text) =>
        text is null ? string.Empty : new string(text.Where(char.IsLetter).Select(char.ToLowerInvariant).ToArray());
}
