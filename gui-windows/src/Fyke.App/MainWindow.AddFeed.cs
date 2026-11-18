using System;
using System.Collections.Generic;
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

public sealed partial class MainWindow
{
    private static readonly TimeSpan FeedTypingPause = TimeSpan.FromMilliseconds(500);
    private FeedSubscriptions feedSubscriptions = null!;
    private CancellationTokenSource? feedLookup;
    private FeedSubscriptionBatch? feedBatch;
    private bool addingFeeds;
    private bool finishedAddingFeeds;
    private bool allowLocalFeed;
    private bool IsAddFeedOpen => AddFeedOverlay?.Visibility == Visibility.Visible;

    private void InitializeAddFeed()
    {
        feedSubscriptions = new FeedSubscriptions(client);
        AddFeedOverlay.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(AddFeedKeyDown), true);
    }

    private void AddFeedClicked(object sender, RoutedEventArgs args) => OpenAddFeed();

    private void AddFeedShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected)
        {
            args.Handled = true;
            OpenAddFeed();
        }
    }

    private void OpenAddFeed(long? folderId = null)
    {
        if (!readerConnected || IsAddFeedOpen)
        {
            return;
        }

        CloseSearch();
        ClosePalette();
        PopulateAddFeedFolders(folderId);
        AddFeedStatus.Text = "Paste a site or feed address.";
        AddFeedLocalRetry.Visibility = Visibility.Collapsed;
        ShowReaderOverlay(AddFeedOverlay, AddFeedAddress);
        UpdateAddFeedControls();
    }

    private void PopulateAddFeedFolders(long? selected)
    {
        var choices = new List<FeedFolderChoice> { new(null, "No folder") };
        var path = new List<string>();
        foreach (var folder in catalog.Where(row => row.Scope == ReaderScope.Folder))
        {
            if (path.Count > folder.Depth)
            {
                path.RemoveRange(folder.Depth, path.Count - folder.Depth);
            }

            path.Add(folder.Title);
            choices.Add(new FeedFolderChoice(folder.Id, string.Join(" / ", path)));
        }

        AddFeedFolder.ItemsSource = choices;
        AddFeedFolder.SelectedItem = choices.FirstOrDefault(choice => choice.Id == selected) ?? choices[0];
    }

    private bool CloseAddFeed(bool restoreFocus = true)
    {
        if (addingFeeds)
        {
            return false;
        }

        if (IsAddFeedOpen)
        {
            feedLookup?.Cancel();
            HideReaderOverlay(AddFeedOverlay, AddFeedButton, restoreFocus);
            feedBatch = null;
            finishedAddingFeeds = false;
            allowLocalFeed = false;
            AddFeedAddress.Text = string.Empty;
            AddFeedCandidates.ItemsSource = null;
            AddFeedName.Text = string.Empty;
        }

        return true;
    }

    private void AddFeedBackdropPressed(object sender, PointerRoutedEventArgs args)
    {
        args.Handled = true;
        CloseAddFeed();
    }

    private void AddFeedCancelClicked(object sender, RoutedEventArgs args) => CloseAddFeed();

    private void AddFeedKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            CloseAddFeed();
        }
        else if (args.Key == VirtualKey.Enter && AddFeedAddress.FocusState != FocusState.Unfocused
            && AddFeedPrimary.IsEnabled)
        {
            args.Handled = true;
            InvokeAddFeedPrimary();
        }
    }

    private void AddFeedAddressChanged(object sender, TextChangedEventArgs args)
    {
        if (IsAddFeedOpen && !addingFeeds && feedBatch is null)
        {
            allowLocalFeed = false;
            _ = DiscoverFeedsAsync(debounce: true);
        }
    }

    private void AddFeedLocalClicked(object sender, RoutedEventArgs args)
    {
        allowLocalFeed = true;
        _ = DiscoverFeedsAsync(debounce: false);
    }

    private async Task DiscoverFeedsAsync(bool debounce)
    {
        feedLookup?.Cancel();
        AddFeedCandidates.ItemsSource = null;
        AddFeedLocalRetry.Visibility = Visibility.Collapsed;
        AddFeedStatus.Text = "Paste a site or feed address.";
        var address = FeedSubscriptions.Address(AddFeedAddress.Text);
        UpdateAddFeedControls();
        if (address is null || (debounce && !address.Host.Contains('.') && !AddFeedAddress.Text.Contains("://", StringComparison.Ordinal)))
        {
            return;
        }

        var allowPrivate = allowLocalFeed;
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        feedLookup = request;
        try
        {
            if (debounce)
            {
                await Task.Delay(FeedTypingPause, request.Token);
            }

            AddFeedStatus.Text = "Looking for feeds…";
            var found = await feedSubscriptions.DiscoverAsync(address, allowPrivate, request.Token);
            request.Token.ThrowIfCancellationRequested();
            AddFeedCandidates.ItemsSource = found;
            AddFeedStatus.Text = found.Count switch
            {
                0 => "No feed found on this site. Try the feed address if you know it.",
                1 => "Feed found.",
                _ => "This site has more than one feed. Choose the feeds you want.",
            };
            if (found.Count > 0)
            {
                AddFeedCandidates.SelectedIndex = 0;
            }
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (DaemonRpcException error) when (!request.IsCancellationRequested && error.Is("PrivateAddress"))
        {
            AddFeedStatus.Text = "This address is on a private network. Continue only if you trust this site.";
            AddFeedLocalRetry.Visibility = Visibility.Visible;
        }
        catch (Exception error) when (!request.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            AddFeedStatus.Text = "Fyke couldn’t reach that address. Check it and try again.";
        }
        finally
        {
            if (ReferenceEquals(feedLookup, request))
            {
                feedLookup = null;
                if (!request.IsCancellationRequested)
                {
                    UpdateAddFeedControls();
                }
            }
        }
    }

    private void AddFeedSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (IsAddFeedOpen)
        {
            AddFeedName.Text = AddFeedCandidates.SelectedItems.Count == 1
                ? ((FeedCandidate)AddFeedCandidates.SelectedItems[0]).Title ?? string.Empty
                : string.Empty;
            UpdateAddFeedControls();
        }
    }

    private void UpdateAddFeedControls()
    {
        if (!IsAddFeedOpen)
        {
            return;
        }

        var found = AddFeedCandidates.Items.Count > 0;
        var selected = AddFeedCandidates.SelectedItems.Count;
        var editing = !addingFeeds && feedBatch is null;
        AddFeedAddress.IsEnabled = editing;
        AddFeedCandidates.IsEnabled = editing;
        AddFeedName.IsEnabled = editing;
        AddFeedOptions.Visibility = found ? Visibility.Visible : Visibility.Collapsed;
        AddFeedNameRow.Visibility = selected == 1 ? Visibility.Visible : Visibility.Collapsed;
        AddFeedFolder.IsEnabled = !addingFeeds && !finishedAddingFeeds;
        CancelAddFeed.IsEnabled = !addingFeeds;
        CancelAddFeed.Visibility = finishedAddingFeeds ? Visibility.Collapsed : Visibility.Visible;
        AddFeedPrimary.IsEnabled = !addingFeeds && (finishedAddingFeeds || feedBatch is not null || selected > 0
            || (!found && FeedSubscriptions.Address(AddFeedAddress.Text) is not null));
        AddFeedPrimary.Content = finishedAddingFeeds ? "Done"
            : feedBatch is not null ? "Try again"
            : selected > 1 ? $"Subscribe to {selected}"
            : found ? "Subscribe" : "Find feeds";
    }

    private void AddFeedPrimaryClicked(object sender, RoutedEventArgs args) => InvokeAddFeedPrimary();

    private void InvokeAddFeedPrimary()
    {
        if (finishedAddingFeeds)
        {
            CloseAddFeed();
            return;
        }

        if (feedBatch is null && AddFeedCandidates.SelectedItems.Count == 0)
        {
            _ = DiscoverFeedsAsync(debounce: false);
            return;
        }

        if (feedBatch is null)
        {
            var selected = AddFeedCandidates.SelectedItems.Cast<FeedCandidate>().ToArray();
            var title = AddFeedName.Text.Trim();
            var requests = selected.Select(candidate => new FeedSubscriptionRequest(candidate,
                selected.Length == 1 && title.Length > 0 && title != candidate.Title ? title : null));
            feedBatch = new FeedSubscriptionBatch(requests, allowLocalFeed);
        }

        _ = SubscribeToFeedsAsync(feedBatch);
    }

    private async Task SubscribeToFeedsAsync(FeedSubscriptionBatch batch)
    {
        addingFeeds = true;
        var folder = (AddFeedFolder.SelectedItem as FeedFolderChoice)?.Id;
        AddFeedStatus.Text = "Saving subscriptions…";
        UpdateAddFeedControls();
        try
        {
            await batch.CompleteAsync(feedSubscriptions, folder, lifetime.Token);
            finishedAddingFeeds = true;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (!lifetime.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            var saved = batch.AddedCount > 0 ? $"Subscriptions saved: {batch.AddedCount}. " : string.Empty;
            AddFeedStatus.Text = saved + (error is DaemonRpcException rpc && rpc.Is("NoSuchFolder")
                ? "That folder is unavailable. Choose another folder and try again."
                : "Fyke couldn’t confirm all changes. Try again to finish.");
        }
        finally
        {
            addingFeeds = false;
        }

        if (lifetime.IsCancellationRequested)
        {
            return;
        }

        _ = LoadReaderAsync(refreshCatalog: true);
        if (finishedAddingFeeds && batch.FetchWarningCount == 0)
        {
            CloseAddFeed();
            return;
        }

        if (finishedAddingFeeds)
        {
            AddFeedStatus.Text = $"Subscriptions saved: {batch.AddedCount}. Some feeds couldn’t load articles on the first refresh.";
        }

        UpdateAddFeedControls();
    }
}
