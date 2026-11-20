using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

/// <summary>
/// The Storage tab of Settings and the data move, as on macOS (gui/Sources/Reader/StoragePane.swift and
/// MoveDialog in Sidebar.swift). Sizes come from the daemon. A move runs <c>fyke data move</c>, which
/// stops the daemon, copies and checks the data, writes the location pointer and starts the daemon again.
/// </summary>
public sealed partial class MainWindow
{
    private enum MovePhase { Asking, Moving, Failed }

    private Storage storage = null!;
    private StorageUse? storageUse;
    private DateTimeOffset? storageCheckedAt;
    private CancellationTokenSource? storageRequest;
    private bool storageWorking;
    private string? storageConfirming;
    private readonly HashSet<string> storageOpenSections = ["articles"];
    private ComboBox? retentionPicker;
    private IReadOnlyList<RetentionChoice> retentionChoices = StorageText.RetentionChoices;
    private DataMovePlan? dataMove;
    private MovePhase dataMovePhase;

    private bool IsStorageShown => IsSettingsOpen && SettingsTabs.SelectedItem == StorageSettingsTab;

    private bool IsDataMoveOpen => DataMoveOverlay?.Visibility == Visibility.Visible;

    // FYKE_HOME names the folder for this run, so there is no default for a move to repoint.
    private static bool HomeOverridden => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("FYKE_HOME"));

    private void InitializeStorage() => storage = new Storage(client);

    private void ShowStorage()
    {
        ShowDataFolder();
        ChangeDataFolder.IsEnabled = !HomeOverridden;
        ToolTipService.SetToolTip(ChangeDataFolder, HomeOverridden ? StorageText.HomeOverridden : null);
        RenderStorage();
        _ = MeasureStorageAsync();
    }

    private void ShowDataFolder()
    {
        var user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var folder = client.DataFolder;
        DataFolderPath.Text = StorageText.Tilde(folder, user);
        SettingsFilePath.Text = StorageText.Tilde(Path.Combine(folder, "config.json"), user);
    }

    private async Task MeasureStorageAsync()
    {
        if (!readerConnected)
        {
            return;
        }

        storageRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        storageRequest = request;
        try
        {
            storageUse = await storage.GetAsync(request.Token);
            storageCheckedAt = DateTimeOffset.Now;
            ShowSettingsStatus(null);
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or System.Text.Json.JsonException)
        {
            ShowSettingsStatus($"Fyke couldn’t measure its disk use. {WriterText.Problem(error)}");
        }
        finally
        {
            if (storageRequest == request)
            {
                storageRequest = null;
            }
        }

        RenderStorage();
    }

    private void StorageRefreshClicked(object sender, RoutedEventArgs args) => _ = MeasureStorageAsync();

    private async Task FreeStorageAsync(Func<CancellationToken, Task<StorageFreed>> free)
    {
        storageConfirming = null;
        storageWorking = true;
        RenderStorage();
        try
        {
            await free(lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or System.Text.Json.JsonException)
        {
            ShowSettingsStatus($"Fyke couldn’t free up space. {WriterText.Problem(error)}");
        }
        finally
        {
            storageWorking = false;
        }

        await MeasureStorageAsync();
    }

    // ----- drawing -----

    private void RenderStorage()
    {
        StorageChecked.Text = storageCheckedAt is { } at ? StorageText.Checked(at, DateTimeOffset.Now) : string.Empty;
        StorageDetails.Children.Clear();
        retentionPicker = null;
        if (storageUse is not { } use)
        {
            StorageDetails.Children.Add(StorageLabel(StorageText.Measuring, 13, "BriefMuted"));
            return;
        }

        var total = new Grid();
        total.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        total.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        total.Children.Add(StorageLabel("Used in all", 13, "BriefInk"));
        var size = StorageLabel(StorageText.Size(use.TotalBytes), 13, "BriefInk", nameof(ReaderFontWeights.SectionLabel));
        Grid.SetColumn(size, 1);
        total.Children.Add(size);
        AutomationProperties.SetName(total, $"Used in all, {StorageText.Size(use.TotalBytes)}");
        StorageDetails.Children.Add(total);
        StorageDetails.Children.Add(StorageBar(
        [
            ("Articles and search", use.DatabaseBytes, "StorageInkSegment"),
            ("Feed copies", use.RawBytes, "StorageUnreadSegment"),
            ("Logs and settings", use.LogsAndSettingsBytes, "StorageSegment"),
        ], height: 6, legendSquares: true));

        var articles = new StackPanel { Spacing = 8 };
        articles.Children.Add(StorageBar(
        [
            ("Article text", use.Articles.TextBytes, "StorageInkSegment"),
            ("Search index", use.Articles.SearchBytes, "StorageSoftSegment"),
            ("Other", use.Articles.OtherBytes, "StorageSegment"),
        ], height: 4, legendSquares: false));
        articles.Children.Add(ArticleControls());
        if (storageConfirming == "articles")
        {
            articles.Children.Add(StorageConfirm(StorageText.FreeArticlesPrompt(use.Articles), storage.FreeArticlesAsync));
        }

        StorageDetails.Children.Add(StorageSection("articles", "Articles and search", use.DatabaseBytes,
            StorageText.ArticlesDetail(use.Articles), articles));

        var copies = new StackPanel { Spacing = 8 };
        copies.Children.Add(StorageLabel(StorageText.Copies(use.RawFiles), 13, "BriefMuted"));
        copies.Children.Add(FreeButton("copies", "Free up space from feed copies"));
        if (storageConfirming == "copies")
        {
            copies.Children.Add(StorageConfirm(StorageText.FreeCopiesPrompt, storage.FreeCopiesAsync));
        }

        StorageDetails.Children.Add(StorageSection("copies", "Feed copies", use.RawBytes, StorageText.CopiesDetail, copies));
        StorageDetails.Children.Add(StorageSection("logs", "Logs and settings", use.LogsAndSettingsBytes, StorageText.LogsDetail, null));
    }

    private Grid ArticleControls()
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(FreeButton("articles", "Free up space from articles"));
        var label = StorageLabel("Remove read articles after", 13, "BriefMuted");
        label.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(label, 1);
        row.Children.Add(label);

        var days = preferences?.RemoveReadAfterDays ?? 0;
        var choices = StorageText.RetentionChoicesWith(days);
        retentionChoices = choices;
        var labels = new List<string>(choices.Count);
        foreach (var choice in choices)
        {
            labels.Add(choice.Label);
        }

        var picker = new ComboBox
        {
            ItemsSource = labels,
            MinWidth = 120,
            MinHeight = 32,
            FontFamily = AppResources.FromApp<FontFamily>("FontUi"),
            IsEnabled = preferences is { InvalidConfig: false },
        };
        for (var index = 0; index < choices.Count; index++)
        {
            if (choices[index].Days == days)
            {
                picker.SelectedIndex = index;
            }
        }

        AutomationProperties.SetName(picker, "Remove read articles after");
        AutomationProperties.SetAutomationId(picker, "RetentionPicker");
        picker.SelectionChanged += RetentionChanged;
        Grid.SetColumn(picker, 2);
        row.Children.Add(picker);
        retentionPicker = picker;
        return row;
    }

    private void RetentionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (readingSettings || sender is not ComboBox { SelectedIndex: var index } || index < 0 || index >= retentionChoices.Count
            || preferences is not { InvalidConfig: false } saved || saved.RemoveReadAfterDays == retentionChoices[index].Days)
        {
            return;
        }

        var choice = retentionChoices[index];

        _ = ReadSettingsAsync(token => storage.SetRetentionAsync(choice.Days, token),
            loaded => loaded.RemoveReadAfterDays == choice.Days);
    }

    /// <summary>Puts the saved retention in the picker once settings are read.</summary>
    private void ApplyStorageControls(ReaderPreferences loaded)
    {
        if (retentionPicker is null || !IsStorageShown)
        {
            return;
        }

        if (retentionPicker.SelectedIndex is var shown && shown >= 0 && shown < retentionChoices.Count
            && retentionChoices[shown].Days == loaded.RemoveReadAfterDays)
        {
            return;
        }

        RenderStorage();
    }

    private Button FreeButton(string section, string name)
    {
        var button = new Button
        {
            Content = "Free up space…",
            IsEnabled = !storageWorking,
            Style = AppResources.FromApp<Style>("BriefSecondaryAction"),
            FontFamily = AppResources.FromApp<FontFamily>("FontUi"),
        };
        AutomationProperties.SetName(button, name);
        AutomationProperties.SetAutomationId(button, section == "articles" ? "FreeArticles" : "FreeCopies");
        button.Click += (_, _) =>
        {
            storageConfirming = section;
            RenderStorage();
        };
        return button;
    }

    private Border StorageConfirm(string text, Func<CancellationToken, Task<StorageFreed>> free)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var words = StorageLabel(text, 13, "BriefSoft");
        words.TextWrapping = TextWrapping.Wrap;
        words.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(words);
        var cancel = new Button { Content = "Cancel", Style = AppResources.FromApp<Style>("BriefSecondaryAction"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(cancel, "StorageConfirmCancel");
        cancel.Click += (_, _) =>
        {
            storageConfirming = null;
            RenderStorage();
        };
        Grid.SetColumn(cancel, 1);
        row.Children.Add(cancel);
        var confirm = new Button { Content = "Free up space", Style = AppResources.FromApp<Style>("BriefPrimaryAction"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAutomationId(confirm, "StorageConfirm");
        confirm.Click += (_, _) => _ = FreeStorageAsync(free);
        Grid.SetColumn(confirm, 2);
        row.Children.Add(confirm);
        var border = new Border { Child = row, Style = AppResources.FromApp<Style>("StorageConfirm") };
        // The question opens under its button, which can be the foot of the page, so it scrolls into view.
        border.Loaded += (_, _) => border.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        return border;
    }

    private StackPanel StorageSection(string id, string title, long bytes, string detail, UIElement? details)
    {
        var section = new StackPanel { Spacing = 6, Margin = new Thickness(0, 6, 0, 0) };
        section.Children.Add(new Border { Height = 1, Margin = new Thickness(0, 0, 0, 6), Style = AppResources.FromApp<Style>("SettingsHairline") });
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = StorageLabel(title, 13, "BriefInk");
        AutomationProperties.SetHeadingLevel(name, AutomationHeadingLevel.Level3);
        heading.Children.Add(name);
        var size = StorageLabel(StorageText.Size(bytes), 13, "BriefInk");
        Grid.SetColumn(size, 1);
        heading.Children.Add(size);
        AutomationProperties.SetName(heading, $"{title}, {StorageText.Size(bytes)}");
        section.Children.Add(heading);
        var words = StorageLabel(detail, 12, "BriefMuted");
        words.TextWrapping = TextWrapping.Wrap;
        section.Children.Add(words);
        if (details is null)
        {
            return section;
        }

        var open = storageOpenSections.Contains(id);
        var toggle = new Button { Style = AppResources.FromApp<Style>("BriefPlainButton"), HorizontalAlignment = HorizontalAlignment.Left, Height = 22 };
        var toggleContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        toggleContent.Children.Add(new FontIcon
        {
            Glyph = open ? "\uE70D" : "\uE76C",
            FontSize = 10,
            Foreground = AppResources.FromApp<Brush>("MutedBrush"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        toggleContent.Children.Add(StorageLabel("Details", 13, "BriefSoft"));
        toggle.Content = toggleContent;
        AutomationProperties.SetName(toggle, $"{title} details");
        AutomationProperties.SetAutomationId(toggle, $"StorageDetails_{id}");
        toggle.Click += (_, _) =>
        {
            if (!storageOpenSections.Remove(id))
            {
                storageOpenSections.Add(id);
            }

            RenderStorage();
        };
        section.Children.Add(toggle);
        if (open)
        {
            section.Children.Add(details);
        }

        return section;
    }

    /// <summary>One bar split by size, with a legend under it.</summary>
    private StackPanel StorageBar(IReadOnlyList<(string Label, long Bytes, string Style)> segments, double height, bool legendSquares)
    {
        var sum = 0L;
        foreach (var segment in segments)
        {
            sum += segment.Bytes;
        }

        var bar = new Grid { ColumnSpacing = 2, Height = height };
        var legend = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18 };
        for (var index = 0; index < segments.Count; index++)
        {
            var (label, bytes, style) = segments[index];
            // Every kind keeps a sliver, as on macOS, so the legend always has a mark in the bar.
            var weight = Math.Max(bytes, Math.Max(sum, 1) / 200.0);
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(weight, GridUnitType.Star) });
            var piece = new Border { Style = AppResources.FromApp<Style>(style), CornerRadius = new CornerRadius(height / 2) };
            Grid.SetColumn(piece, index);
            bar.Children.Add(piece);

            var key = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            if (legendSquares)
            {
                key.Children.Add(new Border
                {
                    Width = 9,
                    Height = 9,
                    CornerRadius = new CornerRadius(2),
                    VerticalAlignment = VerticalAlignment.Center,
                    Style = AppResources.FromApp<Style>(style),
                });
            }

            key.Children.Add(StorageLabel($"{label}  {StorageText.Size(bytes)}", 12, "BriefMuted"));
            legend.Children.Add(key);
        }

        AutomationProperties.SetAccessibilityView(bar, AccessibilityView.Raw);
        var panel = new StackPanel { Spacing = 10, Margin = new Thickness(0, 0, 0, 6) };
        panel.Children.Add(bar);
        panel.Children.Add(legend);
        return panel;
    }

    private TextBlock StorageLabel(string text, double size, string style, string weight = nameof(ReaderFontWeights.Ui))
    {
        var label = briefRenderer.Label(text, size, style, weight);
        label.VerticalAlignment = VerticalAlignment.Center;
        return label;
    }

    // ----- opening files -----

    private void OpenDataFolderClicked(object sender, RoutedEventArgs args) => OpenInShell(client.DataFolder);

    private void OpenSettingsFileClicked(object sender, RoutedEventArgs args) =>
        OpenInShell(Path.Combine(client.DataFolder, "config.json"));

    /// <summary>Opens a folder in File Explorer, or a file in the app Windows uses for it.</summary>
    private void OpenInShell(string path)
    {
        if (string.IsNullOrEmpty(path) || (!Directory.Exists(path) && !File.Exists(path)))
        {
            ShowSettingsStatus($"{path} is not there.");
            return;
        }

        try
        {
            using var opened = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            ShowSettingsStatus($"Windows couldn’t open {path}. {error.Message}");
        }
    }

    // ----- moving the data folder -----

    private async void ChangeDataFolderClicked(object sender, RoutedEventArgs args)
    {
        if (HomeOverridden || IsDataMoveOpen)
        {
            return;
        }

        var picker = new FolderPicker(AppWindow.Id) { CommitButtonText = "Choose" };
        PickFolderResult? picked;
        try
        {
            picked = await picker.PickSingleFolderAsync();
        }
        catch (Exception error) when (error is UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            ShowSettingsStatus($"Windows couldn’t open the folder picker. {error.Message}");
            return;
        }

        if (picked is null || string.IsNullOrEmpty(picked.Path) || lifetime.IsCancellationRequested || !readerConnected)
        {
            return;
        }

        var target = DataMoves.Target(picked.Path, out var problem);
        if (target is null)
        {
            ShowSettingsStatus(problem);
            return;
        }

        StorageUse? use = storageUse;
        try
        {
            use = await storage.GetAsync(lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or System.Text.Json.JsonException)
        {
            // The last measure, or nothing, still lets the move ask; the command checks the space itself.
        }
        catch (OperationCanceledException)
        {
            return;
        }

        var bytes = use?.TotalBytes ?? 0;
        var warning = DataMoves.Warn(DataMoves.Drive(client.DataFolder), DataMoves.Drive(target), bytes);
        dataMove = new DataMovePlan(target, bytes, warning);
        dataMovePhase = MovePhase.Asking;
        RenderDataMove();
        ShowReaderOverlay(DataMoveOverlay, warning == DataMoveWarning.NoSpace ? DataMoveCancel : DataMoveConfirm);
    }

    private void RenderDataMove(string? text = null)
    {
        if (dataMove is not { } plan)
        {
            return;
        }

        DataMoveHeading.Text = dataMovePhase == MovePhase.Moving ? "Moving your data" : "Move your data?";
        DataMoveText.Inlines.Clear();
        if (dataMovePhase == MovePhase.Asking)
        {
            var user = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            DataMoveText.Inlines.Add(new Run { Text = DataMoves.Summary(plan) });
            DataMoveText.Inlines.Add(new Run
            {
                Text = StorageText.Tilde(plan.Target, user),
                FontFamily = AppResources.FromApp<FontFamily>("FontCode"),
                FontSize = 13,
                Foreground = AppResources.FromApp<Brush>("InkBrush"),
            });
            DataMoveText.Inlines.Add(new Run { Text = DataMoves.SummaryEnd });
        }
        else
        {
            DataMoveText.Inlines.Add(new Run { Text = text ?? string.Empty });
        }

        AutomationProperties.SetName(DataMoveText, dataMovePhase == MovePhase.Asking
            ? DataMoves.Summary(plan) + plan.Target + DataMoves.SummaryEnd
            : text ?? string.Empty);
        var warning = dataMovePhase == MovePhase.Asking ? DataMoves.WarningText(plan.Warning) : string.Empty;
        DataMoveWarningText.Text = warning;
        DataMoveWarningRow.Visibility = warning.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        DataMoveButtons.Visibility = dataMovePhase == MovePhase.Moving ? Visibility.Collapsed : Visibility.Visible;
        DataMoveConfirm.Visibility = dataMovePhase == MovePhase.Asking ? Visibility.Visible : Visibility.Collapsed;
        DataMoveConfirm.IsEnabled = plan.CanMove;
        DataMoveCancel.Content = dataMovePhase == MovePhase.Failed ? "Close" : "Cancel";
    }

    private async void DataMoveConfirmClicked(object sender, RoutedEventArgs args)
    {
        if (dataMove is not { CanMove: true } plan || dataMovePhase != MovePhase.Asking)
        {
            return;
        }

        dataMovePhase = MovePhase.Moving;
        RenderDataMove("Stopping…");
        DataMoveOverlay.Focus(FocusState.Programmatic);
        DataMoves.Outcome outcome;
        try
        {
            // While the command stops the daemon and starts it again, the client must not start one
            // in the old folder. Afterwards it finds the folder again through the new location pointer.
            using (await client.PauseAsync(lifetime.Token))
            {
                var queue = DispatcherQueue;
                outcome = await DataMoves.RunAsync(McpProgram(), plan.Target,
                    stage => queue.TryEnqueue(() =>
                    {
                        if (dataMovePhase == MovePhase.Moving)
                        {
                            RenderDataMove(stage);
                        }
                    }),
                    lifetime.Token);
            }
        }
        catch (OperationCanceledException)
        {
            return; // The window closed.
        }

        if (outcome.Succeeded)
        {
            dataMovePhase = MovePhase.Asking;
            CloseDataMove(restoreFocus: true);
            storageUse = null;
            if (IsStorageShown)
            {
                ShowDataFolder();
            }

            return;
        }

        dataMovePhase = MovePhase.Failed;
        RenderDataMove(DataMoves.Failure(outcome.Output, outcome.Errors));
        DataMoveCancel.Focus(FocusState.Programmatic);
    }

    private void DataMoveCancelClicked(object sender, RoutedEventArgs args) => CloseDataMove(restoreFocus: true);

    private void DataMoveKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            CloseDataMove(restoreFocus: true);
        }
    }

    private void CloseDataMove(bool restoreFocus)
    {
        // A move that has started finishes; the dialog stays to say how it ended.
        if (!IsDataMoveOpen || dataMovePhase == MovePhase.Moving)
        {
            return;
        }

        dataMove = null;
        HideReaderOverlay(DataMoveOverlay, ChangeDataFolder, restoreFocus && IsSettingsOpen);
    }
}
