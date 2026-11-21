namespace Fyke.Client;

/// <summary>
/// Why the client is in the Failed state. These are the strings <c>StateChanged</c> carries,
/// so a view model can pick its sentence without parsing prose.
/// </summary>
public static class FailureReason
{
    /// <summary>The daemon did not answer in time, and starting one did not help.</summary>
    public const string NotResponding = "not-responding";

    /// <summary>The <c>fyke</c> program that starts the daemon cannot be found.</summary>
    public const string ProgramMissing = "program-missing";

    /// <summary>The daemon runs, but it is older than this app needs.</summary>
    public const string DaemonTooOld = "daemon-too-old";

    /// <summary>The data folder's path is too long for the daemon's socket.</summary>
    public const string PathTooLong = "path-too-long";

    /// <summary>The person or the app stopped the attempt.</summary>
    public const string Cancelled = "cancelled";
}
