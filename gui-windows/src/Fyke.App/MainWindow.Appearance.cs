using Fyke.ViewModels;
using Microsoft.UI.System;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI.ViewManagement;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private UISettings systemAppearance = null!;
    private ThemeSettings windowThemeSettings = null!;

    private void InitializeAppearance()
    {
        systemAppearance = new UISettings();
        windowThemeSettings = ThemeSettings.CreateForWindowId(AppWindow.Id);
        systemAppearance.ColorValuesChanged += SystemColorsChanged;
        windowThemeSettings.Changed += WindowThemeChanged;
        string[] choices = ["Light", "Dark"];
        ThemePicker.ItemsSource = DayThemePicker.ItemsSource = NightThemePicker.ItemsSource = choices;
        ApplyAppearance(ReaderAppearance.Default);
    }

    private void SystemColorsChanged(UISettings sender, object args) => QueueAppearanceRefresh();

    private void WindowThemeChanged(ThemeSettings sender, object args) => QueueAppearanceRefresh();

    private void QueueAppearanceRefresh() => _ = DispatcherQueue.TryEnqueue(() =>
    {
        if (!lifetime.IsCancellationRequested)
        {
            ApplyAppearance(preferences?.Appearance ?? ReaderAppearance.Default);
        }
    });

    private void ApplyAppearance(ReaderAppearance appearance)
    {
        var highContrast = windowThemeSettings.HighContrast;
        var foreground = systemAppearance.GetColorValue(UIColorType.Foreground);
        // The default foreground is light when Windows uses dark app mode.
        var systemIsDark = (5 * foreground.G + 2 * foreground.R + foreground.B) > 8 * 128;
        var dark = appearance.ActiveTheme(systemIsDark) is "dark" or "terminal";
        Root.RequestedTheme = highContrast ? ElementTheme.Default : (dark ? ElementTheme.Dark : ElementTheme.Light);
        AppWindow.TitleBar.PreferredTheme = highContrast ? TitleBarTheme.UseDefaultAppMode
            : (dark ? TitleBarTheme.Dark : TitleBarTheme.Light);
    }

    private void ApplyAppearanceControls(ReaderAppearance appearance)
    {
        FollowSystemToggle.IsOn = appearance.FollowSystem;
        SystemThemeChoices.Visibility = appearance.FollowSystem ? Visibility.Visible : Visibility.Collapsed;
        SelectTheme(ThemePicker, appearance.Theme);
        SelectTheme(DayThemePicker, appearance.DayTheme);
        SelectTheme(NightThemePicker, appearance.NightTheme);
    }

    private static void SelectTheme(ComboBox picker, string theme)
    {
        picker.PlaceholderText = theme == "terminal" ? "Dark (fallback)" : "Light (fallback)";
        picker.SelectedIndex = theme switch { "light" => 0, "dark" => 1, _ => -1 };
    }

    private void FollowSystemChanged(object sender, RoutedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved)
        {
            return;
        }

        var follows = FollowSystemToggle.IsOn;
        if (follows != saved.Appearance.FollowSystem)
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetFollowSystemAsync(follows, ct),
                current => current.Appearance.FollowSystem == follows);
        }
    }

    private void AppearanceThemeChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved
            || sender is not ComboBox { SelectedIndex: >= 0 } picker)
        {
            return;
        }

        var slot = picker == DayThemePicker ? ReaderThemeSlot.Day
            : picker == NightThemePicker ? ReaderThemeSlot.Night : ReaderThemeSlot.Fixed;
        var theme = picker.SelectedIndex == 0 ? "light" : "dark";
        if (theme != saved.Appearance.ThemeFor(slot) || (slot == ReaderThemeSlot.Fixed && saved.Appearance.FollowSystem))
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetThemeAsync(slot, theme, ct),
                current => current.Appearance.ThemeFor(slot) == theme
                    && (slot != ReaderThemeSlot.Fixed || !current.Appearance.FollowSystem));
        }
    }
}
