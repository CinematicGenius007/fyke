using Fyke.Client;

namespace Fyke.ViewModels.Tests;

public sealed class ConnectionViewModelTests
{
    [Theory]
    [InlineData(ConnectionState.Connecting, null, "Starting Fyke…")]
    [InlineData(ConnectionState.Connected, null, "")]
    [InlineData(ConnectionState.Reconnecting, null, "Reconnecting…")]
    [InlineData(ConnectionState.Failed, FailureReason.DaemonTooOld, "Fyke needs to be updated")]
    [InlineData(ConnectionState.Failed, FailureReason.ProgramMissing, "Fyke can't find its background program")]
    [InlineData(ConnectionState.Failed, FailureReason.NotResponding, "Fyke can't reach its background service")]
    [InlineData(ConnectionState.Failed, FailureReason.Cancelled, "Stopped waiting for Fyke")]
    [InlineData(ConnectionState.Failed, null, "Fyke can't reach its background service")]
    [InlineData(ConnectionState.Failed, "something-new", "Fyke can't reach its background service")]
    public void EveryStateHasItsSentence(ConnectionState state, string? reason, string expected)
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);

        client.Raise(state, reason);

        Assert.Equal(state, model.State);
        Assert.Equal(expected, model.Message);
    }

    [Fact]
    public void ItStartsWithTheClientsStateAndMessage()
    {
        var client = new FakeClient();
        client.Raise(ConnectionState.Reconnecting);
        using var model = new ConnectionViewModel(client);

        Assert.Equal(ConnectionState.Reconnecting, model.State);
        Assert.Equal("Reconnecting…", model.Message);
        Assert.True(model.ShowsInlineState);
    }

    [Fact]
    public void TheInlineStateIsQuietWhileConnected()
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);
        Assert.True(model.ShowsInlineState);
        Assert.False(model.IsConnected);

        client.Raise(ConnectionState.Connected);

        Assert.False(model.ShowsInlineState);
        Assert.True(model.IsConnected);
        Assert.Equal(string.Empty, model.Message);
    }

    [Fact]
    public void AReaderThatWorkedIsHeldWhileItReconnects()
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);
        client.Raise(ConnectionState.Reconnecting);
        Assert.False(model.HoldsReader);

        client.Raise(ConnectionState.Connected);
        client.Raise(ConnectionState.Reconnecting);

        Assert.True(model.HoldsReader);
        Assert.False(model.ShowsInlineState);
        Assert.Equal("Reconnecting…", model.Message);

        // A failure falls back to the inline state, with what to do.
        client.Raise(ConnectionState.Failed, FailureReason.ProgramMissing);
        Assert.False(model.HoldsReader);
        Assert.True(model.ShowsInlineState);
    }

    [Fact]
    public void AFailureSaysWhatToDoAndOtherStatesSayNothingMore()
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);

        client.Raise(ConnectionState.Failed, FailureReason.DaemonTooOld);
        Assert.Equal("The background service is older than this app. Update Fyke, then try again.", model.Detail);
        client.Raise(ConnectionState.Failed, FailureReason.ProgramMissing);
        Assert.Equal("Reinstall Fyke, then try again.", model.Detail);
        client.Raise(ConnectionState.Failed, FailureReason.Cancelled);
        Assert.Equal("Try again when you are ready.", model.Detail);
        client.Raise(ConnectionState.Failed, FailureReason.NotResponding);
        Assert.Equal("Nothing was lost. Try again in a moment.", model.Detail);
        client.Raise(ConnectionState.Reconnecting);
        Assert.Equal(string.Empty, model.Detail);
        Assert.Null(model.Reason);
    }

    [Fact]
    public void ChangesAreAnnouncedForBinding()
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);
        var changed = new List<string?>();
        model.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        client.Raise(ConnectionState.Failed, FailureReason.NotResponding);

        Assert.Contains(nameof(ConnectionViewModel.State), changed);
        Assert.Contains(nameof(ConnectionViewModel.Message), changed);
        Assert.Contains(nameof(ConnectionViewModel.Reason), changed);
        Assert.Contains(nameof(ConnectionViewModel.Detail), changed);
        Assert.Contains(nameof(ConnectionViewModel.CanRetry), changed);
        Assert.Contains(nameof(ConnectionViewModel.ShowsInlineState), changed);
        Assert.Contains(nameof(ConnectionViewModel.IsConnected), changed);
    }

    [Fact]
    public void RetryIsOnlyAvailableWhenFailed()
    {
        var client = new FakeClient();
        using var model = new ConnectionViewModel(client);
        var notified = 0;
        model.RetryCommand.CanExecuteChanged += (_, _) => notified++;

        Assert.False(model.RetryCommand.CanExecute(null));
        client.Raise(ConnectionState.Failed, FailureReason.NotResponding);
        Assert.True(model.RetryCommand.CanExecute(null));
        Assert.True(model.CanRetry);
        client.Raise(ConnectionState.Connecting);
        Assert.False(model.RetryCommand.CanExecute(null));
        Assert.True(notified >= 2);
    }

    [Fact]
    public async Task RetryStartsTheClientAgain()
    {
        var client = new FakeClient
        {
            OnStart = (c, _) =>
            {
                c.Raise(ConnectionState.Connecting);
                c.Raise(ConnectionState.Connected);
                return Task.CompletedTask;
            },
        };
        using var model = new ConnectionViewModel(client);
        client.Raise(ConnectionState.Failed, FailureReason.NotResponding);

        await model.RetryCommand.ExecuteAsync(null);

        Assert.Equal(1, client.StartCalls);
        Assert.Equal(ConnectionState.Connected, model.State);
        Assert.Equal(string.Empty, model.Message);
        Assert.False(model.RetryCommand.CanExecute(null));
    }

    [Fact]
    public async Task ARetryThatFailsAgainShowsTheNewReasonAndDoesNotThrow()
    {
        var client = new FakeClient
        {
            OnStart = (c, _) =>
            {
                c.Raise(ConnectionState.Failed, FailureReason.DaemonTooOld);
                throw new DaemonTooOldException(1, 2);
            },
        };
        using var model = new ConnectionViewModel(client);
        client.Raise(ConnectionState.Failed, FailureReason.NotResponding);

        await model.RetryCommand.ExecuteAsync(null);

        Assert.Equal("Fyke needs to be updated", model.Message);
        Assert.True(model.CanRetry);
    }

    [Fact]
    public async Task StartShowsAFailureInsteadOfThrowingIt()
    {
        var client = new FakeClient
        {
            OnStart = (c, _) =>
            {
                c.Raise(ConnectionState.Failed, FailureReason.ProgramMissing);
                throw new DaemonProgramNotFoundException("Cannot find the fyke program.");
            },
        };
        using var model = new ConnectionViewModel(client);

        await model.StartAsync();

        Assert.Equal("Fyke can't find its background program", model.Message);
    }

    [Fact]
    public async Task StartIgnoresACancellation()
    {
        var client = new FakeClient { OnStart = (_, _) => throw new OperationCanceledException() };
        using var model = new ConnectionViewModel(client);

        await model.StartAsync();

        Assert.Equal(1, client.StartCalls);
    }

    [Fact]
    public void StateChangesGoThroughTheDispatcher()
    {
        var client = new FakeClient();
        var queued = new List<Action>();
        using var model = new ConnectionViewModel(client, queued.Add);

        client.Raise(ConnectionState.Reconnecting);

        Assert.Equal(ConnectionState.Connecting, model.State); // Nothing ran yet.
        Assert.Single(queued);
        queued[0]();
        Assert.Equal(ConnectionState.Reconnecting, model.State);
        Assert.Equal("Reconnecting…", model.Message);
    }

    [Fact]
    public void ADisposedModelStopsListening()
    {
        var client = new FakeClient();
        var model = new ConnectionViewModel(client);
        Assert.True(client.HasSubscribers);

        model.Dispose();

        Assert.False(client.HasSubscribers);
    }

    [Fact]
    public void ItRequiresAClient()
    {
        Assert.Throws<ArgumentNullException>(() => new ConnectionViewModel(null!));
    }
}
