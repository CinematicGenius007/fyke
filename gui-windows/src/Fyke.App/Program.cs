using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Fyke.App;

/// <summary>
/// The entry point, written out (DISABLE_XAML_GENERATED_MAIN) so that a second launch can
/// hand itself to the window already open before it builds one of its own.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main()
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        if (RedirectedToOpenWindow())
        {
            return 0;
        }

        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }

    /// True when another Fyke has this data folder open and took this launch.
    private static bool RedirectedToOpenWindow()
    {
        var key = SingleInstance.Key(Environment.GetEnvironmentVariable("FYKE_HOME"));
        var owner = AppInstance.FindOrRegisterForKey(key);
        if (owner.IsCurrent)
        {
            return false;
        }

        // Only the process the person launched may bring a window forward, so it lends that
        // right to the one it hands over to.
        _ = NativeMethods.AllowSetForegroundWindow(owner.ProcessId);
        var arguments = AppInstance.GetCurrent().GetActivatedEventArgs();
        // The redirect is a WinRT call that must not wait on this STA thread, so it runs on
        // the pool; nothing else exists yet for the wait to block.
        Task.Run(() => owner.RedirectActivationToAsync(arguments).AsTask()).GetAwaiter().GetResult();
        return true;
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        public static extern int AllowSetForegroundWindow(uint processId);
    }
}
