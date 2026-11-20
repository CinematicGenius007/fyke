using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class RoutineNoticesTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 20, 7, 30, 0, TimeSpan.Zero);

    [Fact]
    public void OnlyARoutinesNotifyEventPosts()
    {
        var notices = new RoutineNotices();

        Assert.False(notices.ShouldPost(new DaemonEvent(1, "routine.changed", 4), Start));
        Assert.False(notices.ShouldPost(new DaemonEvent(2, DaemonEvent.GapType, null), Start));
        Assert.True(notices.ShouldPost(new DaemonEvent(3, "routine.notify", 4), Start));
        Assert.Equal("Fyke", RoutineNotices.Title);
        Assert.Equal("A routine has something for you", RoutineNotices.Body);
    }

    [Fact]
    public void ABurstPostsOnce()
    {
        var notices = new RoutineNotices();

        Assert.True(notices.ShouldPost(new DaemonEvent(1, "routine.notify", 4), Start));
        Assert.False(notices.ShouldPost(new DaemonEvent(2, "routine.notify", 5), Start.AddSeconds(2)));
        Assert.True(notices.ShouldPost(new DaemonEvent(3, "routine.notify", 4), Start.Add(RoutineNotices.Quiet)));
        // A clock set back does not silence the next one.
        Assert.True(notices.ShouldPost(new DaemonEvent(4, "routine.notify", 4), Start.AddMinutes(-5)));
    }
}
