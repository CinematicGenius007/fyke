using System;
using Microsoft.UI.Xaml;

namespace Fyke.App;

public partial class App : Application
{
    private Window? window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            window = new MainWindow();
            window.Activate();
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            throw;
        }
    }
}
