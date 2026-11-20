using Microsoft.UI.Xaml.Controls;

namespace Fyke.App;

/// <summary>
/// The Settings pane's view: General, Reading, Agents and Storage. Its controls are internal so
/// that <see cref="MainWindow"/>, which owns the settings state and the daemon client, fills them
/// and attaches their handlers (<c>MainWindow.WireSettingsPane</c>).
/// </summary>
public sealed partial class SettingsPane : UserControl
{
    public SettingsPane() => InitializeComponent();
}
