using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>
/// Decides when a routine's <c>notify</c> action reaches the system, as macOS does: the
/// daemon writes a <c>routine.notify</c> event and the running app turns it into one
/// notification titled "Fyke". A burst of them (several routines at one time, or events
/// replayed after a reconnect) becomes a single notification.
/// </summary>
public sealed class RoutineNotices
{
    public const string EventType = "routine.notify";
    public const string Title = "Fyke";
    public const string Body = "A routine has something for you";

    /// <summary>How long one notification stands for any that follow it.</summary>
    public static readonly TimeSpan Quiet = TimeSpan.FromSeconds(10);

    private DateTimeOffset? last;

    /// <summary>True when this event should post a notification at <paramref name="now"/>.</summary>
    public bool ShouldPost(DaemonEvent change, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(change);
        if (change.Type != EventType || (last is { } previous && now - previous < Quiet && now >= previous))
        {
            return false;
        }

        last = now;
        return true;
    }
}
