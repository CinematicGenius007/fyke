using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Fyke.ViewModels;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Invoked = Windows.Foundation.TypedEventHandler<Microsoft.Windows.AppNotifications.AppNotificationManager,
    Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs>;

namespace Fyke.App;

/// <summary>
/// Posts a routine's notification through the Windows App SDK, as macOS does through its
/// notification centre. The open window posts each <c>routine.notify</c> event it receives.
/// With every window closed the daemon runs <c>Fyke.App.exe --notify</c>, which posts one
/// and exits before any window opens (<c>src/notify.zig</c>). Clicking a notification
/// starts Fyke, or brings the open window forward.
/// </summary>
internal static class RoutineNotifier
{
    public const string Argument = "--notify";
    public const string RemoveArgument = "--unregister-notifications";

    private static readonly Lazy<bool> Supported = new(() =>
    {
        try
        {
            return AppNotificationManager.IsSupported();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            return false;
        }
    });

    /// <summary>
    /// False in a headless check, which must not reach the notification centre of the person
    /// at this PC, and on a system without notifications.
    /// </summary>
    public static bool CanPost =>
        string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FYKE_HEADLESS")) && Supported.Value;

    /// <summary>Registers this process as the target of clicks. False when it cannot post.</summary>
    public static bool Register(Invoked invoked)
    {
        if (!CanPost)
        {
            return false;
        }

        try
        {
            var manager = AppNotificationManager.Default;
            // Subscribe before Register, so that a click while this process runs comes here.
            manager.NotificationInvoked += invoked;
            manager.Register();
            return true;
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"Notifications are not available: {e.Message}");
            return false;
        }
    }

    /// <summary>
    /// Stops taking clicks in this process. The registration stays with the system, so a
    /// click later starts Fyke.
    /// </summary>
    public static void Unregister(Invoked invoked)
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked -= invoked;
            AppNotificationManager.Default.Unregister();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"Notifications were not unregistered: {e.Message}");
        }
    }

    public static void Post()
    {
        try
        {
            // Turned off in Settings: nothing is posted, as on macOS without permission.
            if (AppNotificationManager.Default.Setting != AppNotificationSetting.Enabled)
            {
                return;
            }

            var notification = new AppNotificationBuilder()
                .AddText(RoutineNotices.Title)
                .AddText(RoutineNotices.Body)
                .BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"A routine notification was not shown: {e.Message}");
        }
    }

    /// <summary>
    /// The uninstaller's launch: removes Fyke from the notification settings and the
    /// registration that lets a click start it.
    /// </summary>
    public static void RemoveRegistration()
    {
        try
        {
            if (Supported.Value)
            {
                AppNotificationManager.Default.UnregisterAll();
            }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            Trace.TraceWarning($"Notifications were not removed: {e.Message}");
        }
    }

    /// <summary>The <c>--notify</c> launch: posts one notification, and opens no window.</summary>
    public static void PostAlone()
    {
        Invoked ignore = static (_, _) => { };
        if (Register(ignore))
        {
            Post();
            Unregister(ignore);
        }
    }
}
