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
/// A recipe, opened in place from the brief it wrote, as on macOS (gui/Sources/Reader/RecipeView.swift):
/// Edit it, Try it on the same articles without saving a brief, or go back through its History.
/// Every save is a new revision, and a brief keeps the revision it was written with.
/// </summary>
public sealed partial class MainWindow
{
    private readonly RecipeDraft recipeDraft = new();
    private readonly RecipeTrial recipeTrial = new();
    private readonly Dictionary<long, string> recipeRevisionTexts = [];
    private Recipes recipes = null!;
    private long recipeId;
    private Brief? recipeBrief;
    private CancellationTokenSource? recipeRequest;
    private IReadOnlyList<RecipeRevision> recipeRevisions = [];
    private long? openRevision;
    private bool recipeSaving;
    private bool applyingRecipeText;

    private bool IsRecipeShown => RecipePane.Visibility == Visibility.Visible;

    /// <summary>Opens a recipe. Opened from a brief, Back returns to it and saving writes the brief again.</summary>
    private void OpenRecipe(long id, long? briefId)
    {
        if (!readerConnected)
        {
            return;
        }

        CloseAsk(restoreFocus: false);
        CloseRoutines(restoreFocus: false);
        briefRenderer.ClosePopover();
        recipeId = id;
        recipeBrief = briefId is not null && shownBrief?.Id == briefId ? shownBrief : null;
        recipeDraft.Load(new Recipe { Id = id });
        recipeTrial.Reset();
        recipeRevisions = [];
        recipeRevisionTexts.Clear();
        openRevision = null;
        RecipeBackText.Text = recipeBrief is null ? "Back" : "Brief";
        RecipeSave.Content = recipeBrief is null ? "Save" : "Save and rewrite the brief";
        RecipeFixedNote.Text = RecipeText.Fixed;
        RecipeTrialIntro.Text = RecipeText.TrialIntro(recipeBrief);
        RecipeBarName.Text = string.Empty;
        RecipeTabs.SelectedItem = RecipeEditTab;
        RecipePane.Visibility = Visibility.Visible;
        RecipeBody.Visibility = Visibility.Collapsed;
        RecipeState.Visibility = Visibility.Collapsed;
        RecipeLoading.Visibility = Visibility.Visible;
        RecipeLoading.IsActive = true;
        RecipeBack.Focus(FocusState.Programmatic);
        _ = LoadRecipeAsync();
    }

    private void CloseRecipe(bool restoreFocus = true)
    {
        if (!IsRecipeShown)
        {
            return;
        }

        recipeRequest?.Cancel();
        briefRenderer.ClosePopover();
        RecipePane.Visibility = Visibility.Collapsed;
        RecipeTrialColumn.Children.Clear();
        RecipeHistoryPage.Children.Clear();
        if (restoreFocus)
        {
            if (IsTodayShown && openArticle is null)
            {
                TodayScroller.Focus(FocusState.Programmatic);
            }
            else
            {
                FocusArticle();
            }
        }
    }

    private async Task LoadRecipeAsync()
    {
        recipeRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        recipeRequest = request;
        try
        {
            var recipe = await recipes.GetAsync(recipeId, request.Token);
            request.Token.ThrowIfCancellationRequested();
            recipeDraft.Load(recipe);
            RecipeLoading.IsActive = false;
            RecipeLoading.Visibility = Visibility.Collapsed;
            RecipeBody.Visibility = Visibility.Visible;
            ShowRecipeText();
            RenderRecipe();
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            RecipeLoading.IsActive = false;
            RecipeLoading.Visibility = Visibility.Collapsed;
            RecipeState.Children.Clear();
            RecipeState.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Failed, "Recipe",
                "This recipe could not be opened", $"{RecipeProblem(error)} The brief and its recipe are unchanged.",
                (recipeBrief is null ? "Back" : "Back to the brief", () => CloseRecipe()))));
            RecipeState.Visibility = Visibility.Visible;
        }
        finally
        {
            if (ReferenceEquals(recipeRequest, request))
            {
                recipeRequest = null;
            }
        }
    }

    /// <summary>Puts the draft's text in the editor without counting it as an edit.</summary>
    private void ShowRecipeText()
    {
        applyingRecipeText = true;
        try
        {
            RecipeEditor.Text = recipeDraft.Text;
        }
        finally
        {
            applyingRecipeText = false;
        }
    }

    /// <summary>Draws the header and the Edit page's state: conflict, unsaved changes, and which actions apply.</summary>
    private void RenderRecipe(string? problem = null)
    {
        if (recipeDraft.Recipe is not { } recipe)
        {
            return;
        }

        RecipeTitle.Text = recipe.DisplayName;
        RecipeBarName.Text = $"{recipe.DisplayName} recipe";
        RecipeSubtitle.Text = RecipeText.Subtitle(recipe, CurrentWriterName, DateTimeOffset.Now);
        var conflict = recipeDraft.Conflict;
        RecipeConflict.Visibility = conflict is null ? Visibility.Collapsed : Visibility.Visible;
        if (conflict is not null)
        {
            RecipeConflictTitle.Text = RecipeText.ConflictTitle(conflict);
            RecipeConflictDetail.Text = RecipeText.ConflictDetail;
        }

        var dirty = recipeDraft.IsDirty;
        RecipeDirtyDot.Visibility = dirty ? Visibility.Visible : Visibility.Collapsed;
        RecipeStatus.Text = dirty ? "Unsaved changes" : problem ?? string.Empty;
        RecipeReset.Visibility = recipe.Builtin ? Visibility.Visible : Visibility.Collapsed;
        RecipeReset.IsEnabled = !recipeSaving;
        RecipeRevert.IsEnabled = dirty && !recipeSaving;
        RecipeSave.IsEnabled = recipeDraft.CanSave && !recipeSaving;
        RecipeTryButton.Content = recipeTrial.Result is null ? "Try it" : "Try again";
        RecipeTryButton.IsEnabled = !recipeTrial.IsRunning && recipeDraft.Text.Trim().Length > 0;
    }

    private void RecipeEditorChanged(object sender, TextChangedEventArgs args)
    {
        if (!applyingRecipeText)
        {
            recipeDraft.Text = RecipeEditor.Text;
            RenderRecipe();
        }
    }

    /// <summary>Saves the text as a new revision. Opened from a brief, the brief is written again with it.</summary>
    private async Task SaveRecipeAsync(long? overRevision = null)
    {
        if (recipeDraft.Recipe is not { } recipe || recipeSaving || (overRevision is null && !recipeDraft.CanSave))
        {
            return;
        }

        recipeSaving = true;
        RenderRecipe();
        string? problem = null;
        try
        {
            var saved = await recipes.SaveAsync(recipe, recipeDraft.Text, overRevision ?? recipe.Revision, lifetime.Token);
            recipeDraft.Load(saved);
            ShowRecipeText();
            if (recipeBrief is { } brief)
            {
                await RewriteBriefAsync(brief.ViewId, saved.Id);
                return;
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (RecipeConflictException conflict)
        {
            recipeDraft.Conflicted(conflict.Current);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            problem = RecipeProblem(error);
        }
        finally
        {
            recipeSaving = false;
        }

        RenderRecipe(problem);
    }

    /// <summary>Writes the brief again with the saved recipe and shows Today, where it arrives.</summary>
    private async Task RewriteBriefAsync(long? viewId, long savedRecipe)
    {
        CloseRecipe(restoreFocus: false);
        try
        {
            await briefs.RunAsync(viewId, savedRecipe, lifetime.Token);
            selectedBriefId = null;
            shownTodayKey = null;
            if (openArticle is not null)
            {
                _ = OpenArticleAsync(null);
            }

            await LoadTodayAsync();
            TodayScroller.Focus(FocusState.Programmatic);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowBulkNotice($"The recipe is saved, but Fyke couldn’t write the brief. {RecipeProblem(error)}");
        }
    }

    private async Task ResetRecipeAsync()
    {
        if (recipeDraft.Recipe is not { Builtin: true } recipe || recipeSaving)
        {
            return;
        }

        recipeSaving = true;
        RenderRecipe();
        string? problem = null;
        try
        {
            recipeDraft.Load(await recipes.ResetAsync(recipe, lifetime.Token));
            ShowRecipeText();
            ShowBulkNotice($"Reset “{recipe.DisplayName}” to the built-in text. The earlier text stays in History.");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (RecipeConflictException conflict)
        {
            recipeDraft.Conflicted(conflict.Current);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            problem = RecipeProblem(error);
        }
        finally
        {
            recipeSaving = false;
        }

        RenderRecipe(problem);
    }

    /// <summary>A recipe saved elsewhere replaces the one shown unless it has edits; the trial and history follow their jobs.</summary>
    private async Task FollowRecipeAsync(TodaySnapshot snapshot)
    {
        if (!IsRecipeShown || recipeDraft.Recipe is not { } recipe)
        {
            return;
        }

        if (snapshot.Recipes.FirstOrDefault(row => row.Id == recipe.Id) is { } listed && listed.Revision != recipe.Revision
            && !recipeDraft.IsDirty && !recipeSaving)
        {
            try
            {
                if (recipeDraft.Refresh(await recipes.GetAsync(recipe.Id, lifetime.Token)))
                {
                    ShowRecipeText();
                    RenderRecipe();
                    if (RecipeTabs.SelectedItem == RecipeHistoryTab)
                    {
                        _ = LoadRecipeHistoryAsync();
                    }
                }
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
            {
                // The next change reads it again.
            }
        }

        await FollowTrialAsync(snapshot.Jobs);
    }

    private async Task TryRecipeAsync()
    {
        if (recipeDraft.Recipe is not { } recipe || recipeTrial.IsRunning || recipeDraft.Text.Trim().Length == 0)
        {
            return;
        }

        recipeTrial.Reset();
        try
        {
            var job = await recipes.TryAsync(recipe.Id, recipeDraft.Text, recipeBrief?.ViewId, lifetime.Token);
            recipeTrial.Started(job.Id);
            RenderTrial();
            await FollowTrialAsync([job]);
            // A trial that finished before it was started here has no change left to report.
            _ = LoadTodayAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            recipeTrial.Failed(RecipeProblem(error));
            RenderTrial();
        }
    }

    private async Task FollowTrialAsync(IReadOnlyList<WriterJob> jobs)
    {
        if (!recipeTrial.IsRunning)
        {
            return;
        }

        var job = recipeTrial.JobId;
        if (recipeTrial.Finished(jobs) is { } artifact)
        {
            try
            {
                var result = await recipes.TrialAsync(artifact, lifetime.Token);
                if (recipeTrial.JobId == job)
                {
                    recipeTrial.Written(result);
                }
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
            {
                return;
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
            {
                if (recipeTrial.JobId == job)
                {
                    recipeTrial.Failed(RecipeProblem(error));
                }
            }
        }

        if (!recipeTrial.IsRunning)
        {
            RenderTrial();
        }
    }

    private void RenderTrial()
    {
        briefRenderer.ClosePopover();
        RecipeTrialColumn.Children.Clear();
        RenderRecipe();
        if (recipeTrial.IsRunning && recipeTrial.JobId is { } job)
        {
            RecipeTrialColumn.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Working, "Trying the recipe",
                "Writing a trial brief", RecipeText.TrialWorkingDetail, ("Cancel", () => _ = CancelTrialAsync(job)))));
        }
        else if (recipeTrial.Problem is { } problem)
        {
            RecipeTrialColumn.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Failed, "Trial failed",
                "The trial did not finish", $"{problem} The recipe and your briefs are unchanged.",
                ("Try again", () => _ = TryRecipeAsync()))));
        }
        else if (recipeTrial.Result is { } result)
        {
            RecipeTrialColumn.Children.Add(briefRenderer.Tag("TRIAL · NOT SAVED", string.Empty));
            RecipeTrialColumn.Children.Add(briefRenderer.Title(result.DisplayTitle, 28, "RecipeTrialTitle"));
            briefRenderer.AppendBody(RecipeTrialColumn, result, DateTimeOffset.Now, OpenRecipeSource);
        }
    }

    private async Task CancelTrialAsync(long job)
    {
        try
        {
            await briefs.CancelAsync(job, lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowBulkNotice("Fyke couldn’t cancel the trial. It may still finish.");
        }
    }

    private void OpenRecipeSource(BriefCitation citation)
    {
        CloseRecipe(restoreFocus: false);
        _ = OpenArticleAsync(new TimelineArticle(citation.Id, citation.DisplayTitle, citation.FeedTitle, citation.Read));
        FocusArticle();
    }

    private async Task LoadRecipeHistoryAsync()
    {
        try
        {
            recipeRevisions = await recipes.HistoryAsync(recipeId, lifetime.Token);
            RenderRecipeHistory();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            RecipeHistoryPage.Children.Clear();
            RecipeHistoryPage.Children.Add(briefRenderer.Note(RecipeProblem(error), 13, "BriefMuted"));
        }
    }

    /// <summary>Each revision as a row that opens to its text; an older one can be put back in Edit.</summary>
    private void RenderRecipeHistory()
    {
        RecipeHistoryPage.Children.Clear();
        var current = recipeDraft.Recipe?.Revision;
        var now = DateTimeOffset.Now;
        foreach (var revision in recipeRevisions)
        {
            var open = openRevision == revision.Revision;
            var row = new Grid { ColumnSpacing = 12, Height = 44 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var name = briefRenderer.Note(RecipeText.Revision(revision) + (revision.Revision == current ? "  current" : string.Empty),
                14, "BriefInk");
            name.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(name);
            var note = briefRenderer.Note(revision.Note ?? string.Empty, 13, "BriefSoft");
            note.TextWrapping = TextWrapping.NoWrap;
            note.TextTrimming = TextTrimming.CharacterEllipsis;
            note.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(note, 1);
            row.Children.Add(note);
            var when = briefRenderer.Note(BriefText.Time(revision.CreatedAt) is { } date ? BriefText.Relative(date, now) : string.Empty,
                12, "BriefMuted");
            when.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(when, 2);
            row.Children.Add(when);
            var chevron = new FontIcon { Glyph = open ? "" : "", FontSize = 10, Style = AppResources.FromApp<Style>("BriefSoftIcon") };
            Grid.SetColumn(chevron, 3);
            row.Children.Add(chevron);
            var toggle = new Button
            {
                Style = AppResources.FromApp<Style>("RecipeRevisionRow"),
                Content = row,
            };
            // A Button has no expand pattern, so the name says whether the text is shown.
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle,
                $"{RecipeText.Revision(revision)}{(revision.Revision == current ? ", current" : string.Empty)}, {revision.Note}, {(open ? "shown" : "hidden")}");
            var number = revision.Revision;
            toggle.Click += (_, _) => _ = ToggleRevisionAsync(revision);
            RecipeHistoryPage.Children.Add(toggle);
            if (!open)
            {
                continue;
            }

            var text = revision.Text ?? (recipeRevisionTexts.TryGetValue(number, out var read) ? read : null);
            var body = briefRenderer.Note(text ?? "…", 12, "BriefSoft");
            body.FontFamily = AppResources.FromApp<Microsoft.UI.Xaml.Media.FontFamily>("FontCode");
            body.IsTextSelectionEnabled = true;
            RecipeHistoryPage.Children.Add(new Border { Style = AppResources.FromApp<Style>("RecipeRevisionText"), Child = body });
            if (number != current && text is not null)
            {
                var restore = new Button
                {
                    Content = "Put this text in Edit",
                    Style = AppResources.FromApp<Style>("BriefSecondaryAction"),
                    Margin = new Thickness(0, 0, 0, 12),
                };
                restore.Click += (_, _) =>
                {
                    recipeDraft.Text = text;
                    ShowRecipeText();
                    RecipeTabs.SelectedItem = RecipeEditTab;
                    RecipeEditor.Focus(FocusState.Programmatic);
                };
                RecipeHistoryPage.Children.Add(restore);
            }
        }
    }

    private async Task ToggleRevisionAsync(RecipeRevision revision)
    {
        openRevision = openRevision == revision.Revision ? null : revision.Revision;
        RenderRecipeHistory();
        if (openRevision is null || revision.Text is not null || recipeRevisionTexts.ContainsKey(revision.Revision))
        {
            return;
        }

        try
        {
            recipeRevisionTexts[revision.Revision] = await recipes.RevisionTextAsync(recipeId, revision.Revision, lifetime.Token);
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            recipeRevisionTexts[revision.Revision] = RecipeProblem(error);
        }

        RenderRecipeHistory();
    }

    private static string RecipeProblem(Exception error) =>
        error is DaemonRpcException { Message.Length: > 0 } refusal ? refusal.Message.TrimEnd('.') + "."
        : "Fyke couldn’t reach its service.";

    private void RecipeTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var selected = sender.SelectedItem;
        RecipeEditPage.Visibility = selected == RecipeEditTab ? Visibility.Visible : Visibility.Collapsed;
        RecipeTryPage.Visibility = selected == RecipeTryTab ? Visibility.Visible : Visibility.Collapsed;
        RecipeHistoryPage.Visibility = selected == RecipeHistoryTab ? Visibility.Visible : Visibility.Collapsed;
        if (selected == RecipeTryTab)
        {
            RenderTrial();
        }
        else if (selected == RecipeHistoryTab && IsRecipeShown)
        {
            _ = LoadRecipeHistoryAsync();
        }
    }

    private void TodayRecipeClicked(object sender, RoutedEventArgs args)
    {
        if (today.RecipeFor(selectedBriefId) is { } id)
        {
            OpenRecipe(id, today.Selected(selectedBriefId)?.Id);
        }
    }

    private void RecipeBackClicked(object sender, RoutedEventArgs args) => CloseRecipe();

    private void RecipeSaveClicked(object sender, RoutedEventArgs args) => _ = SaveRecipeAsync();

    private void RecipeRevertClicked(object sender, RoutedEventArgs args)
    {
        recipeDraft.Revert();
        ShowRecipeText();
        RenderRecipe();
    }

    private void RecipeResetClicked(object sender, RoutedEventArgs args) => _ = ResetRecipeAsync();

    private void RecipeKeepMineClicked(object sender, RoutedEventArgs args)
    {
        if (recipeDraft.KeepMine() is { } revision)
        {
            _ = SaveRecipeAsync(revision);
        }
    }

    private void RecipeTakeTheirsClicked(object sender, RoutedEventArgs args)
    {
        recipeDraft.TakeTheirs();
        ShowRecipeText();
        RenderRecipe();
    }

    private void RecipeTryClicked(object sender, RoutedEventArgs args) => _ = TryRecipeAsync();

    private void SaveRecipeShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (RecipeTabs.SelectedItem == RecipeEditTab && !IsReaderOverlayOpen)
        {
            args.Handled = true;
            _ = SaveRecipeAsync();
        }
    }

    // Escape leaves the recipe unless it has unsaved edits, which Back or Revert decide about.
    private void RecipePaneKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape && !IsReaderOverlayOpen && !recipeDraft.IsDirty)
        {
            args.Handled = true;
            CloseRecipe();
        }
    }
}
