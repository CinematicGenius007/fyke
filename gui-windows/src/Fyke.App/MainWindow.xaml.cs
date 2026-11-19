using System;
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

public sealed partial class MainWindow : Window
{
    private readonly IDaemonClient client = new DaemonClient(new DaemonClientOptions
    {
        ReplaceOlderDaemon = string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FYKE_BIN"))
            && File.Exists(Path.Combine(AppContext.BaseDirectory, "fyke.exe")),
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
        // StackPanel has no font of its own, so the text elements take it from the token.
        var ui = (FontFamily)Application.Current.Resources["FontUi"];
        MessageText.FontFamily = ui;
        DetailText.FontFamily = ui;
        RetryButton.FontFamily = ui;
        InitializeReader(ui);
        ViewModel.PropertyChanged += (_, _) => ShowState();
        ShowState();
        AppWindow.Closing += FinishFolderDisclosureBeforeClose;
        Closed += OnClosed;
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

    private async void OnClosed(object sender, WindowEventArgs args)
    {
        readerReloadTimer.Stop();
        bulkNoticeTimer.Stop();
        textSaveTimer.Stop();
        systemAppearance.ColorValuesChanged -= SystemColorsChanged;
        windowThemeSettings.Changed -= WindowThemeChanged;
        await lifetime.CancelAsync();
        await connection;
        ViewModel.Dispose();
        await client.DisposeAsync();
        lifetime.Dispose();
    }
}
