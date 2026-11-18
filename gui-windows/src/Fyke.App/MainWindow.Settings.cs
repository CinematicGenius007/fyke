using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private ReaderSettings readerSettings = null!;
    private ReaderPreferences? preferences;
    private Control? focusBeforeSettings;
    private bool readingSettings;

    private bool IsSettingsOpen => SettingsPane?.Visibility == Visibility.Visible;

    private void InitializeSettings()
    {
        readerSettings = new ReaderSettings(client);
        ReaderShell.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(SettingsKeyDown), true);
        var shortcut = new KeyboardAccelerator
        {
            Key = (VirtualKey)0xBC, // VK_OEM_COMMA is absent from the WinRT enum.
            Modifiers = VirtualKeyModifiers.Control,
        };
        shortcut.Invoked += (_, args) =>
        {
            if (readerConnected)
            {
                args.Handled = true;
                ToggleSettings();
            }
        };
        ReaderShell.KeyboardAccelerators.Add(shortcut);

        SettingsShortcutRows.ColumnDefinitions.Add(new ColumnDefinition());
        SettingsShortcutRows.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        (string Action, string Shortcut)[] shortcuts =
        [
            ("Command palette", "Ctrl+K"), ("Search articles", "Ctrl+F"), ("Add feed", "Ctrl+N"),
            ("Settings", "Ctrl+,"), ("Move between panes", "F6 / Shift+F6"), ("Refresh feeds", "R"),
            ("Mark read or unread", "M"), ("Star or unstar article", "S"), ("Show discussion", "C"),
            ("Mark all read", "Ctrl+Shift+K"), ("Undo mark all read", "Ctrl+Z"), ("Close panel", "Esc"),
        ];
        foreach (var (action, key) in shortcuts)
        {
            var row = SettingsShortcutRows.RowDefinitions.Count;
            SettingsShortcutRows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = action, Style = (Style)SettingsPane.Resources["SettingsLabel"] };
            var keys = new TextBlock { Text = key, HorizontalAlignment = HorizontalAlignment.Right,
                Style = (Style)SettingsPane.Resources["SettingsDetail"] };
            Grid.SetRow(label, row);
            Grid.SetRow(keys, row);
            Grid.SetColumn(keys, 1);
            SettingsShortcutRows.Children.Add(label);
            SettingsShortcutRows.Children.Add(keys);
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
        if (!readerConnected || !CloseAddFeed() || !CloseCatalogEdit())
        {
            return;
        }

        ClosePalette();
        CloseSearch();
        if (!IsSettingsOpen)
        {
            focusBeforeSettings = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
            Destinations.IsItemClickEnabled = true;
            TimelinePane.Visibility = TimelineDivider.Visibility = ArticlePane.Visibility = Visibility.Collapsed;
            SettingsPane.Visibility = Visibility.Visible;
            _ = ReadGeneralSettingsAsync();
        }

        CloseSettingsButton.Focus(FocusState.Programmatic);
    }

    private void CloseSettingsClicked(object sender, RoutedEventArgs args) => CloseSettings();

    private void DestinationClicked(object sender, ItemClickEventArgs args)
    {
        if (IsSettingsOpen && args.ClickedItem is ReaderDestination item)
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
    }

    private void SettingsKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (IsSettingsOpen && !IsReaderOverlayOpen && args.Key == VirtualKey.Escape && !args.Handled)
        {
            args.Handled = true;
            CloseSettings();
        }
    }

    private async Task LoadInitialPreferencesAsync(CancellationToken ct)
    {
        try
        {
            var loaded = await readerSettings.ReadAsync(ct);
            ct.ThrowIfCancellationRequested();
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
            loaded = loaded with { LoadImages = previous.LoadImages, Typography = previous.Typography };
        }

        preferences = loaded;
        readerFonts.Apply(loaded.Typography);
        articleRenderer.SetAutomaticImages(loaded.LoadImages);
        FullTextToggle.IsOn = loaded.FullText;
        LoadImagesToggle.IsOn = loaded.LoadImages;
    }

    private void ReloadSettingsClicked(object sender, RoutedEventArgs args) => _ = ReadGeneralSettingsAsync();

    private void GeneralSettingToggled(object sender, RoutedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved)
        {
            return;
        }

        if (sender == FullTextToggle && saved.FullText != FullTextToggle.IsOn)
        {
            _ = ReadGeneralSettingsAsync(fullText: FullTextToggle.IsOn);
        }
        else if (sender == LoadImagesToggle && saved.LoadImages != LoadImagesToggle.IsOn)
        {
            _ = ReadGeneralSettingsAsync(loadImages: LoadImagesToggle.IsOn);
        }
    }

    private async Task ReadGeneralSettingsAsync(bool? fullText = null, bool? loadImages = null)
    {
        if (readingSettings || !readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        readingSettings = true;
        var ct = lifetime.Token;
        var saving = fullText.HasValue || loadImages.HasValue;
        FullTextToggle.IsEnabled = LoadImagesToggle.IsEnabled = false;
        ShowSettingsStatus(saving ? "Saving setting…" : "Loading settings…");
        try
        {
            await SaveGeneralPreferenceAsync(fullText, loadImages, ct);
            var loaded = await readerSettings.ReadAsync(ct);
            ct.ThrowIfCancellationRequested();
            ApplyPreferences(loaded);
            preferencesRead = true;
            var changeConfirmed = (!fullText.HasValue || loaded.FullText == fullText)
                && (!loadImages.HasValue || loaded.LoadImages == loadImages);
            ShowSettingsStatus(loaded.InvalidConfig ? "config.json has a mistake. Fyke is using the last available settings."
                : changeConfirmed ? null : "Fyke couldn’t save this setting. Check the current value and try again.",
                retry: loaded.InvalidConfig);
            FullTextToggle.IsEnabled = LoadImagesToggle.IsEnabled = !loaded.InvalidConfig;
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
                    FullTextToggle.IsOn = saved.FullText;
                    LoadImagesToggle.IsOn = saved.LoadImages;
                }

                ShowSettingsStatus("Fyke couldn’t confirm your settings. Try again.", retry: true);
            }
        }
        finally
        {
            readingSettings = false;
        }
    }

    private async Task SaveGeneralPreferenceAsync(bool? fullText, bool? loadImages, CancellationToken ct)
    {
        try
        {
            if (fullText is bool full)
            {
                await readerSettings.SetFullTextAsync(full, ct);
            }
            else if (loadImages is bool images)
            {
                await readerSettings.SetLoadImagesAsync(images, ct);
            }
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
