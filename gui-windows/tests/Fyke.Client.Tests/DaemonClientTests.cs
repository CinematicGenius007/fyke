using System.Text.Json;

namespace Fyke.Client.Tests;

public sealed class DaemonClientTests
{
    [Fact]
    public void LimitsMatchTheProtocol()
    {
        var options = new DaemonClientOptions();
        Assert.Equal(16 * 1024 * 1024, options.MaxLineBytes);
        Assert.Equal(1024 * 1024, options.MaxRequestBytes);
        Assert.Equal(2, DaemonClient.RequiredApiVersion);
    }

    [Fact]
    public async Task StartConnectsToARunningDaemonWithoutStartingOne()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var starter = new RecordingStarter();
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);

        Assert.Equal(ConnectionState.Connecting, client.State);
        await client.StartAsync(CancellationToken.None);

        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.Equal(0, starter.Calls);
        Assert.Equal(DaemonClient.RequiredApiVersion, client.DaemonApiVersion);
        Assert.Equal([(ConnectionState.Connected, (string?)null)], seen);
    }

    [Fact]
    public async Task ACallReturnsTheResultMember()
    {
        await using var fake = new FakeDaemon();
        fake.On("entries.get", p => new { id = p.GetProperty("id").GetInt64(), title = "Hello" });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var result = await client.CallAsync("entries.get", new { Id = 42 }, CancellationToken.None);

        Assert.Equal(42, result.GetProperty("id").GetInt64());
        Assert.Equal("Hello", result.GetProperty("title").GetString());
    }

    [Fact]
    public async Task ParametersAreWrittenInSnakeCaseAndNullsAreLeftOut()
    {
        await using var fake = new FakeDaemon();
        fake.On("echo", p => p);
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var echoed = await client.CallAsync("echo", new { FeedId = 7, UnreadOnly = true, Before = (long?)null }, CancellationToken.None);
        var none = await client.CallAsync("echo", null, CancellationToken.None);

        Assert.Equal("""{"feed_id":7,"unread_only":true}""", TestSupport.Json(echoed));
        Assert.Equal("{}", TestSupport.Json(none));
    }

    [Fact]
    public async Task AnErrorReplyBecomesAnRpcExceptionWithItsKind()
    {
        await using var fake = new FakeDaemon();
        fake.On("entries.get", _ => new FakeError(-32000, "NoSuchEntry", new { kind = "NoSuchEntry" }));
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var failure = await Assert.ThrowsAsync<DaemonRpcException>(() => client.CallAsync("entries.get", new { Id = 1 }, CancellationToken.None));

        Assert.Equal(-32000, failure.Code);
        Assert.Equal("NoSuchEntry", failure.Kind);
        Assert.Equal("NoSuchEntry", failure.Message);
        Assert.True(failure.Is("no_such_entry"));
        Assert.False(failure.Is("in_use"));
        Assert.False(failure.IsUnknownMethod);
        // An error reply leaves the connection in step: the next call works, on the same connection.
        fake.On("ping", _ => new { ok = true });
        Assert.True((await client.CallAsync("ping", null, CancellationToken.None)).GetProperty("ok").GetBoolean());
        Assert.Equal(1, fake.Accepted);
    }

    [Fact]
    public async Task ARevisionConflictKeepsItsData()
    {
        await using var fake = new FakeDaemon();
        fake.On("views.put", _ => new FakeError(-32000, "revision_conflict", new { kind = "revision_conflict", current = new { id = 3, revision = 9 } }));
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var failure = await Assert.ThrowsAsync<DaemonRpcException>(() => client.CallAsync("views.put", new { Id = 3 }, CancellationToken.None));

        Assert.True(failure.Is("RevisionConflict"));
        Assert.Equal(9, failure.ErrorData!.Value.GetProperty("current").GetProperty("revision").GetInt64());
    }

    [Fact]
    public async Task AnUnknownMethodIsRecognised()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var failure = await Assert.ThrowsAsync<DaemonRpcException>(() => client.CallAsync("nope.nothing", null, CancellationToken.None));

        Assert.True(failure.IsUnknownMethod);
        Assert.Equal(-32601, failure.Code);
    }

    [Fact]
    public async Task ALineOverTheLimitIsRefusedAndTheClientKeepsWorking()
    {
        await using var fake = new FakeDaemon();
        fake.On("big", _ => new { text = new string('x', 5_000) });
        fake.On("small", _ => new { text = "ok" });
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            RetryDelay = options.RetryDelay,
            MaxRetryDelay = options.MaxRetryDelay,
            MaxLineBytes = 2_000,
        });
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<DaemonProtocolException>(() => client.CallAsync("big", null, CancellationToken.None));

        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.Equal("ok", (await client.CallAsync("small", null, CancellationToken.None)).GetProperty("text").GetString());
    }

    [Fact]
    public async Task ALineJustUnderTheLimitIsAccepted()
    {
        await using var fake = new FakeDaemon();
        fake.On("big", _ => new { text = new string('x', 1_500) });
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            MaxLineBytes = 2_000,
        });
        await client.StartAsync(CancellationToken.None);

        var result = await client.CallAsync("big", null, CancellationToken.None);

        Assert.Equal(1_500, result.GetProperty("text").GetString()!.Length);
    }

    [Fact]
    public async Task AReplyOverSixteenMebibytesIsRefusedByDefault()
    {
        await using var fake = new FakeDaemon();
        fake.On("huge", _ => new RawLine(new string('x', 16 * 1024 * 1024 + 1)));
        fake.On("small", _ => new { ok = true });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<DaemonProtocolException>(() => client.CallAsync("huge", null, CancellationToken.None));

        Assert.True((await client.CallAsync("small", null, CancellationToken.None)).GetProperty("ok").GetBoolean());
    }

    [Fact]
    public async Task ARequestOverTheDaemonsLimitIsRefusedBeforeItIsSent()
    {
        await using var fake = new FakeDaemon();
        fake.On("put", _ => new { ok = true });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<DaemonProtocolException>(() =>
            client.CallAsync("put", new { Text = new string('x', 1024 * 1024) }, CancellationToken.None));

        Assert.Equal(ConnectionState.Connected, client.State);
    }

    [Fact]
    public async Task ALineThatIsNotJsonIsAProtocolError()
    {
        await using var fake = new FakeDaemon();
        fake.On("garbage", _ => new RawLine("this is not json"));
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<DaemonProtocolException>(() => client.CallAsync("garbage", null, CancellationToken.None));
    }

    [Fact]
    public async Task ACallThatTakesTooLongTimesOutAndTheNextOneWorks()
    {
        await using var fake = new FakeDaemon();
        fake.On("hang", async _ =>
        {
            await Task.Delay(TimeSpan.FromSeconds(30));
            return new { };
        });
        fake.On("ping", _ => new { ok = true });
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            CallTimeout = TimeSpan.FromMilliseconds(200),
        });
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<TimeoutException>(() => client.CallAsync("hang", null, CancellationToken.None));

        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.True((await client.CallAsync("ping", null, CancellationToken.None)).GetProperty("ok").GetBoolean());
    }

    [Fact]
    public async Task CancellingACallThrowsCancellationNotTimeout()
    {
        await using var fake = new FakeDaemon();
        fake.On("hang", async _ =>
        {
            await Task.Delay(TimeSpan.FromSeconds(30));
            return new { };
        });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);
        using var cancel = new CancellationTokenSource();

        var call = client.CallAsync("hang", null, cancel.Token);
        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => call);
    }

    [Fact]
    public async Task SlowCallsGetTheLongerTimeout()
    {
        var options = new DaemonClientOptions { CallTimeout = TimeSpan.FromSeconds(1), SlowCallTimeout = TimeSpan.FromSeconds(9) };
        Assert.Contains("entries.fetch_full", options.SlowMethods);
        Assert.DoesNotContain("entries.list", options.SlowMethods);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task CallsRunAtTheSameTimeOnTheirOwnConnections()
    {
        await using var fake = new FakeDaemon();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.On("slow", async _ =>
        {
            await release.Task;
            return new { done = "slow" };
        });
        fake.On("quick", _ => new { done = "quick" });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var slow = client.CallAsync("slow", null, CancellationToken.None);
        var quick = await client.CallAsync("quick", null, CancellationToken.None);

        Assert.Equal("quick", quick.GetProperty("done").GetString());
        Assert.False(slow.IsCompleted);
        release.SetResult();
        Assert.Equal("slow", (await slow).GetProperty("done").GetString());
    }

    [Fact]
    public async Task CallingBeforeStartIsAMistake()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));

        await Assert.ThrowsAsync<InvalidOperationException>(() => client.CallAsync("stats.get", null, CancellationToken.None));
    }

    // ----- starting the daemon -----

    [Fact]
    public async Task StartStartsTheDaemonWhenTheSocketDoesNotAnswer()
    {
        await using var fake = new FakeDaemon();
        var starter = new RecordingStarter(folder =>
        {
            Assert.Equal(fake.Folder, folder);
            _ = Task.Run(async () =>
            {
                await Task.Delay(100);
                fake.Start();
            });
        });
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.Equal(1, starter.Calls);
        Assert.Equal([(ConnectionState.Connected, (string?)null)], seen);
    }

    [Fact]
    public async Task StartGivesUpWhenNothingAnswersAndSaysWhy()
    {
        await using var fake = new FakeDaemon();
        var starter = new RecordingStarter();
        var options = TestSupport.Options(fake, starter);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = starter,
            RetryDelay = TimeSpan.FromMilliseconds(10),
            MaxRetryDelay = TimeSpan.FromMilliseconds(20),
            StartRetryInterval = TimeSpan.FromMilliseconds(100),
            StartupTimeout = TimeSpan.FromMilliseconds(500),
        });
        var seen = TestSupport.Record(client);

        var failure = await Assert.ThrowsAsync<DaemonUnavailableException>(() => client.StartAsync(CancellationToken.None));

        Assert.Equal(FailureReason.NotResponding, failure.Reason);
        Assert.Equal(ConnectionState.Failed, client.State);
        // The client starts in Connecting, so only the move to Failed is announced.
        Assert.Equal([(ConnectionState.Failed, FailureReason.NotResponding)], seen);
        Assert.InRange(starter.Calls, 2, 8); // Started again every interval, with backoff between.
        // A call in the Failed state fails at once instead of waiting.
        await Assert.ThrowsAsync<DaemonUnavailableException>(() => client.CallAsync("stats.get", null, CancellationToken.None));
    }

    [Fact]
    public async Task StartAgainFromFailedRecoversOnceTheDaemonIsBack()
    {
        await using var fake = new FakeDaemon();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            RetryDelay = TimeSpan.FromMilliseconds(10),
            MaxRetryDelay = TimeSpan.FromMilliseconds(20),
            StartupTimeout = TimeSpan.FromMilliseconds(200),
        });
        await Assert.ThrowsAsync<DaemonUnavailableException>(() => client.StartAsync(CancellationToken.None));
        Assert.Equal(ConnectionState.Failed, client.State);
        fake.On("ping", _ => new { ok = true });
        fake.Start();

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.True((await client.CallAsync("ping", null, CancellationToken.None)).GetProperty("ok").GetBoolean());
    }

    [Fact]
    public async Task AMissingProgramFailsAtOnceWithItsOwnReason()
    {
        await using var fake = new FakeDaemon();
        await using var client = new DaemonClient(TestSupport.Options(fake, new ThrowingStarter()));
        var seen = TestSupport.Record(client);

        var failure = await Assert.ThrowsAsync<DaemonProgramNotFoundException>(() => client.StartAsync(CancellationToken.None));

        Assert.Equal(FailureReason.ProgramMissing, failure.Reason);
        Assert.Equal(ConnectionState.Failed, client.State);
        Assert.Equal((ConnectionState.Failed, FailureReason.ProgramMissing), seen[^1]);
    }

    [Fact]
    public async Task CancellingStartLeavesTheClientFailedAndRetryable()
    {
        await using var fake = new FakeDaemon();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        using var cancel = new CancellationTokenSource();

        var start = client.StartAsync(cancel.Token);
        await cancel.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => start);

        Assert.Equal(ConnectionState.Failed, client.State);
        fake.Start();
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(ConnectionState.Connected, client.State);
    }

    // ----- version -----

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task BundledDaemonReplacementRequestsShutdownOnlyOnce(bool compatibleReplacement)
    {
        var oldVersion = DaemonClient.RequiredApiVersion - 1;
        await using var fake = new FakeDaemon { ApiVersion = oldVersion };
        var stops = 0;
        fake.On("daemon.stop", _ =>
        {
            Interlocked.Increment(ref stops);
            fake.Kill();
            return new { };
        });
        fake.Start();
        var starter = new RecordingStarter(_ =>
        {
            fake.ApiVersion = compatibleReplacement ? DaemonClient.RequiredApiVersion : oldVersion;
            fake.Start();
        });
        await using var client = new DaemonClient(TestSupport.Options(fake, starter, replaceOlder: true));

        if (compatibleReplacement)
        {
            await client.StartAsync(CancellationToken.None);
            Assert.Equal(ConnectionState.Connected, client.State);
        }
        else
        {
            await Assert.ThrowsAsync<DaemonTooOldException>(() => client.StartAsync(CancellationToken.None));
        }

        Assert.Equal(1, stops);
        Assert.Equal(1, starter.Calls);
    }

    [Fact]
    public async Task ADaemonOlderThanTheAppIsRefusedWithoutRetrying()
    {
        await using var fake = new FakeDaemon { ApiVersion = 1 };
        fake.Start();
        var starter = new RecordingStarter();
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);

        var failure = await Assert.ThrowsAsync<DaemonTooOldException>(() => client.StartAsync(CancellationToken.None));

        Assert.Equal(1, failure.Found);
        Assert.Equal(2, failure.Required);
        Assert.Equal(FailureReason.DaemonTooOld, failure.Reason);
        Assert.Equal(ConnectionState.Failed, client.State);
        Assert.Equal(0, starter.Calls);
        Assert.Equal((ConnectionState.Failed, FailureReason.DaemonTooOld), seen[^1]);
    }

    [Fact]
    public async Task ADaemonWithoutAnApiVersionCountsAsOldest()
    {
        await using var fake = new FakeDaemon { SendApiVersion = false };
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));

        var failure = await Assert.ThrowsAsync<DaemonTooOldException>(() => client.StartAsync(CancellationToken.None));

        Assert.Equal(1, failure.Found);
    }

    [Fact]
    public async Task ADaemonThatDoesNotKnowStatsIsTooOld()
    {
        await using var fake = new FakeDaemon();
        fake.On("stats.get", _ => new FakeError(-32601, "UnknownMethod", new { kind = "UnknownMethod" }));
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));

        await Assert.ThrowsAsync<DaemonTooOldException>(() => client.StartAsync(CancellationToken.None));
    }

    [Fact]
    public async Task ANewerDaemonIsAccepted()
    {
        await using var fake = new FakeDaemon { ApiVersion = DaemonClient.RequiredApiVersion + 5 };
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));

        await client.StartAsync(CancellationToken.None);

        Assert.Equal(ConnectionState.Connected, client.State);
    }

    // ----- reconnecting -----

    [Fact]
    public async Task AfterTheDaemonDiesACallReconnectsStartsItAndRetries()
    {
        await using var fake = new FakeDaemon();
        fake.On("ping", _ => new { ok = true });
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);
        await client.StartAsync(CancellationToken.None);
        await client.CallAsync("ping", null, CancellationToken.None);

        fake.Kill();
        var result = await client.CallAsync("ping", null, CancellationToken.None);

        Assert.True(result.GetProperty("ok").GetBoolean());
        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.Equal(1, starter.Calls);
        Assert.Equal(
            [
                (ConnectionState.Connected, (string?)null),
                (ConnectionState.Reconnecting, (string?)null),
                (ConnectionState.Connected, (string?)null),
            ],
            seen);
    }

    [Fact]
    public async Task LostWriteReplyDoesNotReplayTheRequest()
    {
        await using var fake = new FakeDaemon();
        var writes = 0;
        fake.On("views.put", _ =>
        {
            if (Interlocked.Increment(ref writes) == 1)
            {
                fake.Kill();
            }

            return new { ok = true };
        });
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        await client.StartAsync(CancellationToken.None);

        await Assert.ThrowsAsync<DaemonOutcomeUnknownException>(
            () => client.CallAsync("views.put", null, CancellationToken.None));

        Assert.Equal(1, writes);
        Assert.Equal(ConnectionState.Connected, client.State);
    }

    [Fact]
    public async Task CallsThatFailTogetherShareOneReconnect()
    {
        await using var fake = new FakeDaemon();
        fake.On("ping", _ => new { ok = true });
        fake.Start();
        var starter = new RecordingStarter(_ => fake.Restart());
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        var seen = TestSupport.Record(client);
        await client.StartAsync(CancellationToken.None);
        // Fill the pool with several idle connections.
        await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => client.CallAsync("ping", null, CancellationToken.None)));

        fake.Kill();
        var results = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => client.CallAsync("ping", null, CancellationToken.None)));

        Assert.All(results, r => Assert.True(r.GetProperty("ok").GetBoolean()));
        Assert.Equal(1, seen.Count(s => s.State == ConnectionState.Reconnecting));
        Assert.Equal(ConnectionState.Connected, client.State);
    }

    [Fact]
    public async Task WhenTheDaemonDoesNotComeBackTheClientFailsAndRetryWorks()
    {
        await using var fake = new FakeDaemon();
        fake.On("ping", _ => new { ok = true });
        fake.Start();
        var options = TestSupport.Options(fake);
        await using var client = new DaemonClient(new DaemonClientOptions
        {
            DataFolder = options.DataFolder,
            SocketPath = options.SocketPath,
            ProcessStarter = options.ProcessStarter,
            RetryDelay = TimeSpan.FromMilliseconds(10),
            MaxRetryDelay = TimeSpan.FromMilliseconds(20),
            ReconnectTimeout = TimeSpan.FromMilliseconds(300),
        });
        var seen = TestSupport.Record(client);
        await client.StartAsync(CancellationToken.None);

        fake.Kill();
        await Assert.ThrowsAsync<DaemonUnavailableException>(() => client.CallAsync("ping", null, CancellationToken.None));

        Assert.Equal(ConnectionState.Failed, client.State);
        Assert.Equal(
            [
                (ConnectionState.Connected, (string?)null),
                (ConnectionState.Reconnecting, (string?)null),
                (ConnectionState.Failed, FailureReason.NotResponding),
            ],
            seen);

        fake.Restart();
        await client.StartAsync(CancellationToken.None);
        Assert.Equal(ConnectionState.Connected, client.State);
        Assert.True((await client.CallAsync("ping", null, CancellationToken.None)).GetProperty("ok").GetBoolean());
    }

    [Fact]
    public async Task ADaemonThatCameBackOlderFailsTheReconnect()
    {
        await using var fake = new FakeDaemon();
        fake.On("ping", _ => new { ok = true });
        fake.Start();
        var starter = new RecordingStarter(_ =>
        {
            fake.ApiVersion = 1;
            fake.Restart();
        });
        await using var client = new DaemonClient(TestSupport.Options(fake, starter));
        await client.StartAsync(CancellationToken.None);

        fake.Kill();
        await Assert.ThrowsAsync<DaemonTooOldException>(() => client.CallAsync("ping", null, CancellationToken.None));

        Assert.Equal(ConnectionState.Failed, client.State);
    }

    [Fact]
    public async Task DisposeIsQuietAndRepeatable()
    {
        await using var fake = new FakeDaemon();
        fake.Start();
        var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        await client.DisposeAsync();
        await client.DisposeAsync();

        await Assert.ThrowsAsync<ObjectDisposedException>(() => client.CallAsync("stats.get", null, CancellationToken.None));
    }

    [Fact]
    public async Task ResultsAreUsableAfterTheirConnectionIsReused()
    {
        await using var fake = new FakeDaemon();
        fake.On("one", _ => new { n = 1 });
        fake.On("two", _ => new { n = 2 });
        fake.Start();
        await using var client = new DaemonClient(TestSupport.Options(fake));
        await client.StartAsync(CancellationToken.None);

        var first = await client.CallAsync("one", null, CancellationToken.None);
        var second = await client.CallAsync("two", null, CancellationToken.None);

        Assert.Equal(JsonValueKind.Object, first.ValueKind);
        Assert.Equal(1, first.GetProperty("n").GetInt32());
        Assert.Equal(2, second.GetProperty("n").GetInt32());
        Assert.Equal(1, fake.Accepted);
    }
}
