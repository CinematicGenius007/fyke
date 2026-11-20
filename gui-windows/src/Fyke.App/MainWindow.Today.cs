using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Fyke.App;

/// <summary>
/// Today: the briefs in the list pane and the chosen one in the reader, as on macOS
/// (gui/Sources/Reader/Today.swift). Opening Today never runs a writer; it writes when asked.
/// </summary>
public sealed partial class MainWindow
{
    private readonly ObservableCollection<BriefListItem> briefRows = [];
    private Briefs briefs = null!;
    private BriefRenderer briefRenderer = null!;
    private DispatcherQueueTimer todayReloadTimer = null!;
    private int todayChangesPending;
    private TodaySnapshot today = TodaySnapshot.Empty;
    private CancellationTokenSource? todayRequest;
    // The brief chosen in the list. None means the newest, and becomes it once Today shows one.
    private long? selectedBriefId;
    private Brief? shownBrief;
    private string? shownTodayKey;
    private bool applyingBriefRows;
    private bool openedFromBrief;

    private bool IsTodayShown => destination is { Scope: ReaderScope.Today };

    private void InitializeToday(FontFamily reading, FontFamily ui)
    {
        briefs = new Briefs(client);
        briefRenderer = new BriefRenderer(reading, ui, readerFonts, readerTextStyle);
        BriefRows.ItemsSource = briefRows;
        BriefRows.FontFamily = ui;
        todayReloadTimer = DispatcherQueue.CreateTimer();
        todayReloadTimer.Interval = TimeSpan.FromMilliseconds(250);
        todayReloadTimer.IsRepeating = false;
        todayReloadTimer.Tick += (_, _) =>
        {
            todayReloadTimer.Stop();
            if (Interlocked.Exchange(ref todayChangesPending, 0) != 0)
            {
                _ = LoadTodayAsync();
            }
        };
    }

    /// <summary>Jobs and new briefs reload Today, wherever the reader is, so the sidebar can say so.</summary>
    private void QueueTodayChange(DaemonEvent change)
    {
        if (Briefs.Concerns(change) && Interlocked.Exchange(ref todayChangesPending, 1) == 0)
        {
            _ = DispatcherQueue.TryEnqueue(() =>
            {
                if (readerConnected && !lifetime.IsCancellationRequested)
                {
                    todayReloadTimer.Start();
                }
            });
        }
    }

    private void StopToday()
    {
        todayReloadTimer.Stop();
        todayRequest?.Cancel();
        briefRenderer.ClosePopover();
        shownTodayKey = null;
    }

    /// <summary>Swaps the article list and reader for the brief list and brief, or back.</summary>
    private void ShowTodayMode()
    {
        var on = IsTodayShown;
        Timeline.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        BriefRows.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        TodayDate.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (on)
        {
            TodayDate.Text = BriefText.Today(DateTimeOffset.Now);
            TimelineState.Visibility = Visibility.Collapsed;
            MoreArticles.Visibility = Visibility.Collapsed;
            selectedBriefId ??= today.Briefs.Count > 0 ? today.Briefs[0].Id : null;
        }
        else
        {
            briefRenderer.ClosePopover();
        }

        UpdateTodayPanes();
        UpdateTodayBadge();
    }

    /// <summary>The brief covers the article reader unless an article opened from its sources is shown.</summary>
    private void UpdateTodayPanes()
    {
        var on = IsTodayShown;
        openedFromBrief = on && openArticle is not null;
        TodayPane.Visibility = on && openArticle is null ? Visibility.Visible : Visibility.Collapsed;
        BackToBrief.Visibility = openedFromBrief ? Visibility.Visible : Visibility.Collapsed;
        UpdateMarkControls();
    }

    private async Task LoadTodayAsync(bool reload = true)
    {
        if (!readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        todayRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        todayRequest = request;
        try
        {
            if (reload)
            {
                today = await briefs.LoadAsync(request.Token);
                request.Token.ThrowIfCancellationRequested();
                UpdateTodayBadge();
            }

            if (IsTodayShown)
            {
                selectedBriefId ??= today.Briefs.Count > 0 ? today.Briefs[0].Id : null;
                await ShowTodayAsync(request.Token);
            }
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (!request.IsCancellationRequested && IsTodayShown)
            {
                ShowTodayState("load", new InlineStateView(InlineTone.Failed, "Today", "Fyke couldn’t read your briefs",
                    "Your briefs and articles are as they were.", ("Try again", () => _ = LoadTodayAsync())));
            }
        }
        finally
        {
            if (ReferenceEquals(todayRequest, request))
            {
                todayRequest = null;
            }
        }
    }

    private async Task ShowTodayAsync(CancellationToken ct)
    {
        var now = DateTimeOffset.Now;
        ApplyBriefRows();
        var writing = today.Writing;
        WritingRow.Visibility = writing is null ? Visibility.Collapsed : Visibility.Visible;
        WritingDetail.Text = writing is null ? string.Empty : BriefText.WritingDetail(writing, now);
        BriefListEmpty.Visibility = today.Briefs.Count == 0 && writing is null ? Visibility.Visible : Visibility.Collapsed;
        WriteBriefButton.IsEnabled = today.Available && writing is null;

        switch (today.State(selectedBriefId, now))
        {
            case TodayState.Unavailable:
                ShowTodayState("unavailable", new InlineStateView(InlineTone.Empty, "Today", "Briefs need a newer Fyke service",
                    "The background service running now does not write briefs. Your feeds and articles work as before.",
                    ("Restart the service", RestartService)));
                return;
            case TodayState.Writing:
                ShowTodayState($"writing:{writing!.Id}", new InlineStateView(InlineTone.Working, "Writing your brief",
                    $"Reading your articles with the {(today.Recipes.Count > 0 ? today.Recipes[0].Name : null) ?? "recipe"} recipe",
                    BriefText.WritingSeconds(writing, now),
                    ("Cancel", () => _ = CancelBriefAsync(writing.Id)),
                    ("Read the articles instead", ShowAllArticles)));
                return;
            case TodayState.Failed:
                var failed = today.Failed(now)!;
                ShowTodayState($"failed:{failed.Id}", new InlineStateView(InlineTone.Failed, "Brief not written",
                    $"{BriefText.JobWriter(failed.Writer)} could not write the brief", BriefText.FailedDetail(failed),
                    ("Try again", () => _ = WriteBriefAsync())));
                return;
            case TodayState.Empty:
                ShowTodayState("empty", new InlineStateView(InlineTone.Empty, "Today", "No brief yet",
                    "A brief reads your newest unread articles and cites each one it uses. Opening Today never runs a writer; it writes when you ask.",
                    ("Write a brief", () => _ = WriteBriefAsync())));
                return;
        }

        var summary = today.Selected(selectedBriefId)!;
        var key = $"brief:{summary.Id}";
        if (shownTodayKey == key && shownBrief?.Id == summary.Id)
        {
            return;
        }

        if (shownBrief?.Id != summary.Id)
        {
            shownBrief = null;
            try
            {
                shownBrief = await briefs.GetAsync(summary.Id, ct);
                ct.ThrowIfCancellationRequested();
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
            {
                ShowTodayState($"unopened:{summary.Id}", new InlineStateView(InlineTone.Failed, "Today", "Fyke couldn’t open this brief",
                    "Your briefs and articles are as they were.", ("Try again", () => _ = LoadTodayAsync(reload: false))));
                return;
            }
        }

        shownTodayKey = key;
        briefRenderer.ShowBrief(TodayColumn, shownBrief, BriefText.Header(shownBrief, ViewName),
            today.RecipeName(shownBrief.RecipeId), now, OpenBriefSource);
        _ = TodayScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    // A state is drawn again each time, since its words change as a job runs; a brief only when another is chosen.
    private void ShowTodayState(string key, InlineStateView state)
    {
        if (!key.StartsWith("writing:", StringComparison.Ordinal) && shownTodayKey == key)
        {
            return;
        }

        shownTodayKey = key;
        briefRenderer.ShowState(TodayColumn, state);
    }

    private string? ViewName(long id) =>
        catalog.FirstOrDefault(row => row.Scope == ReaderScope.View && row.Id == id)?.Title;

    private void ApplyBriefRows()
    {
        applyingBriefRows = true;
        try
        {
            ReaderRows.Reconcile(briefRows, today.Rows(ViewName), row => row.Id);
            var selected = briefRows.FirstOrDefault(row => row.Id == today.Selected(selectedBriefId)?.Id);
            if (!ReferenceEquals(BriefRows.SelectedItem, selected))
            {
                BriefRows.SelectedItem = selected;
            }
        }
        finally
        {
            applyingBriefRows = false;
        }
    }

    private void BriefRowChanged(object sender, SelectionChangedEventArgs args)
    {
        if (applyingBriefRows || BriefRows.SelectedItem is not BriefListItem row)
        {
            return;
        }

        selectedBriefId = row.Id;
        if (openArticle is not null)
        {
            _ = OpenArticleAsync(null);
        }

        _ = LoadTodayAsync(reload: false);
    }

    /// <summary>J and K move through the briefs in Today, as through articles elsewhere.</summary>
    private bool MoveBriefSelection(int offset)
    {
        if (briefRows.Count == 0)
        {
            return false;
        }

        var index = BriefRows.SelectedIndex < 0 ? (offset > 0 ? -1 : briefRows.Count) : BriefRows.SelectedIndex;
        var next = Math.Clamp(index + offset, 0, briefRows.Count - 1);
        if (next != BriefRows.SelectedIndex)
        {
            BriefRows.SelectedIndex = next;
            BriefRows.ScrollIntoView(briefRows[next]);
        }

        return true;
    }

    // The newest brief's title is drawn as unread, the older ones as read.
    [System.Diagnostics.CodeAnalysis.SuppressMessage("Performance", "CA1822:Mark members as static",
        Justification = "XAML connects event handlers to the window instance.")]
    private void BriefTitleChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (sender is TextBlock title && args.NewValue is BriefListItem row)
        {
            title.Style = AppResources.FromApp<Style>(row.Newest ? "BriefUnread" : "BriefRead");
        }
    }

    /// <summary>The sidebar's Today row says when a brief is being written, or a new one is unseen.</summary>
    private void UpdateTodayBadge()
    {
        var badge = today.Badge(IsTodayShown, selectedBriefId);
        var index = catalog.ToList().FindIndex(row => row.Scope == ReaderScope.Today);
        if (index < 0 || catalog[index].Badge == badge)
        {
            return;
        }

        catalog = [.. catalog.Select((row, position) => position == index ? row with { Badge = badge } : row)];
        if (destination is { Scope: ReaderScope.Today } current)
        {
            destination = current with { Badge = badge };
        }

        ApplyVisibleDestinations();
    }

    private void OpenBriefSource(BriefCitation citation)
    {
        briefRenderer.ClosePopover();
        _ = OpenArticleAsync(new TimelineArticle(citation.Id, citation.DisplayTitle, citation.FeedTitle, citation.Read));
        FocusArticle();
    }

    private void BackToBriefClicked(object sender, RoutedEventArgs args)
    {
        _ = OpenArticleAsync(null);
        TodayScroller.Focus(FocusState.Programmatic);
    }

    private void WriteBriefClicked(object sender, RoutedEventArgs args) => _ = WriteBriefAsync();

    private void WriteBriefShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsTodayShown && !IsReaderCovered)
        {
            args.Handled = true;
            _ = WriteBriefAsync();
        }
    }

    /// <summary>
    /// Writes a brief of the chosen brief's view, or of the unread articles when it has none. The
    /// new brief is shown when it arrives.
    /// </summary>
    private async Task WriteBriefAsync()
    {
        if (!readerConnected || !today.Available || today.Writing is not null)
        {
            return;
        }

        var selected = today.Selected(selectedBriefId);
        var view = selected?.ViewId ?? (destination is { Scope: ReaderScope.View } current ? current.Id : null);
        WriteBriefButton.IsEnabled = false;
        try
        {
            await briefs.RunAsync(view, today.RecipeFor(selectedBriefId), lifetime.Token);
            selectedBriefId = null;
            shownTodayKey = null;
            if (!IsTodayShown && catalog.FirstOrDefault(row => row.Scope == ReaderScope.Today) is { } row)
            {
                NavigateToDestination(row);
            }
            else if (openArticle is not null)
            {
                _ = OpenArticleAsync(null);
            }

            await LoadTodayAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            WriteBriefButton.IsEnabled = today.Available && today.Writing is null;
            ShowBulkNotice(error is DaemonRpcException { Message.Length: > 0 } refusal
                ? $"Fyke couldn’t start a brief: {refusal.Message}"
                : "Fyke couldn’t start a brief. Try again.");
        }
    }

    private async Task CancelBriefAsync(long job)
    {
        try
        {
            await briefs.CancelAsync(job, lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowBulkNotice("Fyke couldn’t cancel the brief. It may still finish.");
        }

        await LoadTodayAsync();
    }

    private void ShowAllArticles()
    {
        if (catalog.FirstOrDefault(row => row.Scope == ReaderScope.All) is { } all)
        {
            NavigateToDestination(all);
        }
    }

    // The service stops; the client starts the installed one again and reconnects.
    private void RestartService() => _ = RestartServiceAsync();

    private async Task RestartServiceAsync()
    {
        try
        {
            await client.CallAsync("daemon.stop", null, lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            // The service may stop before it answers.
        }
    }
}
