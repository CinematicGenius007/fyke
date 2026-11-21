using System;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.Windows.AppLifecycle;

namespace Fyke.App;

// One window per data folder (Program.cs): a second launch, from Start, the taskbar or a
// shortcut, arrives here instead of opening another window, as a second open of the Mac
// app does. So does a click on a routine notification.
public sealed partial class MainWindow
{
    private void InitializeActivation() => AppInstance.GetCurrent().Activated += AnotherLaunch;

    private void CloseActivation() => AppInstance.GetCurrent().Activated -= AnotherLaunch;

    // Raised on a pool thread.
    private void AnotherLaunch(object? sender, AppActivationArguments args) => DispatcherQueue.TryEnqueue(BringForward);

    /// Restores a minimised window and puts it in front, with the keyboard.
    private void BringForward()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
        {
            presenter.Restore();
        }

        Activate();
        _ = ActivationMethods.SetForegroundWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
    }

    private static class ActivationMethods
    {
        [DllImport("user32.dll")]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        public static extern int SetForegroundWindow(nint window);
    }
}
