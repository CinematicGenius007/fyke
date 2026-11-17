using System;
using System.Threading;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Fyke.App;

public sealed partial class MainWindow : Window
{
    private readonly IDaemonClient client = new DaemonClient(new DaemonClientOptions());
    private readonly CancellationTokenSource lifetime = new();

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
        // The XAML compiler rejects a font family resource used from markup, so it is set here.
        InlineState.FontFamily = (FontFamily)Application.Current.Resources["FontUi"];
        Root.DataContext = ViewModel;
        ViewModel.PropertyChanged += (_, _) => ShowState();
        ShowState();
        Closed += OnClosed;
        // The view model shows a failure where the window can say it; nothing is thrown here.
        _ = ViewModel.StartAsync(lifetime.Token);
    }

    /// Quiet until it matters: the state shows only while connecting or failed, and the
    /// explanation and Try again only after a failure.
    private void ShowState()
    {
        InlineState.Visibility = ViewModel.ShowsInlineState ? Visibility.Visible : Visibility.Collapsed;
        var failed = ViewModel.CanRetry ? Visibility.Visible : Visibility.Collapsed;
        DetailText.Visibility = failed;
        RetryButton.Visibility = failed;
    }

    private async void OnClosed(object sender, WindowEventArgs args)
    {
        await lifetime.CancelAsync();
        ViewModel.Dispose();
        await client.DisposeAsync();
        lifetime.Dispose();
    }
}
