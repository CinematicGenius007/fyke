using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Fyke.App;

[System.Diagnostics.CodeAnalysis.SuppressMessage("Design", "CA1001",
    Justification = "A WinUI window is not disposable; OnClosed disposes what it owns.")]
public sealed partial class MainWindow : Window
{
    private readonly DaemonClient client = new(new DaemonClientOptions
    {
        ReplaceOlderDaemon = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FYKE_BIN"))
            && File.Exists(Path.Combine(AppContext.BaseDirectory, "fyke.exe")),
        PostsNotifications = RoutineNotifier.CanPost,
    });
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task connection;

    public ConnectionViewModel ViewModel { get; }

    public MainWindow()
    {
        // The client raises its events on any thread; the view model hands them to this one.
        var queue = DispatcherQueue.GetForCurrentThread();
        ViewModel = new ConnectionViewModel(client, action => queue.TryEnqueue(() => action()));
        InitializeComponent();
        Title = "Fyke";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Fyke.ico"));
        // StackPanel has no font of its own, so the text elements bind to the face themselves.
        ReaderFaces.Shared.Bind(MessageText, nameof(ReaderFaces.Ui));
        ReaderFaces.Shared.Bind(DetailText, nameof(ReaderFaces.Ui));
        ReaderFaces.Shared.Bind(RetryButton, nameof(ReaderFaces.Ui));
        InitializeReader();
        ViewModel.PropertyChanged += (_, _) => ShowState();
        ShowState();
        SizeWindow();
        AppWindow.Closing += FinishFolderDisclosureBeforeClose;
        Closed += OnClosed;
        InitializeNotifications();
        InitializeActivation();
        connection = KeepConnectionAsync(lifetime.Token);
    }

    private async Task KeepConnectionAsync(CancellationToken cancellationToken)
    {
        await ViewModel.StartAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await foreach (var change in client.EventsAsync(cancellationToken).ConfigureAwait(false))
            {
                QueueReaderChange(change);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    /// Quiet until it matters: the state shows only while connecting or failed, and the
    /// explanation and Try again only after a failure.
    private void ShowState()
    {
        InlineState.Visibility = ViewModel.ShowsInlineState ? Visibility.Visible : Visibility.Collapsed;
        var failed = ViewModel.CanRetry ? Visibility.Visible : Visibility.Collapsed;
        DetailText.Visibility = failed;
        RetryButton.Visibility = failed;
        ShowReaderConnection();
    }

    // An event handler, so nothing may escape it: an exception here would end the process
    // while it closes. Each step runs whatever happened to the one before.
    private async void OnClosed(object sender, WindowEventArgs args)
    {
        readerReloadTimer.Stop();
        todayReloadTimer.Stop();
        bulkNoticeTimer.Stop();
        textSaveTimer.Stop();
        systemAppearance.ColorValuesChanged -= SystemColorsChanged;
        windowThemeSettings.Changed -= WindowThemeChanged;
        CloseNotifications();
        CloseActivation();
        try
        {
            await lifetime.CancelAsync();
            await connection;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            Trace.TraceError($"The connection to the daemon ended with an error: {e}");
        }
        finally
        {
            ViewModel.Dispose();
            await client.DisposeAsync();
            lifetime.Dispose();
        }
    }
}
