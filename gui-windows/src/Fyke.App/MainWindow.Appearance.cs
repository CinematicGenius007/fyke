using System.Collections.Generic;
using System.Linq;
using Fyke.ViewModels;
using Microsoft.UI;
using Microsoft.UI.System;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private UISettings systemAppearance = null!;
    private ThemeSettings windowThemeSettings = null!;
    // The Light and Dark dictionaries of Themes/Tokens.xaml.
    private IDictionary<object, object> tokenThemes = null!;
    // The theme ids the pickers list, in their order: the built-ins, then the user's.
    private string[] themeIds = [];
    private string[] themeNames = [];

    private void InitializeAppearance()
    {
        systemAppearance = new UISettings();
        windowThemeSettings = ThemeSettings.CreateForWindowId(AppWindow.Id);
        systemAppearance.ColorValuesChanged += SystemColorsChanged;
        windowThemeSettings.Changed += WindowThemeChanged;
        tokenThemes = Application.Current.Resources.MergedDictionaries.First(dictionary =>
            dictionary.ThemeDictionaries.TryGetValue("Light", out var light)
            && light is ResourceDictionary tokens && tokens.ContainsKey("GroundBrush")).ThemeDictionaries;
        ListThemes([]);
        ApplyAppearance(null);
    }

    private void ListThemes(IReadOnlyList<ReaderCustomTheme> themes)
    {
        var ids = ReaderPalette.BuiltIns.Concat(themes.Select(theme => theme.Id)).ToArray();
        var names = ids.Select(id => ReaderPalette.DisplayName(id, themes)).ToArray();
        if (ids.SequenceEqual(themeIds) && names.SequenceEqual(themeNames))
        {
            return;
        }

        themeIds = ids;
        themeNames = names;
        ThemePicker.ItemsSource = DayThemePicker.ItemsSource = NightThemePicker.ItemsSource = names;
    }

    private void SystemColorsChanged(UISettings sender, object args) => QueueAppearanceRefresh();

    private void WindowThemeChanged(ThemeSettings sender, object args) => QueueAppearanceRefresh();

    private void QueueAppearanceRefresh() => _ = DispatcherQueue.TryEnqueue(() =>
    {
        if (!lifetime.IsCancellationRequested)
        {
            ApplyAppearance(preferences);
        }
    });

    private void ApplyAppearance(ReaderPreferences? saved)
    {
        var highContrast = windowThemeSettings.HighContrast;
        var foreground = systemAppearance.GetColorValue(UIColorType.Foreground);
        // The default foreground is light when Windows uses dark app mode.
        var systemIsDark = (5 * foreground.G + 2 * foreground.R + foreground.B) > 8 * 128;
        var palette = saved?.Palette(systemIsDark) ?? (systemIsDark ? ReaderPalette.Dark : ReaderPalette.Light);
        if (!highContrast)
        {
            Paint(palette);
        }

        var theme = highContrast ? ElementTheme.Default : (palette.IsDark ? ElementTheme.Dark : ElementTheme.Light);
        if (ApplyLook(saved?.Look(systemIsDark) ?? ReaderLook.Default))
        {
            // ThemeResource values resolve again only when the theme changes, so pass through
            // the other one for the new fonts and radii to reach every control.
            Root.RequestedTheme = theme == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark;
        }

        Root.RequestedTheme = theme;
        AppWindow.TitleBar.PreferredTheme = highContrast ? TitleBarTheme.UseDefaultAppMode
            : (palette.IsDark ? TitleBarTheme.Dark : TitleBarTheme.Light);
    }

    /// <summary>Puts a theme's colours into the token brushes of its light or dark dictionary.</summary>
    /// <remarks>Every control shares those brush objects through ThemeResource, so changing a brush's
    /// colour repaints the window without rebuilding it. Newsprint and the user's light themes use the
    /// Light dictionary; Terminal and dark themes use Dark.</remarks>
    private void Paint(ReaderPalette palette)
    {
        var dictionary = Theme(palette.IsDark ? "Dark" : "Light");
        foreach (var (token, rgba) in palette.Colors)
        {
            var color = ColorHelper.FromArgb((byte)rgba, (byte)(rgba >> 24), (byte)(rgba >> 16), (byte)(rgba >> 8));
            if (dictionary[token + "Brush"] is SolidColorBrush brush && brush.Color != color)
            {
                brush.Color = color;
            }
        }
    }

    /// <summary>Puts a theme's typefaces and corner radii into both token dictionaries.</summary>
    /// <remarks>Unlike colours, each theme sets its own fonts, so both dictionaries hold the
    /// active theme's. Elements built in code follow through their binding to
    /// <see cref="ReaderFaces"/>. False when nothing changed.</remarks>
    private bool ApplyLook(ReaderLook look)
    {
        var faces = ReaderFaces.Shared;
        if (!faces.Apply(look))
        {
            return false;
        }

        faces.WriteTo(Theme("Light"));
        faces.WriteTo(Theme("Dark"));
        return true;
    }

    // The Light or Dark dictionary of Themes/Tokens.xaml.
    private ResourceDictionary Theme(string name) =>
        tokenThemes.TryGetValue(name, out var value) && value is ResourceDictionary dictionary
            ? dictionary
            : throw new InvalidOperationException(
                $"The {name} token dictionary is {value?.GetType().FullName ?? "missing"}, not a ResourceDictionary.");

    private void ApplyAppearanceControls(ReaderPreferences saved)
    {
        var appearance = saved.Appearance;
        ListThemes(saved.Themes);
        FollowSystemToggle.IsOn = appearance.FollowSystem;
        SystemThemeChoices.Visibility = appearance.FollowSystem ? Visibility.Visible : Visibility.Collapsed;
        SelectTheme(ThemePicker, appearance.Theme);
        SelectTheme(DayThemePicker, appearance.DayTheme);
        SelectTheme(NightThemePicker, appearance.NightTheme);
    }

    // A theme deleted since it was chosen shows as Light, which is what is on screen.
    private void SelectTheme(ComboBox picker, string theme)
    {
        var index = IndexOf(theme);
        picker.SelectedIndex = index >= 0 ? index : IndexOf("light");

        int IndexOf(string id)
        {
            for (var i = 0; i < themeIds.Length; i++)
            {
                if (themeIds[i] == id)
                {
                    return i;
                }
            }

            return -1;
        }
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
        var theme = themeIds[picker.SelectedIndex];
        if (theme != saved.Appearance.ThemeFor(slot) || (slot == ReaderThemeSlot.Fixed && saved.Appearance.FollowSystem))
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetThemeAsync(slot, theme, ct),
                current => current.Appearance.ThemeFor(slot) == theme
                    && (slot != ReaderThemeSlot.Fixed || !current.Appearance.FollowSystem));
        }
    }
}
