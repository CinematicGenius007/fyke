using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>The plain sentences for each connection state, in one place so they can be tested and translated.</summary>
public static class ConnectionMessages
{
    public const string Connecting = "Starting Fyke…";
    public const string Reconnecting = "Reconnecting…";
    public const string NeedsUpdate = "Fyke needs to be updated";
    public const string ProgramMissing = "Fyke can't find its background program";
    public const string Cancelled = "Stopped waiting for Fyke";
    public const string PathTooLong = "Fyke's data folder path is too long";
    public const string Unreachable = "Fyke can't reach its background service";

    /// <summary>What the inline state says. Empty when connected: nothing needs saying.</summary>
    public static string For(ConnectionState state, string? reason) => state switch
    {
        ConnectionState.Connecting => Connecting,
        ConnectionState.Connected => string.Empty,
        ConnectionState.Reconnecting => Reconnecting,
        _ => reason switch
        {
            FailureReason.DaemonTooOld => NeedsUpdate,
            FailureReason.ProgramMissing => ProgramMissing,
            FailureReason.Cancelled => Cancelled,
            FailureReason.PathTooLong => PathTooLong,
            _ => Unreachable,
        },
    };

    /// <summary>A second sentence that says what to do. Only a failure has one.</summary>
    public static string DetailFor(ConnectionState state, string? reason)
    {
        if (state != ConnectionState.Failed)
        {
            return string.Empty;
        }

        return reason switch
        {
            FailureReason.DaemonTooOld => "The background service is older than this app. Update Fyke, then try again.",
            FailureReason.ProgramMissing => "Reinstall Fyke, then try again.",
            FailureReason.Cancelled => "Try again when you are ready.",
            FailureReason.PathTooLong => $"Windows limits the background service's address to {FykeHome.MaxSocketPathBytes} characters. "
                + "Move the data folder somewhere shorter with fyke data move, or set FYKE_HOME to a shorter path.",
            _ => "Nothing was lost. Try again in a moment.",
        };
    }
}
