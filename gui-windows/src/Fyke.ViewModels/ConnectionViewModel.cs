using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>
/// The inline connection state: what the window says when the daemon is starting, gone, or too
/// old, and the Retry that tries again. Holds no UI types.
/// </summary>
public sealed class ConnectionViewModel : ObservableObject, IDisposable
{
    private readonly IDaemonClient _client;
    private readonly Action<Action> _dispatch;
    private ConnectionState _state;
    private string? _reason;
    private string _message;
    private string _detail;

    /// <param name="client">The client whose state is shown.</param>
    /// <param name="dispatch">
    /// Runs an action on the UI thread. The client raises its events on any thread, so the app passes
    /// its dispatcher queue here. Null runs the action at once, which suits tests.
    /// </param>
    public ConnectionViewModel(IDaemonClient client, Action<Action>? dispatch = null)
    {
        ArgumentNullException.ThrowIfNull(client);
        _client = client;
        _dispatch = dispatch ?? (action => action());
        _state = client.State;
        _message = ConnectionMessages.For(_state, null);
        _detail = ConnectionMessages.DetailFor(_state, null);
        RetryCommand = new AsyncRelayCommand(RetryAsync, () => CanRetry);
        client.StateChanged += OnStateChanged;
    }

    public ConnectionState State => _state;

    /// <summary>A <see cref="FailureReason"/> code while failed, otherwise null.</summary>
    public string? Reason => _reason;

    /// <summary>The sentence the window shows. Empty while connected.</summary>
    public string Message => _message;

    /// <summary>What to do about a failure. Empty unless failed.</summary>
    public string Detail => _detail;

    public bool IsConnected => _state == ConnectionState.Connected;

    /// <summary>The inline state is quiet until it matters: hidden while connected.</summary>
    public bool ShowsInlineState => _state != ConnectionState.Connected;

    public bool CanRetry => _state == ConnectionState.Failed;

    public IAsyncRelayCommand RetryCommand { get; }

    /// <summary>Connects, and shows what happens. A failure is shown, not thrown.</summary>
    public async Task StartAsync(CancellationToken ct = default)
    {
        try
        {
            await _client.StartAsync(ct).ConfigureAwait(false);
        }
        catch (DaemonException)
        {
            // The client moved to Failed and said why; the state is what the person sees.
        }
        catch (OperationCanceledException)
        {
            // Stopped on purpose.
        }
    }

    public void Dispose() => _client.StateChanged -= OnStateChanged;

    private Task RetryAsync(CancellationToken ct) => StartAsync(ct);

    private void OnStateChanged(ConnectionState state, string? reason) => _dispatch(() => Apply(state, reason));

    private void Apply(ConnectionState state, string? reason)
    {
        var reasonNow = state == ConnectionState.Failed ? reason : null;
        SetProperty(ref _state, state, nameof(State));
        SetProperty(ref _reason, reasonNow, nameof(Reason));
        SetProperty(ref _message, ConnectionMessages.For(state, reasonNow), nameof(Message));
        SetProperty(ref _detail, ConnectionMessages.DetailFor(state, reasonNow), nameof(Detail));
        OnPropertyChanged(nameof(IsConnected));
        OnPropertyChanged(nameof(ShowsInlineState));
        OnPropertyChanged(nameof(CanRetry));
        RetryCommand.NotifyCanExecuteChanged();
    }
}
