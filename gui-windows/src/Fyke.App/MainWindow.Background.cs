using System.Threading;
using System.Threading.Tasks;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;

namespace Fyke.App;

/// <summary>General's "Keep updating in the background", through <see cref="BackgroundUpdates"/>.</summary>
public sealed partial class MainWindow
{
    private BackgroundUpdates backgroundUpdates = null!;
    // True while the switch is set from what fyke reports, or a change is under way.
    private bool backgroundBusy;

    private void InitializeBackgroundUpdates()
    {
        backgroundUpdates = new BackgroundUpdates(McpProgram());
        SettingsPane.BackgroundToggle.Toggled += BackgroundToggled;
    }

    /// <summary>Shows whether the daemon starts at sign-in. The switch stays off and
    /// disabled when fyke cannot tell, rather than claim either.</summary>
    private async Task ReadBackgroundUpdatesAsync()
    {
        if (backgroundBusy)
        {
            return;
        }

        backgroundBusy = true;
        try
        {
            var on = await backgroundUpdates.IsOnAsync(CancellationToken.None);
            SettingsPane.BackgroundToggle.IsOn = on == true;
            SettingsPane.BackgroundToggle.IsEnabled = on is not null;
        }
        finally
        {
            backgroundBusy = false;
        }
    }

    private async void BackgroundToggled(object sender, RoutedEventArgs args)
    {
        if (backgroundBusy || !IsSettingsOpen)
        {
            return;
        }

        backgroundBusy = true;
        var toggle = SettingsPane.BackgroundToggle;
        toggle.IsEnabled = false;
        string? problem;
        try
        {
            // Turning it on or off restarts the daemon; the window reconnects on its own.
            problem = await backgroundUpdates.SetAsync(toggle.IsOn, CancellationToken.None);
        }
        finally
        {
            backgroundBusy = false;
        }

        if (problem is not null)
        {
            ShowSettingsStatus(problem);
        }

        await ReadBackgroundUpdatesAsync();
    }
}
