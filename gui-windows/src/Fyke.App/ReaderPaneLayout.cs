using System;

namespace Fyke.App;

internal static class ReaderPaneLayout
{
    public const double DefaultSidebar = 232;
    public const double DefaultTimeline = 368;
    public const double Divider = 8;

    public static double Sidebar(double width) => Math.Min(DefaultSidebar, Math.Max(0, width * 0.30));

    public static double Timeline(double width, double requested)
    {
        var available = Math.Max(0, width - Sidebar(width) - Divider - 1);
        var minimum = Math.Min(280, available * 0.45);
        var maximum = Math.Max(minimum, Math.Min(640, available - Math.Min(400, available * 0.5)));
        return Math.Clamp(requested, minimum, maximum);
    }
}
