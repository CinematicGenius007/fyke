using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

/// <summary>
/// Ask your feeds, as on macOS (gui/Sources/Reader/Ask.swift): a question answered only from your
/// articles, every claim cited. It covers the reader; Back returns to the article or the list.
/// The job is followed through the job list Today already reloads on each job change.
/// </summary>
public sealed partial class MainWindow
{
    private readonly AskSession askSession = new();
    private Asking asking = null!;
    private string? askViewName;
    private bool askUnavailable;

    private bool IsAskShown => AskPane.Visibility == Visibility.Visible;

    private string AskScope => AskText.Scope(askViewName);

    /// <summary>Opens Ask over the saved view being read, or every feed, and asks the question when given one.</summary>
    private void StartAsk(string? question = null)
    {
        if (!readerConnected)
        {
            return;
        }

        CloseSettings(restoreFocus: false);
        CloseRoutines(restoreFocus: false);
        CloseRecipe(restoreFocus: false);
        var view = destination is { Scope: ReaderScope.View } current ? current : null;
        askViewName = view?.Title;
        askSession.Start(view?.Id);
        AskBackText.Text = openArticle is null ? "Back" : "Back to article";
        AskPane.Visibility = Visibility.Visible;
        AskQuery.Text = question?.Trim() ?? string.Empty;
        RenderAsk();
        if (AskQuery.Text.Length > 0)
        {
            _ = SubmitAskAsync();
        }
        else
        {
            AskQuery.Focus(FocusState.Programmatic);
        }
    }

    private void CloseAsk(bool restoreFocus = true)
    {
        if (!IsAskShown)
        {
            return;
        }

        briefRenderer.ClosePopover();
        AskPane.Visibility = Visibility.Collapsed;
        AskColumn.Children.Clear();
        AskColumn.Children.Add(AskField);
        if (restoreFocus)
        {
            FocusArticle();
        }
    }

    private async Task SubmitAskAsync()
    {
        if (askSession.Begin(AskQuery.Text) is not { } question)
        {
            return;
        }

        AskQuery.Text = string.Empty;
        RenderAsk();
        try
        {
            var job = await asking.RunAsync(question, askSession.ViewId, lifetime.Token);
            askSession.Queued(job.Id);
            await FollowAskAsync([job]);
            // A job that finished before it was queued here has no change left to report.
            _ = LoadTodayAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (DaemonRpcException error) when (error.IsUnknownMethod)
        {
            askUnavailable = true;
            askSession.Refused("Asking needs a newer Fyke service.");
            RenderAsk();
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            askSession.Refused(error is DaemonRpcException { Message.Length: > 0 } refusal
                ? refusal.Message : "Fyke couldn’t reach the writer.");
            RenderAsk();
        }
    }

    /// <summary>Reads the asked job from a job list; once it is done, fetches and shows the answer.</summary>
    private async Task FollowAskAsync(IReadOnlyList<WriterJob> jobs)
    {
        if (!askSession.IsAsking)
        {
            return;
        }

        var waiting = askSession.Latest;
        if (askSession.Finished(jobs) is not { } answerId)
        {
            if (!askSession.IsAsking)
            {
                RenderAsk();
            }

            return;
        }

        try
        {
            var answer = await asking.AnswerAsync(answerId, lifetime.Token);
            if (ReferenceEquals(askSession.Latest, waiting))
            {
                askSession.Answered(answer);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (ReferenceEquals(askSession.Latest, waiting))
            {
                askSession.Refused("Fyke couldn’t open the answer.");
            }
        }

        RenderAsk();
    }

    /// <summary>Draws the turns asked so far: the earlier questions, then the latest one's state or answer.</summary>
    private void RenderAsk()
    {
        briefRenderer.ClosePopover();
        AskColumn.Children.Clear();
        var latest = askSession.Latest;
        AskCopy.Visibility = AskRoutine.Visibility = latest?.Answer is null ? Visibility.Collapsed : Visibility.Visible;
        AskRoutine.IsEnabled = HasRoutineViews;
        AskSubmit.IsEnabled = !askSession.IsAsking && AskQuery.Text.Trim().Length > 0;
        if (latest is null)
        {
            AskColumn.Children.Add(briefRenderer.Title("Ask your feeds", 34, "AskTitle"));
            AskColumn.Children.Add(briefRenderer.Note(AskText.Intro(AskScope), 15, "BriefSoft"));
            if (askUnavailable)
            {
                AskColumn.Children.Add(briefRenderer.Note("This needs a newer Fyke service.", 13, "BriefMuted"));
            }

            AskField.Margin = new Thickness(0, 24, 0, 0);
            AutomationProperties.SetName(AskQuery, "Question");
            AskQuery.PlaceholderText = "Which posts disagree about…";
            AskColumn.Children.Add(AskField);
            return;
        }

        foreach (var earlier in askSession.Turns.Take(askSession.Turns.Count - 1))
        {
            AskColumn.Children.Add(briefRenderer.Note($"Earlier: {earlier.Question}", 13, "BriefMuted"));
        }

        AskColumn.Children.Add(briefRenderer.Tag("ASKED", AskText.Header(AskScope, latest.Answer)));
        AskColumn.Children.Add(briefRenderer.Title(latest.Question, 32, "AskQuestion"));
        if (latest.Answer is { } answer)
        {
            briefRenderer.AppendBody(AskColumn, answer, DateTimeOffset.Now, OpenAskSource);
            AskField.Margin = new Thickness(0, 32, 0, 0);
            AutomationProperties.SetName(AskQuery, "Follow-up question");
            AskQuery.PlaceholderText = "Ask a follow-up";
            AskColumn.Children.Add(AskField);
        }
        else if (latest.Problem is { } problem)
        {
            AskColumn.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Failed, "No answer",
                "This question was not answered", $"{problem} Nothing changed in your feeds.",
                askUnavailable ? null : ("Ask again", (Action)RetryAsk))));
        }
        else
        {
            AskColumn.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Working, "Answering",
                AskText.Working(AskScope), AskText.WorkingDetail,
                latest.JobId is { } job ? ("Cancel", (Action)(() => _ = CancelAskAsync(job))) : null)));
        }
    }

    private void RetryAsk()
    {
        if (askSession.Retract() is { } question)
        {
            AskQuery.Text = question;
            _ = SubmitAskAsync();
        }
    }

    private async Task CancelAskAsync(long job)
    {
        try
        {
            await asking.CancelAsync(job, lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowBulkNotice("Fyke couldn’t cancel the question. It may still be answered.");
        }
    }

    private void OpenAskSource(BriefCitation citation)
    {
        CloseAsk(restoreFocus: false);
        _ = OpenArticleAsync(new TimelineArticle(citation.Id, citation.DisplayTitle, citation.FeedTitle, citation.Read));
        FocusArticle();
    }

    private void AskShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected && !IsReaderOverlayOpen)
        {
            args.Handled = true;
            StartAsk();
        }
    }

    private void AskBackClicked(object sender, RoutedEventArgs args) => CloseAsk();

    private void AskCopyClicked(object sender, RoutedEventArgs args)
    {
        if (askSession.Latest?.Answer is { } answer)
        {
            var package = new DataPackage();
            package.SetText(AskText.Copy(answer));
            Clipboard.SetContent(package);
            ShowBulkNotice("Copied the answer.");
        }
    }

    private void AskSubmitClicked(object sender, RoutedEventArgs args) => _ = SubmitAskAsync();

    private void AskQueryChanged(object sender, TextChangedEventArgs args) =>
        AskSubmit.IsEnabled = !askSession.IsAsking && AskQuery.Text.Trim().Length > 0;

    private void AskQueryKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Enter)
        {
            args.Handled = true;
            _ = SubmitAskAsync();
        }
    }

    private void AskPaneKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape && !IsReaderOverlayOpen)
        {
            args.Handled = true;
            CloseAsk();
        }
    }
}
