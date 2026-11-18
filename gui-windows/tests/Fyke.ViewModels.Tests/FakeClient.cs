using System.Text.Json;
using Fyke.Client;

namespace Fyke.ViewModels.Tests;

/// <summary>A client the test drives by hand.</summary>
internal sealed class FakeClient : IDaemonClient
{
    public ConnectionState State { get; private set; } = ConnectionState.Connecting;

    public event Action<ConnectionState, string?>? StateChanged;

    public int StartCalls { get; private set; }

    /// <summary>What <see cref="StartAsync"/> does: raise states, or throw.</summary>
    public Func<FakeClient, CancellationToken, Task> OnStart { get; set; } = (_, _) => Task.CompletedTask;

    public Func<string, object?, JsonElement> OnCall { get; set; } =
        (_, _) => throw new NotSupportedException();

    public bool HasSubscribers => StateChanged is not null;

    public void Raise(ConnectionState state, string? reason = null)
    {
        State = state;
        StateChanged?.Invoke(state, reason);
    }

    public async Task StartAsync(CancellationToken ct)
    {
        StartCalls++;
        await OnStart(this, ct);
    }

    public Task<JsonElement> CallAsync(string method, object? parameters, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(OnCall(method, parameters));
    }

    public IAsyncEnumerable<DaemonEvent> EventsAsync(CancellationToken ct) => throw new NotSupportedException();

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
