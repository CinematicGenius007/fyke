using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.UI.Core;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private ReaderSettings readerSettings = null!;
    private ReaderPreferences? preferences;
    private Control? focusBeforeSettings;
    private bool readingSettings;
    private readonly Dictionary<ComboBox, ReaderFontRole> weightPickers = [];

    private bool IsSettingsOpen => SettingsPane?.Visibility == Visibility.Visible;

    private void InitializeSettings()
    {
        readerSettings = new ReaderSettings(client);
        ReaderShell.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(SettingsKeyDown), true);
        Root.PreviewKeyDown += SettingsShortcutKeyDown;
        InitializeTextLayoutSettings();
        InitializeAppearance();
        InitializeWriters();
        InitializeStorage();
        SettingsTabs.SelectionChanged += SettingsTabChanged;
        SettingsTabs.SelectedItem = GeneralSettingsTab;

        weightPickers.Add(ReadingWeightPicker, ReaderFontRole.Reading);
        weightPickers.Add(TitleWeightPicker, ReaderFontRole.Title);
        weightPickers.Add(UiWeightPicker, ReaderFontRole.Ui);
        weightPickers.Add(CodeWeightPicker, ReaderFontRole.Code);
        string[] choices = ["Much lighter", "Lighter", "Normal", "Bolder", "Much bolder"];
        foreach (var picker in weightPickers.Keys)
        {
            picker.ItemsSource = choices;
        }
        ScrollbarsPicker.ItemsSource = new[] { "While scrolling", "Always", "Never" };
    }

    private void SettingsTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var reading = sender.SelectedItem == ReadingSettingsTab;
        var agents = sender.SelectedItem == AgentsSettingsTab;
        var storageTab = sender.SelectedItem == StorageSettingsTab;
        GeneralSettingsBody.Visibility = reading || agents || storageTab ? Visibility.Collapsed : Visibility.Visible;
        ReadingSettingsBody.Visibility = reading ? Visibility.Visible : Visibility.Collapsed;
        AgentsSettingsBody.Visibility = agents ? Visibility.Visible : Visibility.Collapsed;
        StorageSettingsBody.Visibility = storageTab ? Visibility.Visible : Visibility.Collapsed;
        _ = SettingsScroll.ChangeView(null, 0, null, disableAnimation: true);
        if (!reading)
        {
            FlushTextLayoutChanges();
        }

        if (agents && IsSettingsOpen)
        {
            _ = LoadWritersAsync();
        }

        if (storageTab && IsSettingsOpen)
        {
            ShowStorage();
        }
    }

    private void SettingsClicked(object sender, RoutedEventArgs args) => ToggleSettings();

    private void ToggleSettings()
    {
        if (IsSettingsOpen && !IsReaderOverlayOpen)
        {
            CloseSettings();
        }
        else
        {
            OpenSettings();
        }
    }

    private void OpenSettings()
    {
        if (!readerConnected || viewDialogOpen || !CloseAddFeed() || !CloseCatalogEdit())
        {
            return;
        }

        ClosePalette();
        CloseSearch();
        CloseRoutines(restoreFocus: false);
        if (!IsSettingsOpen)
        {
            focusBeforeSettings = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
            Destinations.IsItemClickEnabled = true;
            TimelinePane.Visibility = TimelineDivider.Visibility = ArticlePane.Visibility = Visibility.Collapsed;
            SettingsPane.Visibility = Visibility.Visible;
            _ = ReadSettingsAsync();
            if (SettingsTabs.SelectedItem == AgentsSettingsTab)
            {
                _ = LoadWritersAsync();
            }
            else if (SettingsTabs.SelectedItem == StorageSettingsTab)
            {
                ShowStorage();
            }
        }

        CloseSettingsButton.Focus(FocusState.Programmatic);
    }

    /// After a reconnect, Settings that stayed open reads everything again: a data move or a
    /// restarted daemon may have changed the folder, the settings or the writers.
    private void RefreshOpenSettings()
    {
        if (!IsSettingsOpen)
        {
            return;
        }

        _ = ReadSettingsAsync();
        if (SettingsTabs.SelectedItem == AgentsSettingsTab)
        {
            _ = LoadWritersAsync();
        }
        else if (SettingsTabs.SelectedItem == StorageSettingsTab)
        {
            ShowStorage();
        }
    }

    private void CloseSettingsClicked(object sender, RoutedEventArgs args) => CloseSettings();

    private void DestinationClicked(object sender, ItemClickEventArgs args)
    {
        if ((IsSettingsOpen || IsRoutinesShown) && args.ClickedItem is ReaderDestination item)
        {
            NavigateToDestination(item);
        }
    }

    private void CloseSettings(bool restoreFocus = true)
    {
        if (!IsSettingsOpen)
        {
            return;
        }

        SettingsPane.Visibility = Visibility.Collapsed;
        Destinations.IsItemClickEnabled = false;
        TimelinePane.Visibility = TimelineDivider.Visibility = ArticlePane.Visibility = Visibility.Visible;
        if (restoreFocus && focusBeforeSettings?.Focus(FocusState.Programmatic) != true)
        {
            SettingsButton.Focus(FocusState.Programmatic);
        }

        focusBeforeSettings = null;
        FlushTextLayoutChanges();
    }

    private void SettingsKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (IsSettingsOpen && !IsReaderOverlayOpen && args.Key == VirtualKey.Escape && !args.Handled)
        {
            args.Handled = true;
            CloseSettings();
        }
    }

    private void SettingsShortcutKeyDown(object sender, KeyRoutedEventArgs args)
    {
        // WinUI's KeyboardAccelerator can fail fast when it formats VK_OEM_COMMA.
        const VirtualKey comma = (VirtualKey)0xBC;
        if (!readerConnected || args.OriginalKey != comma || !IsDown(VirtualKey.Control)
            || IsDown(VirtualKey.Menu) || IsDown(VirtualKey.Shift))
        {
            return;
        }

        args.Handled = true;
        if (!args.KeyStatus.WasKeyDown)
        {
            ToggleSettings();
        }

        static bool IsDown(VirtualKey key) =>
            (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;
    }

    private async Task LoadInitialPreferencesAsync(CancellationToken ct)
    {
        try
        {
            var loaded = await readerSettings.ReadAsync(ct);
            ct.ThrowIfCancellationRequested();
            RestoreFolderDisclosure(loaded);
            if (!preferencesRead && !readingSettings)
            {
                ApplyPreferences(loaded);
            }
        }
        catch (Exception error) when (!ct.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            // The article still opens with local defaults if the profile is temporarily unavailable.
        }

        preferencesRead = true;
    }

    private void ApplyPreferences(ReaderPreferences loaded)
    {
        if (loaded.InvalidConfig && preferences is { } previous)
        {
            loaded = loaded with
            {
                LoadImages = previous.LoadImages, Typography = previous.Typography, TextLayout = previous.TextLayout,
                Scrollbars = previous.Scrollbars, Appearance = previous.Appearance, Themes = previous.Themes,
                ChosenFonts = previous.ChosenFonts, AgentTier = previous.AgentTier,
            };
        }

        if (preferences?.Scrollbars != loaded.Scrollbars)
        {
            ApplyScrollbarMode(loaded.Scrollbars);
        }

        preferences = loaded;
        ApplyAppearance(loaded);
        readerFonts.Apply(loaded.Typography);
        ApplyReaderTextLayout(loaded.TextLayout);
        articleRenderer.SetAutomaticImages(loaded.LoadImages);
        ApplySettingsControls(loaded);
    }

    private void ApplySettingsControls(ReaderPreferences loaded)
    {
        FullTextToggle.IsOn = loaded.FullText;
        LoadImagesToggle.IsOn = loaded.LoadImages;
        ApplyAppearanceControls(loaded);
        ApplyTextLayoutControls(loaded.TextLayout);
        ScrollbarsPicker.SelectedIndex = (int)loaded.Scrollbars;
        ApplyAgentControls(loaded);
        ApplyStorageControls(loaded);
        foreach (var (picker, role) in weightPickers)
        {
            picker.SelectedIndex = loaded.Typography.StepFor(role) + 2;
        }
    }

    private void EnableSettingsControls(bool enabled)
    {
        FullTextToggle.IsEnabled = LoadImagesToggle.IsEnabled = ScrollbarsPicker.IsEnabled = AgentTierPicker.IsEnabled = enabled;
        FollowSystemToggle.IsEnabled = ThemePicker.IsEnabled = DayThemePicker.IsEnabled = NightThemePicker.IsEnabled = enabled;
        foreach (var picker in weightPickers.Keys)
        {
            picker.IsEnabled = enabled;
        }
        foreach (var slider in textSliders.Keys)
        {
            slider.IsEnabled = enabled;
        }

        if (retentionPicker is not null)
        {
            retentionPicker.IsEnabled = enabled;
        }
    }

    private void ReloadSettingsClicked(object sender, RoutedEventArgs args) => _ = ReadSettingsAsync();

    private void GeneralSettingToggled(object sender, RoutedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || sender is not ToggleSwitch toggle
            || preferences is not { InvalidConfig: false } saved)
        {
            return;
        }

        var enabled = toggle.IsOn;
        if (toggle == FullTextToggle && saved.FullText != enabled)
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetFullTextAsync(enabled, ct), current => current.FullText == enabled);
        }
        else if (toggle == LoadImagesToggle && saved.LoadImages != enabled)
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetLoadImagesAsync(enabled, ct), current => current.LoadImages == enabled);
        }
    }

    private void FontWeightChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved
            || sender is not ComboBox { SelectedIndex: >= 0 } picker || !weightPickers.TryGetValue(picker, out var role))
        {
            return;
        }

        var step = picker.SelectedIndex - 2;
        if (step != saved.Typography.StepFor(role))
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetFontWeightAsync(role, step, ct),
                current => current.Typography.StepFor(role) == step);
        }
    }

    private void ScrollbarsChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved
            || sender is not ComboBox { SelectedIndex: >= 0 } picker)
        {
            return;
        }

        var mode = (ReaderScrollbarMode)picker.SelectedIndex;
        if (saved.Scrollbars != mode)
        {
            _ = ReadSettingsAsync(ct => readerSettings.SetScrollbarsAsync(mode, ct), current => current.Scrollbars == mode);
        }
    }

    private void ApplyScrollbarMode(ReaderScrollbarMode mode)
    {
        var visibility = mode switch
        {
            ReaderScrollbarMode.Always => ScrollBarVisibility.Visible,
            ReaderScrollbarMode.Never => ScrollBarVisibility.Hidden,
            _ => ScrollBarVisibility.Auto,
        };
        ArticleScroller.VerticalScrollBarVisibility = SettingsScroll.VerticalScrollBarVisibility = visibility;
        ScrollViewer.SetVerticalScrollBarVisibility(Destinations, visibility);
        ScrollViewer.SetVerticalScrollBarVisibility(Timeline, visibility);
        ScrollViewer.SetVerticalScrollBarVisibility(SearchResults, visibility);
        ScrollViewer.SetVerticalScrollBarVisibility(PaletteResults, visibility);
    }

    private async Task ReadSettingsAsync(Func<CancellationToken, Task>? save = null, Func<ReaderPreferences, bool>? confirmed = null)
    {
        if (readingSettings || !readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        readingSettings = true;
        var ct = lifetime.Token;
        var layoutChanges = pendingTextChanges;
        pendingTextChanges = [];
        textSaveTimer.Stop();
        var saving = save is not null || layoutChanges.Count > 0;
        try
        {
            if (saving)
            {
                // WinUI still uses the originating control until its selection event returns.
                await Task.Yield();
                if (!readerConnected || ct.IsCancellationRequested)
                {
                    return;
                }
            }

            EnableSettingsControls(false);
            ShowSettingsStatus(saving ? "Saving settings…" : "Loading settings…");
            if (layoutChanges.Count > 0)
            {
                await SaveSettingAsync(token => readerSettings.SetTextLayoutAsync(layoutChanges, token), ct);
            }
            if (save is not null)
            {
                await SaveSettingAsync(save, ct);
            }

            var loaded = await readerSettings.ReadAsync(ct);
            ct.ThrowIfCancellationRequested();
            ApplyPreferences(loaded);
            preferencesRead = true;
            var changeConfirmed = (confirmed?.Invoke(loaded) ?? true)
                && layoutChanges.All(change => loaded.TextLayout.Get(change.Key) == change.Value);
            ShowSettingsStatus(loaded.InvalidConfig ? "config.json has a mistake. Fyke is using the last available settings."
                : changeConfirmed ? null : "Fyke couldn’t save this setting. Check the current value and try again.",
                retry: loaded.InvalidConfig);
            EnableSettingsControls(!loaded.InvalidConfig);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (!ct.IsCancellationRequested)
            {
                if (preferences is { } saved)
                {
                    ApplyPreferences(saved);
                }

                ShowSettingsStatus("Fyke couldn’t confirm your settings. Try again.", retry: true);
            }
        }
        finally
        {
            readingSettings = false;
        }
    }

    private static async Task SaveSettingAsync(Func<CancellationToken, Task> save, CancellationToken ct)
    {
        try
        {
            await save(ct);
        }
        catch (Exception error) when (!ct.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            // A write can commit before its reply is lost. Read the stored value before offering another change.
        }
    }

    private void ShowSettingsStatus(string? message, bool retry = false)
    {
        SettingsStatus.Text = message ?? string.Empty;
        SettingsFeedback.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
        ReloadSettingsButton.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SettingsExportClicked(object sender, RoutedEventArgs args) => _ = ExportOpmlAsync();
}
