using System;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Fyke.App;

/// <summary>The window's opening size and the smallest size its layout holds, as on macOS.</summary>
public sealed partial class MainWindow
{
    // In view pixels, like the macOS window (gui/Sources/Reader/ReaderApp.swift).
    private const double OpeningWidth = 1440;
    private const double OpeningHeight = 900;
    private const double MinimumWidth = 960;
    private const double MinimumHeight = 600;

    /// <summary>Opens centred in the work area, at the macOS size or as much of it as fits.</summary>
    private void SizeWindow()
    {
        var scale = NativeMethods.GetDpiForWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        if (scale <= 0)
        {
            scale = 1;
        }

        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(Pixels(OpeningWidth, scale), area.Width);
        var height = Math.Min(Pixels(OpeningHeight, scale), area.Height);
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
        ApplyMinimumSize(scale);
        Root.Loaded += (_, _) => Root.XamlRoot.Changed += (root, _) => ApplyMinimumSize(root.RasterizationScale);
    }

    // The presenter takes physical pixels, so the minimum follows the display's scale.
    private void ApplyMinimumSize(double scale)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = Pixels(MinimumWidth, scale);
            presenter.PreferredMinimumHeight = Pixels(MinimumHeight, scale);
        }
    }

    private static int Pixels(double viewPixels, double scale) => (int)Math.Round(viewPixels * scale);

    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        public static extern uint GetDpiForWindow(nint window);
    }
}
