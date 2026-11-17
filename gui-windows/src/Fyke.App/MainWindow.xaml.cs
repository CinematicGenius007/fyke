using System;
using System.Threading;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;

namespace Fyke.App;

public sealed partial class MainWindow : Window
{
    private readonly IDaemonClient client = new DaemonClient(new DaemonClientOptions());
    private readonly CancellationTokenSource lifetime = new();

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        var viewModel = new ConnectionViewModel(client);
        ((FrameworkElement)Content).DataContext = viewModel;
        Closed += OnClosed;
        _ = client.StartAsync(lifetime.Token);
    }

    private async void OnClosed(object sender, WindowEventArgs args)
    {
        lifetime.Cancel();
        await client.DisposeAsync();
        lifetime.Dispose();
    }
}
