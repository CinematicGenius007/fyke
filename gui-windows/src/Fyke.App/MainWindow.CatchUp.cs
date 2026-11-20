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

/// <summary>
/// Catch up, as on macOS (gui/Sources/Reader/CatchUp.swift): the unread articles of the place
/// being read, one card at a time. Skip marks read, Later saves for later, Read now opens it.
/// Each mark keeps the article's earlier state so Undo can put it back.
/// </summary>
public sealed partial class MainWindow
{
    private readonly Dictionary<long, CatchUpMarks?> catchUpPrevious = [];
    private CatchUpSession? catchUp;
    private ReaderDestination? catchUpPlace;
    private CancellationTokenSource? catchUpRequest;
    private bool catchUpMarked;

    private bool IsCatchUpOpen => CatchUpOverlay?.Visibility == Visibility.Visible;

    /// <summary>Opens Catch up over a place, or the one being read. Today has no articles of its own, so it means All.</summary>
    private void OpenCatchUp(ReaderDestination? place = null)
    {
        place ??= destination;
        if (!readerConnected || place is null || IsCatchUpOpen)
        {
            return;
        }

        if (place.Scope == ReaderScope.Today)
        {
            place = catalog.FirstOrDefault(row => row.Scope == ReaderScope.All) ?? place;
        }

        CloseSettings(restoreFocus: false);
        CloseAsk(restoreFocus: false);
        CloseRecipe(restoreFocus: false);
        catchUpPlace = place;
        catchUp = null;
        catchUpMarked = false;
        catchUpPrevious.Clear();
        CatchUpHeading.Text = CatchUpText.Heading(CatchUpText.Title(place));
        ShowReaderOverlay(CatchUpOverlay, CatchUpDone);
        RenderCatchUp();
        _ = LoadCatchUpAsync(place);
    }

    private async Task LoadCatchUpAsync(ReaderDestination place)
    {
        catchUpRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        catchUpRequest = request;
        try
        {
            var queue = await reader.CatchUpQueueAsync(place, request.Token);
            request.Token.ThrowIfCancellationRequested();
            catchUp = new CatchUpSession(queue);
            RenderCatchUp();
            FocusCatchUp();
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            ShowCatchUpState(new InlineStateView(InlineTone.Failed, "Could not load", "Catch up could not start",
                $"{CatchUpProblem(error)} Nothing was marked.", ("Close", () => CloseCatchUp())));
        }
        finally
        {
            if (ReferenceEquals(catchUpRequest, request))
            {
                catchUpRequest = null;
            }
        }
    }

    private void CloseCatchUp(bool restoreFocus = true)
    {
        if (!IsCatchUpOpen)
        {
            return;
        }

        catchUpRequest?.Cancel();
        HideReaderOverlay(CatchUpOverlay, CatchUpButton, restoreFocus);
        catchUp = null;
        catchUpPrevious.Clear();
        if (catchUpMarked)
        {
            catchUpMarked = false;
            _ = LoadReaderAsync(refreshCatalog: true);
        }
    }

    /// <summary>Draws the current card, or the loading, empty or finished state.</summary>
    private void RenderCatchUp()
    {
        var session = catchUp;
        var card = session?.Current;
        CatchUpLoading.IsActive = session is null;
        CatchUpLoading.Visibility = session is null ? Visibility.Visible : Visibility.Collapsed;
        CatchUpProgress.Value = session?.Progress ?? 0;
        CatchUpStack.Visibility = card is null ? Visibility.Collapsed : Visibility.Visible;
        CatchUpActions.Visibility = CatchUpStack.Visibility;
        CatchUpFooter.Visibility = card is null ? Visibility.Collapsed : Visibility.Visible;
        CatchUpState.Visibility = Visibility.Collapsed;
        if (session is null)
        {
            return;
        }

        if (card is null)
        {
            ShowCatchUpState(new InlineStateView(InlineTone.Empty, "Catch up", CatchUpText.FinishedTitle(session),
                CatchUpText.FinishedDetail(session, CatchUpText.Title(catchUpPlace!)),
                ("Done", () => CloseCatchUp()), session.HasHistory ? ("Undo last", (Action)(() => _ = UndoCatchUpAsync())) : null));
            return;
        }

        CatchUpDetail.Text = CatchUpText.Detail(card, DateTimeOffset.Now);
        CatchUpTitle.Text = card.Title;
        CatchUpPreview.Text = card.Preview ?? string.Empty;
        CatchUpPreview.Visibility = string.IsNullOrWhiteSpace(card.Preview) ? Visibility.Collapsed : Visibility.Visible;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(CatchUpCard, card.Title);
        var more = session.HasMoreAfterCurrent ? Visibility.Visible : Visibility.Collapsed;
        CatchUpEdgeFar.Visibility = more;
        CatchUpEdgeNear.Visibility = more;
        CatchUpCounts.Text = $"{CatchUpText.Position(session)} · {CatchUpText.Summary(session)}";
        CatchUpUndo.IsEnabled = session.HasHistory;
    }

    private void ShowCatchUpState(InlineStateView state)
    {
        CatchUpLoading.IsActive = false;
        CatchUpLoading.Visibility = Visibility.Collapsed;
        CatchUpStack.Visibility = Visibility.Collapsed;
        CatchUpActions.Visibility = Visibility.Collapsed;
        CatchUpFooter.Visibility = Visibility.Collapsed;
        CatchUpState.Children.Clear();
        CatchUpState.Children.Add(briefRenderer.State(state));
        CatchUpState.Visibility = Visibility.Visible;
        CatchUpDone.Focus(FocusState.Programmatic);
    }

    private void FocusCatchUp()
    {
        if (catchUp?.Current is not null)
        {
            CatchUpCard.Focus(FocusState.Programmatic);
        }
    }

    /// <summary>Marks the current card as decided and moves on; Read now also opens it in the reader.</summary>
    private async Task DecideCatchUpAsync(CatchUpDecision decision)
    {
        if (catchUp is not { } session || session.Decide(decision) is not { } card)
        {
            return;
        }

        catchUpMarked = true;
        if (decision == CatchUpDecision.Read)
        {
            OpenFromCatchUp(card);
        }
        else
        {
            RenderCatchUp();
            FocusCatchUp();
        }

        try
        {
            catchUpPrevious[card.Id] = await reader.CatchUpMarkAsync(card.Id, decision, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // The card moved on; say so and keep the earlier state unknown, which Undo restores as unread.
            catchUpPrevious[card.Id] = null;
            ShowBulkNotice($"Fyke couldn’t mark “{card.Title}”. {CatchUpProblem(error)}");
        }
    }

    private async Task UndoCatchUpAsync()
    {
        if (catchUp is not { } session || session.Undo() is not { } undone)
        {
            return;
        }

        RenderCatchUp();
        FocusCatchUp();
        catchUpPrevious.Remove(undone.Id, out var previous);
        try
        {
            await reader.RestoreCatchUpAsync(undone.Id, previous, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowBulkNotice($"Fyke couldn’t undo the last mark. {CatchUpProblem(error)}");
        }
    }

    /// <summary>Closes Catch up and opens the article, listing All first when the reader shows briefs.</summary>
    private void OpenFromCatchUp(CatchUpCard card)
    {
        var place = catchUpPlace;
        CloseCatchUp(restoreFocus: false);
        if (IsTodayShown && place is not null)
        {
            NavigateToDestination(place);
        }

        _ = OpenArticleAsync(new TimelineArticle(card.Id, card.Title, card.FeedTitle, Read: true));
        FocusArticle();
    }

    private static string CatchUpProblem(Exception error) =>
        error is DaemonRpcException { Message.Length: > 0 } refusal ? refusal.Message.TrimEnd('.') + "."
        : "Fyke couldn’t reach its service.";

    private void CatchUpShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected && !IsReaderOverlayOpen)
        {
            args.Handled = true;
            OpenCatchUp();
        }
    }

    private void CatchUpClicked(object sender, RoutedEventArgs args) => OpenCatchUp();

    private void CatchUpDoneClicked(object sender, RoutedEventArgs args) => CloseCatchUp();

    private void CatchUpSkipClicked(object sender, RoutedEventArgs args) => _ = DecideCatchUpAsync(CatchUpDecision.Skip);

    private void CatchUpLaterClicked(object sender, RoutedEventArgs args) => _ = DecideCatchUpAsync(CatchUpDecision.Later);

    private void CatchUpReadClicked(object sender, RoutedEventArgs args) => _ = DecideCatchUpAsync(CatchUpDecision.Read);

    private void CatchUpUndoClicked(object sender, RoutedEventArgs args) => _ = UndoCatchUpAsync();

    private void CatchUpKeyDown(object sender, KeyRoutedEventArgs args)
    {
        var card = catchUp?.Current is not null;
        switch (args.Key)
        {
            case VirtualKey.Escape:
                CloseCatchUp();
                break;
            case VirtualKey.Z when IsModifierDown(VirtualKey.Control):
                _ = UndoCatchUpAsync();
                break;
            case VirtualKey.Left when card:
                _ = DecideCatchUpAsync(CatchUpDecision.Skip);
                break;
            case VirtualKey.Down when card:
                _ = DecideCatchUpAsync(CatchUpDecision.Later);
                break;
            case VirtualKey.Right when card:
                _ = DecideCatchUpAsync(CatchUpDecision.Read);
                break;
            // Enter on a focused button presses that button; elsewhere it reads the card.
            case VirtualKey.Enter when card && args.OriginalSource is not Button:
                _ = DecideCatchUpAsync(CatchUpDecision.Read);
                break;
            default:
                return;
        }

        args.Handled = true;
    }
}
