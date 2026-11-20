namespace Fyke.ViewModels;

/// <summary>
/// The sidebar's indent, from docs/design-rules.md: 10 + 22 × depth, where 22 is the icon
/// (14) plus the gap (8). Every row draws an icon column (a folder's holds its chevron), so a
/// child's icon starts where its parent's text starts, and its text one step further in.
/// </summary>
public static class SidebarIndent
{
    public const double Edge = 10;
    public const double Icon = 14;
    public const double Gap = 8;
    public const double Step = Icon + Gap;

    /// <summary>Where a row at <paramref name="depth"/> starts its icon column.</summary>
    public static double Leading(int depth) => Edge + Step * Math.Max(depth, 0);

    /// <summary>Where a row at <paramref name="depth"/> starts its text.</summary>
    public static double TextStart(int depth) => Leading(depth) + Step;
}
