using System;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.Windows.AppNotifications;

namespace Fyke.App;

// A routine's notify action, as on macOS: while the window is open, each `routine.notify`
// event becomes a system notification, and clicking one brings the window forward. The
// client tells the daemon so (PostsNotifications); with the window closed the daemon starts
// `Fyke.App.exe --notify` instead (RoutineNotifier).
public sealed partial class MainWindow
{
    private readonly RoutineNotices routineNotices = new();
    private bool notificationsRegistered;

    private void InitializeNotifications() =>
        notificationsRegistered = RoutineNotifier.Register(NotificationInvoked);

    private void QueueNotification(DaemonEvent change)
    {
        if (notificationsRegistered && routineNotices.ShouldPost(change, DateTimeOffset.Now))
        {
            _ = DispatcherQueue.TryEnqueue(RoutineNotifier.Post);
        }
    }

    private void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
        DispatcherQueue.TryEnqueue(BringForward);

    private void CloseNotifications()
    {
        if (notificationsRegistered)
        {
            notificationsRegistered = false;
            RoutineNotifier.Unregister(NotificationInvoked);
        }
    }
}
