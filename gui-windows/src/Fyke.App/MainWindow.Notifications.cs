using System;
using System.Diagnostics;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Fyke.App;

// A routine's notify action, as on macOS: while the window is open, each `routine.notify`
// event becomes a system notification. Clicking one brings the window forward. With the
// window closed nothing is posted yet; that is W4 (docs/windows-gui.md).
public sealed partial class MainWindow
{
    private readonly RoutineNotices routineNotices = new();
    private bool notificationsRegistered;

    /// A headless check must not reach the notification centre of the person at this PC.
    private static bool Headless => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FYKE_HEADLESS"));

    private void InitializeNotifications()
    {
        if (Headless)
        {
            return;
        }

        try
        {
            if (!AppNotificationManager.IsSupported())
            {
                return;
            }

            var manager = AppNotificationManager.Default;
            // Subscribe before Register, so a click while the window is open comes here.
            manager.NotificationInvoked += NotificationInvoked;
            manager.Register();
            notificationsRegistered = true;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"Notifications are not available: {e.Message}");
        }
    }

    private void QueueNotification(DaemonEvent change)
    {
        if (notificationsRegistered && routineNotices.ShouldPost(change, DateTimeOffset.Now))
        {
            _ = DispatcherQueue.TryEnqueue(PostRoutineNotification);
        }
    }

    private static void PostRoutineNotification()
    {
        try
        {
            var notification = new AppNotificationBuilder()
                .AddText(RoutineNotices.Title)
                .AddText(RoutineNotices.Body)
                .BuildNotification();
            // Denied in Settings: the system drops it, as macOS does without authorisation.
            if (AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled)
            {
                AppNotificationManager.Default.Show(notification);
            }
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"A routine notification was not shown: {e.Message}");
        }
    }

    private void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
        DispatcherQueue.TryEnqueue(() => Activate());

    private void CloseNotifications()
    {
        if (!notificationsRegistered)
        {
            return;
        }

        notificationsRegistered = false;
        try
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
            // An unpackaged app removes its registration, so a click after it closes does not
            // start a second copy before W4 brings single-instance activation.
            AppNotificationManager.Default.Unregister();
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"Notifications were not unregistered: {e.Message}");
        }
    }
}
