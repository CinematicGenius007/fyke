using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private const int UndoHistoryLimit = 100;
    private readonly List<BulkReadChange> bulkUndo = [];
    private DispatcherQueueTimer bulkNoticeTimer = null!;
    private bool bulkMarksBusy;

    private bool CanChangeBulkMarks => readerConnected && !lifetime.IsCancellationRequested && !bulkMarksBusy;

    private void InitializeBulkMarks()
    {
        bulkNoticeTimer = DispatcherQueue.CreateTimer();
        bulkNoticeTimer.Interval = TimeSpan.FromSeconds(6);
        bulkNoticeTimer.IsRepeating = false;
        bulkNoticeTimer.Tick += (_, _) => HideBulkNotice();
    }

    private void PrepareDestinationActions(Grid row, ReaderDestination item)
    {
        if (item.Scope == ReaderScope.Starred)
        {
            row.ContextFlyout = null;
        }
        else if (row.ContextFlyout is null)
        {
            var flyout = new MenuFlyout();
            var mark = new MenuFlyoutItem { Text = "Mark all read" };
            var add = new MenuFlyoutItem { Text = "Add feed here" };
            mark.Click += (_, _) => StartBulkMark(row.DataContext as ReaderDestination);
            add.Click += (_, _) =>
            {
                if (row.DataContext is ReaderDestination { Scope: ReaderScope.Folder } folder)
                {
                    OpenAddFeed(folder.Id);
                }
            };
            flyout.Items.Add(mark);
            flyout.Items.Add(add);
            flyout.Opening += (_, _) =>
            {
                mark.IsEnabled = CanChangeBulkMarks;
                add.Visibility = row.DataContext is ReaderDestination { Scope: ReaderScope.Folder }
                    ? Visibility.Visible : Visibility.Collapsed;
            };
            row.ContextFlyout = flyout;
        }
    }

    private void UpdateBulkButton()
    {
        var available = destination is { Scope: not ReaderScope.Starred };
        BulkReadButton.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        BulkReadButton.IsEnabled = available && CanChangeBulkMarks;
    }

    private void MarkAllReadClicked(object sender, RoutedEventArgs args) => StartBulkMark(destination);

    private void MarkAllReadShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!IsReaderOverlayOpen && StartBulkMark(destination))
        {
            args.Handled = true;
        }
    }

    private bool StartBulkMark(ReaderDestination? scope)
    {
        if (!CanChangeBulkMarks || scope is null || scope.Scope == ReaderScope.Starred)
        {
            return false;
        }

        _ = MarkScopeReadAsync(scope);
        return true;
    }

    private async Task MarkScopeReadAsync(ReaderDestination scope)
    {
        bulkMarksBusy = true;
        ShowBulkNotice($"Marking unread articles in {scope.Title}…", temporary: false);
        var change = new BulkReadChange(scope);
        var completed = false;
        try
        {
            await change.ApplyAsync(reader, lifetime.Token);
            completed = true;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // The change retains the batches the daemon acknowledged before the error.
        }
        finally
        {
            bulkMarksBusy = false;
        }

        if (lifetime.IsCancellationRequested)
        {
            return;
        }

        var count = change.RemainingCount;
        if (count == 0)
        {
            ShowBulkNotice(completed && !change.ReachedLimit
                ? $"No unread articles in {scope.Title}."
                : $"Fyke couldn’t confirm a change in {scope.Title}. Check the unread count before trying again.");
            return;
        }

        bulkUndo.Add(change);
        if (bulkUndo.Count > UndoHistoryLimit)
        {
            bulkUndo.RemoveAt(0);
        }

        if (openArticle is { } article && change.Includes(article.Id))
        {
            ApplyBulkReadToArticle(article.Id, true);
        }

        var message = $"Marked {ArticleCount(count)} in {scope.Title} as read.";
        if (!completed)
        {
            message += " Fyke couldn’t confirm the remaining changes.";
        }
        else if (change.ReachedLimit)
        {
            message += " Reached the 20,000-article limit.";
        }

        ShowBulkNotice(message, offerUndo: true);
    }

    private void UndoBulkClicked(object sender, RoutedEventArgs args) => StartBulkUndo();

    private void UndoBulkShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!IsReaderOverlayOpen && StartBulkUndo())
        {
            args.Handled = true;
        }
    }

    private bool StartBulkUndo()
    {
        if (!CanChangeBulkMarks || bulkUndo.Count == 0)
        {
            return false;
        }

        _ = UndoBulkReadAsync(bulkUndo[^1]);
        return true;
    }

    private async Task UndoBulkReadAsync(BulkReadChange change)
    {
        bulkMarksBusy = true;
        ShowBulkNotice($"Restoring unread articles in {change.DestinationTitle}…", temporary: false);
        var before = change.RemainingCount;
        var active = openArticle?.Id;
        var affectsActive = active is long id && change.Includes(id);
        try
        {
            await change.UndoAsync(reader, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // Any unconfirmed batch remains in the undo record.
        }
        finally
        {
            bulkMarksBusy = false;
        }

        if (lifetime.IsCancellationRequested)
        {
            return;
        }

        if (affectsActive && active is long entry && !change.Includes(entry))
        {
            ApplyBulkReadToArticle(entry, false);
        }

        var restored = before - change.RemainingCount;
        if (change.RemainingCount == 0)
        {
            bulkUndo.RemoveAt(bulkUndo.Count - 1);
            ShowBulkNotice($"Restored {ArticleCount(restored)} in {change.DestinationTitle} to unread.");
        }
        else
        {
            var message = restored == 0
                ? "Fyke couldn’t confirm the undo. Try Undo again."
                : $"Restored {ArticleCount(restored)} to unread. Try Undo again for the remaining articles.";
            ShowBulkNotice(message, offerUndo: true);
        }
    }

    private void ApplyBulkReadToArticle(long id, bool read)
    {
        if (openArticle is { } article && article.Id == id && !pendingMarks.Contains(id))
        {
            ApplyArticleMarks(id, new ArticleMarks(read, article.Starred));
        }
    }

    private static string ArticleCount(int count) => count == 1 ? "1 article"
        : $"{count.ToString("N0", CultureInfo.CurrentCulture)} articles";

    private void ShowBulkNotice(string message, bool offerUndo = false, bool temporary = true)
    {
        UpdateBulkButton();
        bulkNoticeTimer.Stop();
        BulkNoticeText.Text = message;
        BulkNoticeUndo.Visibility = offerUndo ? Visibility.Visible : Visibility.Collapsed;
        BulkNotice.Visibility = readerConnected ? Visibility.Visible : Visibility.Collapsed;
        if (temporary && readerConnected)
        {
            bulkNoticeTimer.Start();
        }
    }

    private void HideBulkNotice()
    {
        bulkNoticeTimer.Stop();
        BulkNotice.Visibility = Visibility.Collapsed;
    }
}
