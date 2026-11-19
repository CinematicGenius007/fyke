using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed record PaletteResult(string Key, string Title, string? Detail, string? Shortcut, Action Run);

public sealed partial class MainWindow
{
    private const int PaletteArticleLimit = 4;
    private readonly ObservableCollection<PaletteResult> paletteRows = [];
    private CancellationTokenSource? paletteRequest;
    private bool IsPaletteOpen => PaletteOverlay?.Visibility == Visibility.Visible;

    private void InitializePalette()
    {
        PaletteResults.ItemsSource = paletteRows;
        PaletteOverlay.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(PaletteKeyDown), true);
    }

    private void PaletteClicked(object sender, RoutedEventArgs args) => OpenPalette();

    private void PaletteShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected)
        {
            args.Handled = true;
            OpenPalette();
        }
    }

    private void OpenPalette()
    {
        if (!readerConnected || viewDialogOpen || !CloseAddFeed() || !CloseCatalogEdit())
        {
            return;
        }

        if (IsPaletteOpen)
        {
            PaletteQuery.Focus(FocusState.Programmatic);
            return;
        }

        CloseSearch();
        ShowReaderOverlay(PaletteOverlay, PaletteQuery);
        _ = RunPaletteQueryAsync();
    }

    private void PaletteBackdropPressed(object sender, PointerRoutedEventArgs args)
    {
        args.Handled = true;
        ClosePalette();
    }

    private void ClosePaletteClicked(object sender, RoutedEventArgs args) => ClosePalette();

    private void ClosePalette(bool restoreFocus = true)
    {
        if (!IsPaletteOpen)
        {
            return;
        }

        paletteRequest?.Cancel();
        HideReaderOverlay(PaletteOverlay, PaletteButton, restoreFocus);
        paletteRows.Clear();
        PaletteQuery.Text = string.Empty;
    }

    private void PaletteQueryChanged(object sender, TextChangedEventArgs args) => _ = RunPaletteQueryAsync();

    private async Task RunPaletteQueryAsync()
    {
        if (!IsPaletteOpen || lifetime.IsCancellationRequested)
        {
            return;
        }

        paletteRequest?.Cancel();
        var query = PaletteQuery.Text.Trim();
        var maximum = query.Length == 0 ? 8 : 5;
        var commands = MatchPaletteItems(PaletteDestinations(), query, maximum)
            .Concat(MatchPaletteItems(PaletteActions(), query, maximum)).ToArray();
        ShowPaletteItems(commands, query.Length >= 2 ? "Searching articles…" : "No matching commands.");
        if (query.Length < 2)
        {
            return;
        }

        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        paletteRequest = request;
        try
        {
            await Task.Delay(SearchTypingPause, request.Token);
            var articles = await reader.SearchAsync(query, unreadOnly: false, request.Token, PaletteArticleLimit);
            request.Token.ThrowIfCancellationRequested();
            var matches = articles.Select(hit => new PaletteResult($"article.{hit.Article.Id}", hit.Title,
                hit.FeedTitle is { } feed ? $"Article · {feed}" : "Article", null, () => OpenResultArticle(hit.Article)));
            ShowPaletteItems(commands.Concat(matches).ToArray(), "No matching commands or articles.", keepSelection: true);
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (!request.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            ShowPaletteItems(commands, "Fyke couldn’t search articles. Try changing the search.", keepSelection: true);
        }
        finally
        {
            if (ReferenceEquals(paletteRequest, request))
            {
                paletteRequest = null;
            }
        }
    }

    private static IEnumerable<PaletteResult> MatchPaletteItems(IEnumerable<PaletteResult> items, string query, int take) =>
        items.Select(item => (Item: item, Score: CommandMatch.Score(query, item.Title)))
            .Where(match => match.Score.HasValue)
            .OrderByDescending(match => match.Score)
            .Take(take)
            .Select(match => match.Item);

    private IEnumerable<PaletteResult> PaletteDestinations()
    {
        foreach (var item in catalog)
        {
            var detail = item.Scope switch
            {
                ReaderScope.Folder => "Folder",
                ReaderScope.Feed => "Feed",
                ReaderScope.View => "Saved view",
                _ => "Library",
            };
            yield return new PaletteResult($"destination.{item.Scope}.{item.Id}", item.Title, detail, null,
                () => OpenPaletteDestination(item.Scope, item.Id));
        }
    }

    private void OpenPaletteDestination(ReaderScope scope, long id)
    {
        var current = catalog.FirstOrDefault(item => item.Scope == scope && item.Id == id);
        if (current is not null)
        {
            NavigateToDestination(current);
            FocusTimeline();
        }
    }

    private IEnumerable<PaletteResult> PaletteActions()
    {
        yield return new("search", "Search articles", null, "Ctrl+F", OpenSearch);
        yield return new("add-feed", "Add feed", null, "Ctrl+N", () => OpenAddFeed());
        yield return new("settings", "Settings", null, "Ctrl+,", OpenSettings);
        yield return new("new-folder", "New folder", null, null, () => OpenCatalogEdit(CatalogEditKind.CreateFolder));
        yield return new("new-view", "New saved view", null, null, () => _ = OpenViewEditorAsync());
        if (destination is { Scope: ReaderScope.View } view)
        {
            yield return new("edit-view", $"Edit {view.Title}", null, null, () => _ = OpenViewEditorAsync(id: view.Id));
            yield return new("delete-view", $"Delete {view.Title}", null, null, () => _ = DeleteViewAsync(view));
        }
        if (!refreshingSubscriptions)
        {
            var feed = destination is { Scope: ReaderScope.Feed } currentFeed ? currentFeed : null;
            yield return new("refresh", feed is null ? "Refresh all feeds" : $"Refresh {feed.Title}", null, "R",
                () => _ = RefreshSubscriptionsAsync(feed));
        }

        if (destination is { Scope: ReaderScope.Feed or ReaderScope.Folder } editable)
        {
            yield return new("rename-destination", $"Rename {editable.Title}", null, null,
                () => OpenCatalogEdit(CatalogEditKind.Rename, editable));
            yield return new("move-destination", $"Move {editable.Title}", null, null,
                () => OpenCatalogEdit(CatalogEditKind.Move, editable));
            var removal = editable.Scope == ReaderScope.Folder ? "Delete" : "Remove";
            yield return new("remove-destination", $"{removal} {editable.Title}", null, null,
                () => OpenCatalogEdit(CatalogEditKind.Remove, editable));
        }
        if (CanChangeBulkMarks && destination is { Scope: not ReaderScope.Starred } selected)
        {
            yield return new("mark-all", $"Mark all read in {selected.Title}", null,
                "Ctrl+Shift+K", () => StartBulkMark(selected));
        }

        if (CanChangeBulkMarks && bulkUndo.Count > 0)
        {
            var change = bulkUndo[^1];
            yield return new("undo", $"Undo mark all read in {change.DestinationTitle}", null, "Ctrl+Z",
                () => StartBulkUndo());
        }

        if (articleReady && openArticle is { } article && !pendingMarks.Contains(article.Id))
        {
            yield return new("read", article.Read ? "Mark as unread" : "Mark as read", null, "M",
                () => ToggleArticleMark(VirtualKey.M));
            yield return new("star", article.Starred ? "Remove star" : "Star article", null, "S",
                () => ToggleArticleMark(VirtualKey.S));
        }

        if (discussionLink is { } link)
        {
            yield return new("discussion", link.HackerNewsItem is null ? "Open discussion" : "Show comments",
                null, "C", () => _ = OpenCurrentDiscussionAsync());
        }

        if (!transferringOpml)
        {
            yield return new("import-opml", "Import OPML", null, null, () => _ = ImportOpmlAsync());
            yield return new("export-opml", "Export OPML", null, null, () => _ = ExportOpmlAsync());
        }

        yield return new("focus-sidebar", "Focus sidebar", null, null, FocusSidebar);
        yield return new("focus-timeline", "Focus timeline", null, null, FocusTimeline);
        yield return new("focus-reader", "Focus reader", null, null, FocusArticle);
    }

    private void ShowPaletteItems(PaletteResult[] items, string status, bool keepSelection = false)
    {
        var previous = keepSelection ? (PaletteResults.SelectedItem as PaletteResult)?.Key : null;
        ReaderRows.Reconcile(paletteRows, items, item => item.Key);
        PaletteResults.Visibility = items.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PaletteStatus.Visibility = items.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        PaletteStatus.Text = status;
        if (items.Length > 0)
        {
            PaletteResults.SelectedIndex = Math.Max(0, Array.FindIndex(items, item => item.Key == previous));
        }
    }

    private void PaletteKeyDown(object sender, KeyRoutedEventArgs args) =>
        HandleOverlayKeys(args, PaletteQuery, PaletteResults, () => ClosePalette(), item => ExecutePaletteResult((PaletteResult)item));

    private void PaletteResultClicked(object sender, RoutedEventArgs args)
    {
        if (sender is Button { DataContext: PaletteResult result })
        {
            ExecutePaletteResult(result);
        }
    }

    private void ExecutePaletteResult(PaletteResult result)
    {
        ClosePalette();
        result.Run();
    }
}
