using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private bool refreshingSubscriptions;

    private void RefreshSubscriptionsShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected && !IsReaderCovered)
        {
            args.Handled = true;
            _ = RefreshSubscriptionsAsync(destination is { Scope: ReaderScope.Feed } feed ? feed : null);
        }
    }

    private async Task RefreshSubscriptionsAsync(ReaderDestination? feed)
    {
        if (!readerConnected || refreshingSubscriptions || lifetime.IsCancellationRequested)
        {
            return;
        }

        refreshingSubscriptions = true;
        SetSubscriptionStatus(feed is null ? "Queueing feed refreshes…" : $"Refreshing {feed.Title}…");
        try
        {
            var ct = lifetime.Token;
            if (feed is null)
            {
                var queued = await catalogEdits.RefreshAllAsync(ct);
                SetSubscriptionStatus(queued == 0 ? "No feeds to refresh." : $"Queued {CountLabel(queued, "feed")} for refresh.");
            }
            else
            {
                var result = await catalogEdits.RefreshFeedAsync(feed.Id, ct);
                var status = result.Status switch
                {
                    "updated" when result.NewCount > 0 => $"{CountLabel(result.NewCount, "new article")} in {feed.Title}.",
                    "updated" when result.Updated > 0 => $"{CountLabel(result.Updated, "updated article")} in {feed.Title}.",
                    "updated" or "not_modified" or "unchanged_body" => $"{feed.Title} is up to date.",
                    "busy" => $"{feed.Title} is already refreshing.",
                    "gone" => $"{feed.Title} is no longer available.",
                    _ => $"Fyke couldn’t refresh {feed.Title}. Try again.",
                };
                SetSubscriptionStatus(status);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            SetSubscriptionStatus("Fyke couldn’t confirm the refresh. Try again.");
        }
        finally
        {
            refreshingSubscriptions = false;
        }
    }

    private void SetSubscriptionStatus(string text)
    {
        if (!lifetime.IsCancellationRequested)
        {
            SubscriptionStatus.Text = text;
            SubscriptionStatus.Visibility = Visibility.Visible;
        }
    }

    private void CatalogDeleteContentsChanged(object sender, RoutedEventArgs args)
    {
        if (IsCatalogEditOpen && catalogDraft is { Kind: CatalogEditKind.Remove, Item: { } item })
        {
            UpdateRemovalHint(item);
        }
    }

    private void UpdateRemovalHint(ReaderDestination item)
    {
        if (item.Scope == ReaderScope.Feed)
        {
            CatalogEditHint.Text = $"This permanently removes the subscription and deletes {ArticleLoss(item.Entries, item.Starred)}.";
        }
        else
        {
            var contents = CatalogRemoval.FromCatalog(item, catalog).Contents;
            CatalogDeleteContents.Visibility = contents.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            if (contents.Count == 0)
            {
                CatalogEditHint.Text = "The folder is empty.";
            }
            else if (CatalogDeleteContents.IsChecked == true)
            {
                var feeds = contents.Where(row => row.Scope == ReaderScope.Feed).ToArray();
                var folders = contents.Count - feeds.Length;
                CatalogEditHint.Text = $"This permanently deletes {CountLabel(folders, "subfolder")}, {CountLabel(feeds.Length, "feed")}, and "
                    + $"{ArticleLoss(feeds.Sum(feed => feed.Entries), feeds.Sum(feed => feed.Starred))}.";
            }
            else
            {
                var parent = item.ParentId is null ? "the top level" : "the parent folder";
                CatalogEditHint.Text = $"Feeds and subfolders move to {parent}. Your articles stay.";
            }
        }

        CatalogEditHint.Visibility = Visibility.Visible;
    }

    private void ApplyCatalogRemoval(CatalogRemoval removal, bool deleteContents)
    {
        var removed = removal.Removed(deleteContents);
        collapsedFolders.ExceptWith(removed.Where(row => row.Scope == ReaderScope.Folder).Select(row => row.Id));
        if (openArticle?.FeedId is long feed && removed.Any(row => row.Scope == ReaderScope.Feed && row.Id == feed))
        {
            SetTimelineSelection(null);
            _ = OpenArticleAsync(null);
        }
    }

    private static string CountLabel(long count, string noun) =>
        $"{count.ToString("N0", CultureInfo.CurrentCulture)} {noun}{(count == 1 ? string.Empty : "s")}";

    private static string ArticleLoss(long count, long starred) =>
        CountLabel(count, "saved article") + (starred > 0 ? $", including {starred.ToString("N0", CultureInfo.CurrentCulture)} starred" : "");
}
