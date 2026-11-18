using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private readonly ObservableCollection<TimelineArticle> articles = [];
    private readonly ObservableCollection<ReaderDestination> destinations = [];
    private readonly HashSet<long> collapsedFolders = [];
    private IReadOnlyList<ReaderDestination> catalog = [];
    private DispatcherQueueTimer readerReloadTimer = null!;
    private int readerChangesPending;
    private ReaderData reader = null!;
    private ReaderFontWeights readerFonts = null!;
    private bool typographyRead;
    private CancellationTokenSource? readerRequest;
    private CancellationTokenSource? articleRequest;
    private ArticleBlockRenderer articleRenderer = null!;
    private ReaderDestination? destination;
    private string? nextCursor;
    private bool readerConnected;
    private bool restoringDestination;
    private bool applyingTimeline;
    private bool articleInterrupted;
    private double requestedTimelineWidth = ReaderPaneLayout.DefaultTimeline;

    private void InitializeReader(FontFamily ui)
    {
        reader = new ReaderData(client);
        Timeline.ItemsSource = articles;
        Destinations.ItemsSource = destinations;
        readerReloadTimer = DispatcherQueue.CreateTimer();
        readerReloadTimer.Interval = TimeSpan.FromMilliseconds(250);
        readerReloadTimer.IsRepeating = false;
        readerReloadTimer.Tick += (_, _) => ReloadChangedReader();
        Destinations.FontFamily = ui;
        Timeline.FontFamily = ui;
        var resources = Application.Current.Resources;
        var reading = (FontFamily)resources["FontReading"];
        var code = (FontFamily)resources["FontCode"];
        readerFonts = (ReaderFontWeights)Root.Resources["ReaderFonts"];
        articleRenderer = new ArticleBlockRenderer(reading, ui, code, readerFonts, linkAction: DiscussionLinkAction);
        InitializeDiscussion(reading, ui, code);
        ShowArticle(null);
    }

    private void ShowReaderConnection()
    {
        var connected = ViewModel.IsConnected;
        ReaderShell.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
        if (readerConnected == connected)
        {
            return;
        }

        readerConnected = connected;
        if (connected)
        {
            _ = LoadReaderAsync(refreshCatalog: true);
        }
        else
        {
            readerReloadTimer.Stop();
            readerRequest?.Cancel();
            articleInterrupted |= articleRequest is not null;
            articleRequest?.Cancel();
        }
    }

    private void QueueReaderChange(DaemonEvent change)
    {
        // Gap events also cover replay after pruned or reset daemon history.
        if ((change.IsGap || change.Type.StartsWith("entry.", StringComparison.Ordinal)
            || change.Type.StartsWith("feed.", StringComparison.Ordinal)
            || change.Type.StartsWith("folder.", StringComparison.Ordinal))
            && Interlocked.Exchange(ref readerChangesPending, 1) == 0)
        {
            _ = DispatcherQueue.TryEnqueue(ScheduleReaderReload);
        }
    }

    private void ScheduleReaderReload()
    {
        if (readerConnected && !lifetime.IsCancellationRequested && readerRequest is null
            && Volatile.Read(ref readerChangesPending) != 0 && !readerReloadTimer.IsRunning)
        {
            readerReloadTimer.Start();
        }
    }

    private void ReloadChangedReader()
    {
        readerReloadTimer.Stop();
        if (readerConnected && !lifetime.IsCancellationRequested && readerRequest is null
            && Interlocked.Exchange(ref readerChangesPending, 0) != 0)
        {
            _ = LoadReaderAsync(refreshCatalog: true);
        }
    }

    private void ApplyVisibleDestinations()
    {
        var visible = ReaderRows.VisibleDestinations(catalog, collapsedFolders);
        restoringDestination = true;
        try
        {
            ReaderRows.Reconcile(destinations, visible, row => (row.Scope, row.Id));
            // A collapsed ancestor can hide the selection while its timeline stays active.
            var active = destination;
            var selected = destinations.FirstOrDefault(row => active is not null
                && row.Scope == active.Scope && row.Id == active.Id);
            if (!ReferenceEquals(Destinations.SelectedItem, selected))
            {
                Destinations.SelectedItem = selected;
            }
        }
        finally
        {
            restoringDestination = false;
        }
    }

    private void FolderDisclosureChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is Button button)
        {
            UpdateFolderDisclosure(button);
        }
    }

    private void FolderDisclosureLoaded(object sender, RoutedEventArgs args)
    {
        if (sender is Button button)
        {
            UpdateFolderDisclosure(button);
        }
    }

    private void FolderDisclosureClicked(object sender, RoutedEventArgs args)
    {
        if (sender is Button button && button.DataContext is ReaderDestination { Scope: ReaderScope.Folder } folder)
        {
            if (!collapsedFolders.Remove(folder.Id))
            {
                collapsedFolders.Add(folder.Id);
            }

            ApplyVisibleDestinations();
            UpdateFolderDisclosure(button);
        }
    }

    private void UpdateFolderDisclosure(Button button)
    {
        if (button.DataContext is not ReaderDestination { Scope: ReaderScope.Folder } folder)
        {
            button.Visibility = Visibility.Collapsed;
            return;
        }

        var collapsed = collapsedFolders.Contains(folder.Id);
        button.Visibility = Visibility.Visible;
        if (button.Content is FontIcon icon)
        {
            icon.Glyph = collapsed ? "\uE76C" : "\uE70D";
        }
        var name = collapsed ? $"Expand {folder.Title}" : $"Collapse {folder.Title}";
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
    }

    private void DestinationChanged(object sender, SelectionChangedEventArgs args)
    {
        if (restoringDestination || Destinations.SelectedItem is not ReaderDestination selected)
        {
            return;
        }

        destination = selected;
        applyingTimeline = true;
        try
        {
            articles.Clear();
        }
        finally
        {
            applyingTimeline = false;
        }
        articleInterrupted = false;
        nextCursor = null;
        MoreArticles.Visibility = Visibility.Collapsed;
        _ = OpenArticleAsync(null);
        _ = LoadReaderAsync();
    }

    private async Task LoadReaderAsync(bool refreshCatalog = false, bool append = false)
    {
        if (!readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        readerRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        readerRequest = request;
        var cursor = append ? nextCursor : null;
        var limit = append ? ReaderData.PageSize : Math.Max(ReaderData.PageSize, articles.Count);
        MoreArticles.IsEnabled = false;
        RetryTimeline.Visibility = Visibility.Collapsed;
        TimelineState.Visibility = articles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        TimelineMessage.Text = "Loading articles…";
        try
        {
            if (refreshCatalog)
            {
                if (!typographyRead)
                {
                    await LoadTypographyAsync(request.Token);
                }

                var rows = await reader.DestinationsAsync(request.Token);
                request.Token.ThrowIfCancellationRequested();
                var previous = destination;
                var current = rows.FirstOrDefault(row => previous is not null
                    && row.Scope == previous.Scope && row.Id == previous.Id) ?? rows[0];

                catalog = rows;
                destination = current;
                ApplyVisibleDestinations();
            }

            if (destination is null)
            {
                return;
            }

            TimelineHeading.Text = destination.Title;
            var page = await reader.TimelineAsync(destination, cursor, request.Token, limit);
            request.Token.ThrowIfCancellationRequested();
            if (append)
            {
                var ids = articles.Select(row => row.Id).ToHashSet();
                foreach (var article in page.Articles)
                {
                    if (ids.Add(article.Id))
                    {
                        articles.Add(article);
                    }
                }
            }
            else
            {
                ApplyTimeline(page.Articles);
            }

            nextCursor = page.NextCursor;
            MoreArticles.Visibility = nextCursor is null ? Visibility.Collapsed : Visibility.Visible;
            TimelineMessage.Text = "No articles here yet.";
            TimelineState.Visibility = articles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (!request.IsCancellationRequested)
            {
                TimelineMessage.Text = articles.Count == 0
                    ? "Fyke couldn’t load articles. Try again."
                    : "Fyke couldn’t update the list. The articles already loaded are still available.";
                TimelineState.Visibility = Visibility.Visible;
                RetryTimeline.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            if (ReferenceEquals(readerRequest, request))
            {
                readerRequest = null;
                MoreArticles.IsEnabled = true;
                ScheduleReaderReload();
            }
        }
    }

    private async Task LoadTypographyAsync(CancellationToken ct)
    {
        try
        {
            var typography = await reader.TypographyAsync(ct);
            ct.ThrowIfCancellationRequested();
            readerFonts.Apply(typography);
        }
        catch (Exception error) when (!ct.IsCancellationRequested && error is DaemonException or TimeoutException)
        {
            // Reading remains available with the built-in typography if settings are unavailable.
        }

        typographyRead = true;
    }

    private void RetryTimelineClicked(object sender, RoutedEventArgs args) => _ = LoadReaderAsync(refreshCatalog: true);

    private void MoreArticlesClicked(object sender, RoutedEventArgs args) => _ = LoadReaderAsync(append: true);

    private void ApplyTimeline(IReadOnlyList<TimelineArticle> updated)
    {
        var selected = Timeline.SelectedItem as TimelineArticle;
        applyingTimeline = true;
        try
        {
            ReaderRows.Reconcile(articles, updated, row => row.Id);
            if (selected is not null)
            {
                var current = articles.FirstOrDefault(row => row.Id == selected.Id);
                if (current is null)
                {
                    _ = OpenArticleAsync(null);
                }
                else if (!ReferenceEquals(Timeline.SelectedItem, current))
                {
                    Timeline.SelectedItem = current;
                }
            }
        }
        finally
        {
            applyingTimeline = false;
        }

        if (articleInterrupted && Timeline.SelectedItem is TimelineArticle interrupted)
        {
            articleInterrupted = false;
            _ = OpenArticleAsync(interrupted);
        }
    }

    private void ArticleChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!applyingTimeline)
        {
            articleInterrupted = false;
            _ = OpenArticleAsync(Timeline.SelectedItem as TimelineArticle);
        }
    }

    private void RetryArticleClicked(object sender, RoutedEventArgs args) =>
        _ = OpenArticleAsync(Timeline.SelectedItem as TimelineArticle);

    private async Task OpenArticleAsync(TimelineArticle? article)
    {
        articleRequest?.Cancel();
        ResetDiscussion();
        ShowArticle(article);
        ArticleBody.Children.Clear();
        ArticleStatus.Visibility = Visibility.Collapsed;
        RetryArticle.Visibility = Visibility.Collapsed;
        _ = ArticleScroller.ChangeView(null, 0, null, disableAnimation: true);
        if (article is null || lifetime.IsCancellationRequested || !readerConnected)
        {
            return;
        }

        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        articleRequest = request;
        ArticleStatus.Text = "Opening article…";
        ArticleStatus.Visibility = Visibility.Visible;
        try
        {
            var result = await reader.ArticleAsync(article.Id, request.Token);
            request.Token.ThrowIfCancellationRequested();
            ArticleHeading.Text = result.Title ?? article.Title;
            ArticleSource.Text = string.Join(" · ", new[] { result.FeedTitle ?? article.FeedTitle, result.Author }
                .Where(value => !string.IsNullOrWhiteSpace(value)));
            SetDiscussion(article.Id, result.Discussion);
            articleRenderer.Append(ArticleBody, result.Blocks);
            ArticleStatus.Text = "This article has no text.";
            ArticleStatus.Visibility = ArticleBody.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (!request.IsCancellationRequested)
            {
                ArticleStatus.Text = "Fyke couldn’t open this article. Your list is still available.";
                RetryArticle.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            if (ReferenceEquals(articleRequest, request))
            {
                articleRequest = null;
            }
        }
    }

    private void ShowArticle(TimelineArticle? article)
    {
        ArticleHeading.Text = article?.Title ?? "Select an article";
        ArticleSource.Text = article?.FeedTitle ?? string.Empty;
    }

    private void ApplyDestinationIndent(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is Grid row && args.NewValue is ReaderDestination item)
        {
            row.Padding = new Thickness(10 + 22 * item.Depth, 0, 8, 0);
        }
    }

    private void ReaderSizeChanged(object sender, SizeChangedEventArgs args) => SizeReader(args.NewSize.Width);

    private void TimelineDividerDragged(object sender, DragDeltaEventArgs args) => ResizeTimeline(args.HorizontalChange);

    private void TimelineDividerKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.Left or VirtualKey.Right)
        {
            ResizeTimeline(args.Key == VirtualKey.Left ? -16 : 16);
            args.Handled = true;
        }
    }

    private void ResizeTimeline(double delta)
    {
        requestedTimelineWidth = ReaderPaneLayout.Timeline(ReaderShell.ActualWidth, TimelineColumn.Width.Value + delta);
        SizeReader(ReaderShell.ActualWidth);
    }

    private void SizeReader(double width)
    {
        SidebarColumn.Width = new GridLength(ReaderPaneLayout.Sidebar(width));
        TimelineColumn.Width = new GridLength(ReaderPaneLayout.Timeline(width, requestedTimelineWidth));
    }
}
