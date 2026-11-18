using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private readonly ObservableCollection<TimelineArticle> articles = [];
    private ReaderData reader = null!;
    private CancellationTokenSource? readerRequest;
    private CancellationTokenSource? articleRequest;
    private ArticleBlockRenderer articleRenderer = null!;
    private ReaderDestination? destination;
    private string? nextCursor;
    private bool readerConnected;
    private bool restoringDestination;
    private double requestedTimelineWidth = ReaderPaneLayout.DefaultTimeline;

    private void InitializeReader(FontFamily ui)
    {
        reader = new ReaderData(client);
        Timeline.ItemsSource = articles;
        Destinations.FontFamily = ui;
        Timeline.FontFamily = ui;
        var resources = Application.Current.Resources;
        var reading = (FontFamily)resources["FontReading"];
        ArticleHeading.FontFamily = reading;
        ArticleSource.FontFamily = ui;
        articleRenderer = new ArticleBlockRenderer(reading, ui, (FontFamily)resources["FontCode"]);
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
            readerRequest?.Cancel();
            articleRequest?.Cancel();
        }
    }

    private void DestinationChanged(object sender, SelectionChangedEventArgs args)
    {
        if (restoringDestination || Destinations.SelectedItem is not ReaderDestination selected)
        {
            return;
        }

        destination = selected;
        articles.Clear();
        ShowArticle(null);
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
        if (!append)
        {
            nextCursor = null;
            MoreArticles.Visibility = Visibility.Collapsed;
        }
        var selectedId = (Timeline.SelectedItem as TimelineArticle)?.Id;
        MoreArticles.IsEnabled = false;
        RetryTimeline.Visibility = Visibility.Collapsed;
        TimelineState.Visibility = articles.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        TimelineMessage.Text = "Loading articles…";
        try
        {
            if (refreshCatalog)
            {
                var rows = await reader.DestinationsAsync(request.Token);
                request.Token.ThrowIfCancellationRequested();
                var previous = destination;
                var current = rows.FirstOrDefault(row => previous is not null
                    && row.Scope == previous.Scope && row.Id == previous.Id) ?? rows[0];

                restoringDestination = true;
                try
                {
                    Destinations.ItemsSource = rows;
                    Destinations.SelectedItem = current;
                    destination = current;
                }
                finally
                {
                    restoringDestination = false;
                }
            }

            if (destination is null)
            {
                return;
            }

            TimelineHeading.Text = destination.Title;
            var page = await reader.TimelineAsync(destination, cursor, request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (!append)
            {
                articles.Clear();
            }

            foreach (var article in page.Articles)
            {
                articles.Add(article);
            }

            if (!append && selectedId is long id)
            {
                Timeline.SelectedItem = articles.FirstOrDefault(article => article.Id == id);
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
            }
        }
    }

    private void RetryTimelineClicked(object sender, RoutedEventArgs args) => _ = LoadReaderAsync(refreshCatalog: true);

    private void MoreArticlesClicked(object sender, RoutedEventArgs args) => _ = LoadReaderAsync(append: true);

    private void ArticleChanged(object sender, SelectionChangedEventArgs args) =>
        _ = OpenArticleAsync(Timeline.SelectedItem as TimelineArticle);

    private void RetryArticleClicked(object sender, RoutedEventArgs args) =>
        _ = OpenArticleAsync(Timeline.SelectedItem as TimelineArticle);

    private async Task OpenArticleAsync(TimelineArticle? article)
    {
        articleRequest?.Cancel();
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
