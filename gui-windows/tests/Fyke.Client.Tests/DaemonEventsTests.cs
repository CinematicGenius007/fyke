namespace Fyke.Client.Tests;

public sealed class DaemonEventsTests
{
    [Fact]
    public async Task EventsArriveInOrderWithTheirSubjects()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        fake.Publish(1, "entry.new", 100);
        fake.Publish(2, "feed.error");
        fake.Publish(3, "entry.state", 101);
        var taken = await TestSupport.TakeAsync(events, 3);

        Assert.Equal(
            [new DaemonEvent(1, "entry.new", 100), new DaemonEvent(2, "feed.error", null), new DaemonEvent(3, "entry.state", 101)],
            taken);
        Assert.DoesNotContain(taken, e => e.IsGap);
        Assert.Equal([0L], fake.Subscriptions);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AnAppThatPostsNotificationsSaysSo(bool posts)
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            StartupTimeout = options.StartupTimeout,
            CallTimeout = options.CallTimeout,
            PostsNotifications = posts,
        });
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        fake.Publish(1, "routine.notify", 7);
        _ = await TestSupport.TakeAsync(events, 1);

        Assert.Equal([posts], fake.SubscriptionsThatNotify);
    }

    [Fact]
    public async Task OnlyChangesAfterTheHandshakeAreDelivered()
    {
        await using var fake = new FakeDaemon();
        fake.Publish(1, "entry.new", 1);
        fake.Publish(2, "entry.new", 2);
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        fake.Publish(3, "entry.new", 3);
        var taken = await TestSupport.TakeAsync(events, 1);

        Assert.Equal(3, taken[0].Seq);
        Assert.Equal([2L], fake.Subscriptions);
    }

    [Fact]
    public async Task EventsUseTheirOwnConnectionSoASlowCallDoesNotDelayThem()
    {
        await using var fake = new FakeDaemon();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.On("slow", async _ =>
        {
            await release.Task;
            return new { ok = true };
        });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        var slow = client.CallAsync("slow", null, CancellationToken.None);
        fake.Publish(1, "entry.new", 5);
        var taken = await TestSupport.TakeAsync(events, 1);

        Assert.Equal(5, taken[0].SubjectId);
        Assert.False(slow.IsCompleted);
        release.SetResult();
        await slow;
    }

    [Fact]
    public async Task AfterTheDaemonDiesEventsResumeFromTheLastSeqWithoutAGap()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);
        fake.Publish(1, "entry.new", 1);
        fake.Publish(2, "entry.new", 2);
        fake.Publish(3, "entry.new", 3);
        Assert.Equal(3, (await TestSupport.TakeAsync(events, 3)).Count);

        fake.Kill();
        fake.Publish(4, "entry.new", 4); // Written while the daemon is gone, as a restarted one reads it back.
        fake.Publish(5, "entry.new", 5);
        var resumed = await TestSupport.TakeAsync(events, 2);

        Assert.Equal([4L, 5L], resumed.Select(e => e.Seq));
        Assert.DoesNotContain(resumed, e => e.IsGap);
        Assert.Equal([0L, 3L], fake.Subscriptions);
        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.Contains((ConnectionState.Reconnecting, (string?)null), seen);
        Assert.Equal(1, starter.Calls);
    }

    [Fact]
    public async Task APauseKeepsTheClientFromStartingADaemonUntilItEnds()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(fake.Folder, client.DataFolder);

        var pause = await client.PauseAsync(CancellationToken.None);
        fake.Kill();
        var call = client.CallAsync("stats.get", null, CancellationToken.None);
        await Task.Delay(300);
        Assert.False(call.IsCompleted);
        Assert.Equal(0, starter.Calls);

        pause.Dispose();
        pause.Dispose(); // A second release is harmless.
        await call.WaitAsync(TestSupport.Patience);
        Assert.Equal(1, starter.Calls);
        Assert.Equal(ConnectionState.Connected, client.State);
    }

    [Fact]
    public async Task EventsThatWerePrunedWhileAwayProduceAGapBeforeTheNextEvent()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);
        fake.Publish(1, "entry.new", 1);
        fake.Publish(2, "entry.new", 2);
        await TestSupport.TakeAsync(events, 2);

        fake.Kill();
        fake.Publish(10, "entry.new", 10); // 3 to 9 were pruned, so they are never sent.
        var resumed = await TestSupport.TakeAsync(events, 2);

        Assert.True(resumed[0].IsGap);
        Assert.Equal(DaemonEvent.GapType, resumed[0].Type);
        Assert.Equal(new DaemonEvent(10, "entry.new", 10), resumed[1]);

        // Numbers are consecutive again from here on, so there is no second gap.
        fake.Publish(11, "entry.new", 11);
        Assert.Equal(new DaemonEvent(11, "entry.new", 11), (await TestSupport.TakeAsync(events, 1))[0]);
    }

    [Fact]
    public async Task ADaemonWhoseEventLogStartedOverProducesAGap()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);
        fake.Publish(1, "entry.new", 1);
        fake.Publish(2, "entry.new", 2);
        await TestSupport.TakeAsync(events, 2);

        fake.Kill();
        fake.ResetEvents(); // A new database: last_event_seq is 0.
        var gap = await TestSupport.TakeAsync(events, 1);

        Assert.True(gap[0].IsGap);
        fake.Publish(1, "entry.new", 77);
        var next = await TestSupport.TakeAsync(events, 1);
        Assert.Equal(new DaemonEvent(1, "entry.new", 77), next[0]);
    }

    [Fact]
    public async Task EventsWaitForTheClientToStart()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        var pending = TestSupport.TakeAsync(events, 1);
        await Task.Delay(100);
        Assert.False(pending.IsCompleted);
        await client.StartAsync(CancellationToken.None);
        fake.Publish(1, "entry.new", 9);

        Assert.Equal(9, (await pending)[0].SubjectId);
    }

    [Fact]
    public async Task EventsWaitInFailedAndContinueWhenStartSucceedsAgain()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            RetryDelay = TimeSpan.FromMilliseconds(10),
            MaxRetryDelay = TimeSpan.FromMilliseconds(20),
            ReconnectTimeout = TimeSpan.FromMilliseconds(200),
            StartupTimeout = TimeSpan.FromSeconds(3),
        });
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);
        fake.Publish(1, "entry.new", 1);
        await TestSupport.TakeAsync(events, 1);

        fake.Kill();
        var pending = TestSupport.TakeAsync(events, 1);
        await TestSupport.WaitUntilAsync(() => client.State == ConnectionState.Failed);
        fake.Publish(2, "entry.new", 2);
        fake.Restart();
        await client.StartAsync(CancellationToken.None); // The Retry button.

        var resumed = await pending;
        Assert.Equal(2, resumed[0].Seq);
        Assert.False(resumed[0].IsGap);
    }

    [Fact]
    public async Task CancellingEndsTheSequence()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();
        await using var events = client.EventsAsync(cancel.Token).GetAsyncEnumerator(cancel.Token);

        var next = events.MoveNextAsync().AsTask();
        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => next);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DisposingTheClientEndsTheSequenceQuietly(bool daemonDisconnects)
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        await using var events = client.EventsAsync(CancellationToken.None).GetAsyncEnumerator();
        var next = events.MoveNextAsync().AsTask();
        await Task.Delay(50);
        if (daemonDisconnects)
        {
            fake.Kill();
        }

        await client.DisposeAsync();

        var finished = await next.WaitAsync(TestSupport.Patience);
        Assert.False(finished);
    }
}
