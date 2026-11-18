using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private static readonly TimeSpan SearchTypingPause = TimeSpan.FromMilliseconds(150);
    private CancellationTokenSource? searchRequest;
    private Control? focusBeforeSearch;
    private bool IsSearchOpen => SearchOverlay?.Visibility == Visibility.Visible;

    private void InitializeSearch()
    {
        // TextBox can consume navigation keys before they bubble to the panel.
        SearchOverlay.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(SearchKeyDown), true);
    }

    private void SearchClicked(object sender, RoutedEventArgs args) => OpenSearch();

    private void SearchShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected)
        {
            args.Handled = true;
            OpenSearch();
        }
    }

    private void OpenSearch()
    {
        if (!readerConnected)
        {
            return;
        }

        if (!IsSearchOpen)
        {
            focusBeforeSearch = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
            ReaderShell.IsHitTestVisible = false;
            ShowSearchMessage("Find words in titles, article text, and feed names.");
            SearchOverlay.Visibility = Visibility.Visible;
        }

        SearchQuery.Focus(FocusState.Programmatic);
    }

    private void SearchBackdropPressed(object sender, PointerRoutedEventArgs args)
    {
        args.Handled = true;
        CloseSearch();
    }

    private void CloseSearchClicked(object sender, RoutedEventArgs args) => CloseSearch();

    private void CloseSearch(bool restoreFocus = true)
    {
        if (!IsSearchOpen)
        {
            return;
        }

        searchRequest?.Cancel();
        SearchOverlay.Visibility = Visibility.Collapsed;
        SearchResults.ItemsSource = null;
        SearchQuery.Text = string.Empty;
        ReaderShell.IsHitTestVisible = true;
        if (restoreFocus && focusBeforeSearch?.Focus(FocusState.Programmatic) != true)
        {
            SearchButton.Focus(FocusState.Programmatic);
        }

        focusBeforeSearch = null;
    }

    private void SearchQueryChanged(object sender, TextChangedEventArgs args) => _ = RunSearchAsync(debounce: true);

    private void SearchUnreadChanged(object sender, RoutedEventArgs args)
    {
        if (sender is ToggleButton filter)
        {
            filter.Content = filter.IsChecked == true ? "Unread only" : "All articles";
            _ = RunSearchAsync(debounce: false);
        }
    }

    private void RetrySearchClicked(object sender, RoutedEventArgs args) => _ = RunSearchAsync(debounce: false);

    private async Task RunSearchAsync(bool debounce)
    {
        if (!IsSearchOpen || lifetime.IsCancellationRequested)
        {
            return;
        }

        searchRequest?.Cancel();
        var query = SearchQuery.Text.Trim();
        if (query.Length == 0)
        {
            ShowSearchMessage("Find words in titles, article text, and feed names.");
            return;
        }

        var unread = SearchUnread.IsChecked == true;
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        searchRequest = request;
        ShowSearchMessage("Searching…");
        try
        {
            if (debounce)
            {
                await Task.Delay(SearchTypingPause, request.Token);
            }

            var results = await reader.SearchAsync(query, unread, request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (results.Count == 0)
            {
                ShowSearchMessage($"Nothing matches “{query}”. Try fewer or related words.");
                return;
            }

            SearchState.Visibility = Visibility.Collapsed;
            SearchResults.ItemsSource = results;
            SearchResults.Visibility = Visibility.Visible;
            SearchResults.SelectedIndex = 0;
            var count = results.Count.ToString("N0", CultureInfo.CurrentCulture);
            SearchCount.Text = results.Count switch
            {
                1 => "1 result",
                ReaderData.SearchLimit => $"{count}+ results",
                _ => $"{count} results",
            };
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (!request.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            ShowSearchMessage("Fyke couldn’t search your feeds. The article you were reading is still open.", retry: true);
        }
        finally
        {
            if (ReferenceEquals(searchRequest, request))
            {
                searchRequest = null;
            }
        }
    }

    private void ShowSearchMessage(string message, bool retry = false)
    {
        SearchResults.Visibility = Visibility.Collapsed;
        SearchResults.ItemsSource = null;
        SearchCount.Text = string.Empty;
        SearchState.Visibility = Visibility.Visible;
        SearchStatus.Text = message;
        RetrySearch.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
    }

    private void SearchKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            CloseSearch();
            return;
        }

        if (SearchResults.Items.Count == 0)
        {
            return;
        }

        if (SearchQuery.FocusState != FocusState.Unfocused && args.Key is VirtualKey.Up or VirtualKey.Down)
        {
            args.Handled = true;
            var step = args.Key == VirtualKey.Up ? -1 : 1;
            SearchResults.SelectedIndex = Math.Clamp(SearchResults.SelectedIndex + step, 0, SearchResults.Items.Count - 1);
            SearchResults.ScrollIntoView(SearchResults.SelectedItem);
        }
        else if (args.Key == VirtualKey.Enter && SearchResults.SelectedItem is SearchHit hit
            && FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox or ListViewItem or ListView)
        {
            args.Handled = true;
            OpenSearchResult(hit);
        }
    }

    private void SearchResultClicked(object sender, RoutedEventArgs args)
    {
        if (sender is Button { DataContext: SearchHit hit })
        {
            OpenSearchResult(hit);
        }
    }

    private void OpenSearchResult(SearchHit hit)
    {
        CloseSearch();
        var row = articles.FirstOrDefault(article => article.Id == hit.Article.Id);
        applyingTimeline = true;
        try
        {
            Timeline.SelectedItem = row;
        }
        finally
        {
            applyingTimeline = false;
        }

        if (row is not null)
        {
            Timeline.ScrollIntoView(row);
        }

        if (openArticle?.Id != hit.Article.Id || RetryArticle.Visibility == Visibility.Visible)
        {
            articleInterrupted = false;
            _ = OpenArticleAsync(row ?? hit.Article);
        }
    }

    private void PrepareSearchTitle(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is TextBlock title && args.NewValue is SearchHit hit)
        {
            title.Style = (Style)Root.Resources[hit.Article.Read ? "ReadSearchTitle" : "UnreadSearchTitle"];
        }
    }

    private void PrepareSearchSnippet(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is TextBlock preview)
        {
            preview.Inlines.Clear();
            if (args.NewValue is SearchHit hit)
            {
                foreach (var part in hit.Snippet)
                {
                    preview.Inlines.Add(new Run
                    {
                        Text = part.Text,
                        FontWeight = part.Match ? readerFonts.SectionLabel : readerFonts.Ui,
                    });
                }
            }
        }
    }

    private void PrepareSearchDate(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is TextBlock date)
        {
            date.FontWeight = readerFonts.Ui;
            date.Text = string.Empty;
            if (args.NewValue is SearchHit { SortAt: var at } && at >= DateTimeOffset.MinValue.ToUnixTimeMilliseconds()
                && at <= DateTimeOffset.MaxValue.ToUnixTimeMilliseconds())
            {
                var localDate = DateTimeOffset.FromUnixTimeMilliseconds(at).LocalDateTime;
                var style = DateTime.Now - localDate < TimeSpan.FromDays(7)
                    ? "dddd" : CultureInfo.CurrentCulture.DateTimeFormat.MonthDayPattern.Replace("MMMM", "MMM", StringComparison.Ordinal);
                date.Text = localDate.ToString(style, CultureInfo.CurrentCulture);
            }
        }
    }
}
