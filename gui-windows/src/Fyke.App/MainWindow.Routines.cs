using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

/// <summary>
/// Routines, as on macOS (gui/Sources/Reader/Routines.swift): the list beside When / Look in / Then
/// for the chosen one, and a dry run over last week. The page covers the list and the reader, as
/// Settings does. A routine runs in the daemon, so nothing here schedules anything.
/// </summary>
public sealed partial class MainWindow
{
    private readonly ObservableCollection<RoutineListItem> routineRows = [];
    private readonly RoutineEditing routineEditing = new();
    private Routines routines = null!;
    private CancellationTokenSource? routinesRequest;
    private CancellationTokenSource? routineDryRunRequest;
    private Control? focusBeforeRoutines;
    private RoutineDryRun? routineDryRun;
    private long? routineDryRunId;
    private string? routineDryRunProblem;
    private string? routineProblem;
    private string? routinesProblem;
    private Func<Task>? routineUndo;
    private int routineChangesPending;
    private bool routinesListed;
    private bool routineSaving;
    private bool applyingRoutine;

    private bool IsRoutinesShown => RoutinesPane?.Visibility == Visibility.Visible;

    private IEnumerable<ReaderDestination> RoutineViews => catalog.Where(item => item.Scope == ReaderScope.View);

    private bool HasRoutineViews => RoutineViews.Any();

    private void InitializeRoutines()
    {
        routines = new Routines(client);
        RoutineRows.ItemsSource = routineRows;
        RoutineBackground.Text = RoutineText.Background;
        RoutineLookIn.Text = RoutineText.LookIn;
        foreach (var repeat in RoutineText.Repeats)
        {
            RoutineRepeat.Items.Add(RoutineText.RepeatWords(repeat));
        }

        foreach (var time in RoutineText.HalfHours)
        {
            RoutineTime.Items.Add(time);
        }

        foreach (var kind in RoutineText.ActionKinds)
        {
            var item = new MenuFlyoutItem { Text = RoutineText.Title(kind), Icon = new FontIcon { Glyph = RoutineText.Glyph(kind) } };
            item.Click += (_, _) => AddRoutineActionOf(kind);
            AddRoutineActionMenu.Items.Add(item);
        }
    }

    /// <summary>Routine changes and gaps reload the list, wherever the reader is, so the sidebar's next run stays true.</summary>
    private void QueueRoutineChange(DaemonEvent change)
    {
        if (Routines.Concerns(change) && Interlocked.Exchange(ref routineChangesPending, 1) == 0)
        {
            _ = DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref routineChangesPending, 0);
                if (readerConnected && !lifetime.IsCancellationRequested)
                {
                    _ = LoadRoutinesAsync();
                }
            });
        }
    }

    private void StopRoutines()
    {
        routinesRequest?.Cancel();
        routineDryRunRequest?.Cancel();
        CloseRoutines(restoreFocus: false);
        routineEditing.Clear();
        routinesListed = false;
        routineDryRun = null;
        routineDryRunId = null;
        routineUndo = null;
        RoutinesNext.Text = string.Empty;
    }

    private void RoutinesClicked(object sender, RoutedEventArgs args) => OpenRoutines();

    private void RoutinesShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (readerConnected && !IsReaderOverlayOpen)
        {
            args.Handled = true;
            OpenRoutines();
        }
    }

    private void OpenRoutines()
    {
        if (!readerConnected || viewDialogOpen || !CloseAddFeed() || !CloseCatalogEdit())
        {
            return;
        }

        ClosePalette();
        CloseSearch();
        CloseAsk(restoreFocus: false);
        CloseRecipe(restoreFocus: false);
        CloseSettings(restoreFocus: false);
        if (!IsRoutinesShown)
        {
            focusBeforeRoutines = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
            Destinations.IsItemClickEnabled = true;
            RoutineListColumn.Width = TimelineColumn.Width;
            TimelinePane.Visibility = TimelineDivider.Visibility = ArticlePane.Visibility = Visibility.Collapsed;
            RoutinesPane.Visibility = Visibility.Visible;
            if (!routinesListed)
            {
                _ = LoadRoutinesAsync();
            }
        }

        RenderRoutines();
        if (routineEditing.Editing?.Id != routineDryRunId || routineDryRun is null)
        {
            _ = LoadRoutineDryRunAsync();
        }

        if (routineRows.Count > 0)
        {
            RoutineRows.Focus(FocusState.Programmatic);
        }
        else
        {
            NewRoutineButton.Focus(FocusState.Programmatic);
        }
    }

    private void CloseRoutines(bool restoreFocus = true)
    {
        if (!IsRoutinesShown)
        {
            return;
        }

        routineDryRunRequest?.Cancel();
        ShowRoutineName(editing: false);
        RoutinesPane.Visibility = Visibility.Collapsed;
        Destinations.IsItemClickEnabled = false;
        TimelinePane.Visibility = TimelineDivider.Visibility = ArticlePane.Visibility = Visibility.Visible;
        if (restoreFocus && focusBeforeRoutines?.Focus(FocusState.Programmatic) != true)
        {
            RoutinesButton.Focus(FocusState.Programmatic);
        }

        focusBeforeRoutines = null;
    }

    private void RoutinesKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Handled || args.Key != VirtualKey.Escape || IsReaderOverlayOpen)
        {
            return;
        }

        args.Handled = true;
        if (RoutineNameBox.Visibility == Visibility.Visible)
        {
            ShowRoutineName(editing: false);
            RoutineTitleButton.Focus(FocusState.Programmatic);
        }
        else
        {
            CloseRoutines();
        }
    }

    /// <summary>Starts a routine over a view, as macOS does: named for the view, weekdays at 07:30, brief and notify.</summary>
    private void StartRoutine(long? viewId = null, string? name = null, IReadOnlyList<RoutineAction>? actions = null)
    {
        var views = RoutineViews.ToList();
        var view = views.FirstOrDefault(item => item.Id == viewId)
            ?? (destination is { Scope: ReaderScope.View } current ? current : null)
            ?? views.FirstOrDefault();
        if (view is null)
        {
            return;
        }

        var recipe = today.Recipes.Count > 0 ? today.Recipes[0].Id : (long?)null;
        routineEditing.Start(Routine.Draft(view.Id, view.Title, recipe, name, actions));
        routineProblem = null;
        OpenRoutines();
        RoutineTitleButton.Focus(FocusState.Programmatic);
    }

    private void NewRoutineClicked(object sender, RoutedEventArgs args) => StartRoutine();

    private void AskRoutineClicked(object sender, RoutedEventArgs args)
    {
        if (askSession.Latest?.Question is { Length: > 0 } question)
        {
            var name = question.Trim();
            StartRoutine(askSession.ViewId, name.Length > 60 ? name[..60].TrimEnd() : name,
                [new RoutineAction { Kind = "brief" }, new RoutineAction { Kind = "notify" }]);
        }
    }

    private async Task LoadRoutinesAsync()
    {
        if (!readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        routinesRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        routinesRequest = request;
        try
        {
            var list = await routines.ListAsync(request.Token);
            request.Token.ThrowIfCancellationRequested();
            routineEditing.Load(list);
            routinesListed = true;
            routinesProblem = null;
            RenderRoutines();
            if (IsRoutinesShown && routineEditing.Editing?.Id != routineDryRunId)
            {
                _ = LoadRoutineDryRunAsync();
            }
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            routinesProblem = $"Fyke couldn’t read your routines. {RoutineText.Problem(error)}";
            RenderRoutines();
        }
        finally
        {
            if (ReferenceEquals(routinesRequest, request))
            {
                routinesRequest = null;
            }
        }
    }

    /// <summary>The sidebar's next run, then the list and the editor when the page is shown.</summary>
    private void RenderRoutines()
    {
        RoutinesNext.Text = RoutineText.SidebarNext(routineEditing.Saved) ?? string.Empty;
        if (!IsRoutinesShown)
        {
            return;
        }

        RenderRoutineRows();
        RenderRoutineEditor();
    }

    private void RenderRoutineRows()
    {
        var now = DateTimeOffset.Now;
        var rows = routineEditing.Rows.Select(routine => RoutineListItem.From(routine, now)).ToList();
        applyingRoutine = true;
        try
        {
            for (var index = 0; index < rows.Count; index++)
            {
                if (index >= routineRows.Count)
                {
                    routineRows.Add(rows[index]);
                }
                else if (routineRows[index] != rows[index])
                {
                    routineRows[index] = rows[index];
                }
            }

            while (routineRows.Count > rows.Count)
            {
                routineRows.RemoveAt(routineRows.Count - 1);
            }

            RoutineRows.SelectedItem = routineRows.FirstOrDefault(row => routineEditing.IsEditing(row.Routine));
        }
        finally
        {
            applyingRoutine = false;
        }

        var hasViews = HasRoutineViews;
        NewRoutineButton.IsEnabled = hasViews;
        RoutinesEmpty.Text = routinesProblem ?? RoutineText.Empty(hasViews);
        RoutinesEmpty.Visibility = routinesProblem is not null || (routinesListed && rows.Count == 0)
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void RenderRoutineEditor()
    {
        var routine = routineEditing.Editing;
        RemoveRoutine.Visibility = routine is { IsSaved: true } ? Visibility.Visible : Visibility.Collapsed;
        if (routine is null)
        {
            var hasViews = HasRoutineViews;
            RoutineEditor.Visibility = Visibility.Collapsed;
            RoutineNone.Children.Clear();
            RoutineNone.Children.Add(briefRenderer.State(new InlineStateView(InlineTone.Empty, "Routines",
                RoutineText.NoneTitle(hasViews), RoutineText.NoneDetail(hasViews),
                hasViews ? ("New routine", (Action)(() => StartRoutine())) : ("Search", (Action)OpenSearch))));
            RoutineNone.Visibility = Visibility.Visible;
            return;
        }

        RoutineNone.Visibility = Visibility.Collapsed;
        RoutineEditor.Visibility = Visibility.Visible;
        applyingRoutine = true;
        try
        {
            RoutineTitle.Text = routine.Name;
            AutomationProperties.SetName(RoutineTitleButton, $"{routine.Name}, rename");
            var repeat = RoutineText.Repeats.ToList().FindIndex(option => option.Kind == routine.Schedule.Kind
                && (option.Days is null || option.Equals(routine.Schedule with { Time = null })));
            RoutineRepeat.SelectedIndex = repeat;
            RoutineRepeat.PlaceholderText = repeat < 0 ? RoutineText.RepeatWords(routine.Schedule) : string.Empty;
            var timed = !routine.Schedule.IsManual;
            RoutineAt.Visibility = RoutineTime.Visibility = timed ? Visibility.Visible : Visibility.Collapsed;
            // A time set elsewhere off the half hour shows as the placeholder.
            var time = routine.Schedule.Time ?? RoutineText.DefaultTime;
            RoutineTime.SelectedIndex = RoutineText.HalfHours.ToList().IndexOf(time);
            RoutineTime.PlaceholderText = time;

            RoutineView.Items.Clear();
            foreach (var view in RoutineViews)
            {
                var item = new ComboBoxItem { Content = view.Title, Tag = view.Id };
                if (!string.IsNullOrWhiteSpace(view.RuleSummary))
                {
                    ToolTipService.SetToolTip(item, view.RuleSummary);
                }

                RoutineView.Items.Add(item);
                if (view.Id == routine.ViewId)
                {
                    RoutineView.SelectedItem = item;
                }
            }

            RenderRoutineActions(routine);
        }
        finally
        {
            applyingRoutine = false;
        }

        UpdateRoutineFooter();
        RenderRoutineDryRun();
    }

    /// <summary>After the catalog reloads: the view menu and New routine follow, without disturbing typing.</summary>
    private void RefreshRoutineViews()
    {
        AskRoutine.IsEnabled = HasRoutineViews;
        if (!IsRoutinesShown)
        {
            return;
        }

        NewRoutineButton.IsEnabled = HasRoutineViews;
        var shown = RoutineView.Items.OfType<ComboBoxItem>().Select(item => $"{item.Tag}:{item.Content}");
        if (!shown.SequenceEqual(RoutineViews.Select(view => $"{view.Id}:{view.Title}")))
        {
            RenderRoutines();
        }
    }

    private void RenderRoutineActions(Routine routine)
    {
        RoutineActions.Children.Clear();
        for (var index = 0; index < routine.Actions.Count; index++)
        {
            RoutineActions.Children.Add(RoutineActionRow(routine.Actions[index], index));
        }
    }

    /// <summary>One action: its icon and words, a recipe menu or tag field where it takes one, and remove.</summary>
    private Border RoutineActionRow(RoutineAction action, int index)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new FontIcon
        {
            Glyph = RoutineText.Glyph(action.Kind), FontSize = 12, VerticalAlignment = VerticalAlignment.Center,
            Style = AppResources.FromApp<Style>("BriefSoftIcon"),
        };
        row.Children.Add(icon);

        var words = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(words, 1);
        row.Children.Add(words);
        switch (action.Kind)
        {
            case "brief":
                words.Children.Add(RoutineWords("Write a brief with"));
                words.Children.Add(RoutineRecipeMenu(action, index));
                break;
            case "tag":
                words.Children.Add(RoutineWords(RoutineText.Title(action.Kind)));
                var tag = new TextBox
                {
                    Text = action.Tag ?? string.Empty, PlaceholderText = "tag", Width = 120, MinHeight = 28, FontSize = 13,
                    Padding = new Thickness(8, 3, 8, 3), MaxLength = 64, FontFamily = BriefRows.FontFamily,
                };
                AutomationProperties.SetName(tag, "Tag");
                tag.TextChanged += (_, _) =>
                {
                    if (!applyingRoutine)
                    {
                        EditRoutineAction(index, changed => changed with { Tag = tag.Text });
                    }
                };
                words.Children.Add(tag);
                break;
            default:
                words.Children.Add(RoutineWords(RoutineText.Title(action.Kind)));
                break;
        }

        if (action.Kind == "brief")
        {
            var writer = briefRenderer.Note(CurrentWriterName ?? "No writer", 12, "BriefMuted");
            writer.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(writer, 2);
            row.Children.Add(writer);
        }

        var remove = new Button
        {
            Width = 24, Height = 24, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
            Style = AppResources.FromApp<Style>("BriefPlainButton"), Content = new FontIcon { Glyph = "", FontSize = 10 },
        };
        AutomationProperties.SetName(remove, "Remove this action");
        AutomationProperties.SetAutomationId(remove, $"RemoveRoutineAction_{index}");
        ToolTipService.SetToolTip(remove, "Remove this action");
        remove.Click += (_, _) => EditRoutine(routine => routine with
        {
            Actions = [.. routine.Actions.Where((_, position) => position != index)],
        }, render: true);
        Grid.SetColumn(remove, 3);
        row.Children.Add(remove);

        var border = new Border { Style = AppResources.FromApp<Style>("RoutineActionRow"), Child = row };
        AutomationProperties.SetName(border, RoutineText.Title(action.Kind));
        return border;
    }

    private TextBlock RoutineWords(string text)
    {
        var words = briefRenderer.Note(text, 14, "BriefInk");
        words.VerticalAlignment = VerticalAlignment.Center;
        return words;
    }

    private ComboBox RoutineRecipeMenu(RoutineAction action, int index)
    {
        var menu = new ComboBox { MinWidth = 140, PlaceholderText = "a recipe", FontSize = 13 };
        AutomationProperties.SetName(menu, "Recipe");
        AutomationProperties.SetAutomationId(menu, $"RoutineRecipe_{index}");
        foreach (var recipe in today.Recipes)
        {
            var item = new ComboBoxItem { Content = recipe.Name ?? "Recipe", Tag = recipe.Id };
            menu.Items.Add(item);
            if (recipe.Id == action.RecipeId)
            {
                menu.SelectedItem = item;
            }
        }

        menu.SelectionChanged += (_, _) =>
        {
            if (!applyingRoutine && menu.SelectedItem is ComboBoxItem { Tag: long id })
            {
                EditRoutineAction(index, changed => changed with { RecipeId = id });
            }
        };
        return menu;
    }

    private void AddRoutineActionOf(string kind)
    {
        var recipe = kind == "brief" && today.Recipes.Count > 0 ? today.Recipes[0].Id : (long?)null;
        EditRoutine(routine => routine with { Actions = [.. routine.Actions, new RoutineAction { Kind = kind, RecipeId = recipe }] },
            render: true);
    }

    private void EditRoutineAction(int index, Func<RoutineAction, RoutineAction> change) =>
        EditRoutine(routine => index < routine.Actions.Count
            ? routine with { Actions = [.. routine.Actions.Select((action, position) => position == index ? change(action) : action)] }
            : routine);

    /// <summary>Changes the edited copy. Rendering again is only needed when the controls' shape changes.</summary>
    private void EditRoutine(Func<Routine, Routine> change, bool render = false)
    {
        if (applyingRoutine || routineEditing.Editing is null)
        {
            return;
        }

        routineEditing.Edit(change);
        routineProblem = null;
        if (render)
        {
            RenderRoutines();
        }
        else
        {
            UpdateRoutineFooter();
        }
    }

    private void RoutineRepeatChanged(object sender, SelectionChangedEventArgs args)
    {
        if (RoutineRepeat.SelectedIndex is var index and >= 0 && index < RoutineText.Repeats.Count)
        {
            var option = RoutineText.Repeats[index];
            EditRoutine(routine => routine with
            {
                Schedule = option with { Time = option.IsManual ? null : routine.Schedule.Time ?? RoutineText.DefaultTime },
            }, render: true);
        }
    }

    private void RoutineTimeChanged(object sender, SelectionChangedEventArgs args)
    {
        if (RoutineTime.SelectedIndex is var index and >= 0 && index < RoutineText.HalfHours.Count)
        {
            var time = RoutineText.HalfHours[index];
            EditRoutine(routine => routine with { Schedule = routine.Schedule with { Time = time } });
        }
    }

    private void RoutineViewChanged(object sender, SelectionChangedEventArgs args)
    {
        if (RoutineView.SelectedItem is ComboBoxItem { Tag: long id })
        {
            EditRoutine(routine => routine with { ViewId = id });
        }
    }

    private void RoutineRowChanged(object sender, SelectionChangedEventArgs args)
    {
        if (applyingRoutine || RoutineRows.SelectedItem is not RoutineListItem item || routineEditing.IsEditing(item.Routine))
        {
            return;
        }

        CommitRoutineName();
        routineEditing.Select(item.Routine);
        routineProblem = null;
        RenderRoutineEditor();
        _ = LoadRoutineDryRunAsync();
    }

    private void RoutineEnabledToggled(object sender, RoutedEventArgs args)
    {
        if (sender is ToggleSwitch { DataContext: RoutineListItem { CanToggle: true } item } toggle && toggle.IsOn != item.Enabled)
        {
            _ = SetRoutineEnabledAsync(item.Routine, toggle.IsOn);
        }
    }

    /// <summary>The list's switch saves at once, as on macOS; the list then reloads with the new revision.</summary>
    private async Task SetRoutineEnabledAsync(Routine routine, bool enabled)
    {
        try
        {
            await routines.SaveAsync(routine with { Enabled = enabled }, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is RoutineConflictException or DaemonException or TimeoutException or JsonException)
        {
            ShowBulkNotice(error is RoutineConflictException
                ? $"“{routine.Name}” changed elsewhere. Try again."
                : $"Fyke couldn’t {(enabled ? "resume" : "pause")} “{routine.Name}”. {RoutineText.Problem(error)}");
        }

        await LoadRoutinesAsync();
    }

    private void RenameRoutineClicked(object sender, RoutedEventArgs args) => ShowRoutineName(editing: true);

    private void ShowRoutineName(bool editing)
    {
        RoutineNameBox.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        RoutineTitleButton.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
        if (editing)
        {
            RoutineNameBox.Text = routineEditing.Editing?.Name ?? string.Empty;
            RoutineNameBox.Focus(FocusState.Programmatic);
            RoutineNameBox.SelectAll();
        }
    }

    private void RoutineNameKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Enter)
        {
            args.Handled = true;
            CommitRoutineName();
            RoutineTitleButton.Focus(FocusState.Programmatic);
        }
    }

    private void RoutineNameLostFocus(object sender, RoutedEventArgs args) => CommitRoutineName();

    /// <summary>Takes the typed name; an empty one keeps the old name.</summary>
    private void CommitRoutineName()
    {
        if (RoutineNameBox.Visibility != Visibility.Visible)
        {
            return;
        }

        var name = RoutineNameBox.Text.Trim();
        ShowRoutineName(editing: false);
        if (name.Length > 0 && name != routineEditing.Editing?.Name)
        {
            EditRoutine(routine => routine with { Name = name }, render: true);
        }
    }

    private void UpdateRoutineFooter()
    {
        if (routineEditing.Editing is not { } routine)
        {
            return;
        }

        RoutineFooter.Text = routineProblem ?? RoutineText.Next(routine, routineEditing.Original, routineEditing.Dirty);
        RunRoutine.IsEnabled = routine.IsSaved && !routineSaving;
        SaveRoutine.IsEnabled = routineEditing.CanSave && !routineSaving;
    }

    private void SaveRoutineClicked(object sender, RoutedEventArgs args) => _ = SaveRoutineAsync();

    private void SaveRoutineShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsRoutinesShown)
        {
            args.Handled = true;
            CommitRoutineName();
            _ = SaveRoutineAsync();
        }
    }

    private async Task SaveRoutineAsync()
    {
        if (routineSaving || !routineEditing.CanSave || routineEditing.Editing is not { } routine)
        {
            return;
        }

        routineSaving = true;
        UpdateRoutineFooter();
        try
        {
            var made = await routines.SaveAsync(routine, lifetime.Token);
            routineEditing.Stored(made);
            routineProblem = null;
            RenderRoutines();
            _ = LoadRoutineDryRunAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (RoutineConflictException conflict)
        {
            routineEditing.Rebase(conflict.Current);
            routineProblem = RoutineText.Conflict;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            routineProblem = RoutineText.Problem(error);
        }
        finally
        {
            routineSaving = false;
        }

        UpdateRoutineFooter();
    }

    private void RunRoutineClicked(object sender, RoutedEventArgs args) => _ = RunRoutineAsync(routineEditing.Editing);

    /// <summary>Captures the matches now and queues the actions; what they make shows in Today.</summary>
    private async Task RunRoutineAsync(Routine? routine)
    {
        if (routine?.Id is not { } id)
        {
            return;
        }

        try
        {
            await routines.RunAsync(id, lifetime.Token);
            ShowBulkNotice($"Running “{routine.Name}” now.");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (IsRoutinesShown && routineEditing.Editing?.Id == id)
            {
                routineProblem = RoutineText.Problem(error);
                UpdateRoutineFooter();
            }
            else
            {
                ShowBulkNotice($"Fyke couldn’t run “{routine.Name}”. {RoutineText.Problem(error)}");
            }
        }
    }

    private void RemoveRoutineClicked(object sender, RoutedEventArgs args) => _ = RemoveRoutineAsync();

    /// <summary>Removes the routine; Undo saves a copy again, as macOS does.</summary>
    private async Task RemoveRoutineAsync()
    {
        if (routineEditing.Editing is not { Id: { } id } routine)
        {
            return;
        }

        var copy = routineEditing.Original ?? routine;
        try
        {
            await routines.RemoveAsync(id, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            routineProblem = RoutineText.Problem(error);
            UpdateRoutineFooter();
            return;
        }

        routineEditing.Removed(id);
        routineProblem = null;
        RenderRoutines();
        _ = LoadRoutineDryRunAsync();
        ShowBulkNotice($"Removed “{copy.Name}”.", offerUndo: true);
        routineUndo = async () =>
        {
            try
            {
                var again = await routines.SaveAsync(copy with { Id = null, Revision = null }, lifetime.Token);
                routineEditing.Stored(again);
                RenderRoutines();
                _ = LoadRoutineDryRunAsync();
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException or ArgumentException)
            {
                ShowBulkNotice($"Fyke couldn’t restore “{copy.Name}”. {RoutineText.Problem(error)}");
            }
        };
        RoutineRows.Focus(FocusState.Programmatic);
    }

    /// <summary>Runs the routine undo the notice offers, if it is the routine's.</summary>
    private bool StartRoutineUndo()
    {
        if (routineUndo is not { } undo || !readerConnected)
        {
            return false;
        }

        routineUndo = null;
        HideBulkNotice();
        _ = undo();
        return true;
    }

    private async Task LoadRoutineDryRunAsync()
    {
        routineDryRunRequest?.Cancel();
        routineDryRunRequest = null;
        var id = routineEditing.Editing?.Id;
        routineDryRunId = id;
        routineDryRun = null;
        routineDryRunProblem = null;
        if (id is null || !readerConnected)
        {
            RenderRoutineDryRun();
            return;
        }

        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        routineDryRunRequest = request;
        RenderRoutineDryRun();
        try
        {
            var dryRun = await routines.DryRunAsync(id.Value, request.Token);
            request.Token.ThrowIfCancellationRequested();
            routineDryRun = dryRun;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            routineDryRunProblem = RoutineText.Problem(error);
        }
        finally
        {
            if (ReferenceEquals(routineDryRunRequest, request))
            {
                routineDryRunRequest = null;
            }
        }

        RenderRoutineDryRun();
    }

    /// <summary>What the routine would have caught over the last seven days, and a bar for each day.</summary>
    private void RenderRoutineDryRun()
    {
        var routine = routineEditing.Editing;
        var loading = routine is { IsSaved: true } && routineDryRunRequest is not null;
        RoutineDryRunLoading.IsActive = loading;
        RoutineDryRunLoading.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        RoutineDryRunActions.Children.Clear();
        RoutineDryRunBars.Children.Clear();
        var dryRun = routine?.Id is { } id && id == routineDryRunId ? routineDryRun : null;
        RoutineDryRunSummary.Text = routine is { IsSaved: false } ? RoutineText.SaveForDryRun
            : dryRun is not null ? RoutineText.DryRunSummary([.. dryRun.Days.Select(day => day.Count)])
            : routineDryRunProblem ?? string.Empty;
        RoutineDryRunSummary.Visibility = RoutineDryRunSummary.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (dryRun is null)
        {
            return;
        }

        foreach (var action in dryRun.Actions.Where(action => !string.IsNullOrWhiteSpace(action.Summary)))
        {
            RoutineDryRunActions.Children.Add(briefRenderer.Note(action.Summary!, 13, "BriefMuted"));
        }

        var heights = RoutineText.Bars([.. dryRun.Days.Select(day => day.Count)]);
        for (var index = 0; index < dryRun.Days.Count; index++)
        {
            var day = dryRun.Days[index];
            var label = RoutineText.DayLabel(day);
            var column = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Bottom };
            column.Children.Add(new Border
            {
                Style = AppResources.FromApp<Style>(day.Count == 0 ? "RoutineBarEmpty" : "RoutineBar"),
                Height = Math.Max(3, 40 * heights[index]),
            });
            var text = briefRenderer.Note(label, 11, "BriefMuted");
            text.HorizontalAlignment = HorizontalAlignment.Center;
            column.Children.Add(text);
            AutomationProperties.SetName(column, $"{label}: {BriefText.Count(day.Count, "article")}");
            RoutineDryRunBars.Children.Add(column);
        }
    }

    private IEnumerable<PaletteResult> PaletteRoutines()
    {
        yield return new("routines", "Routines", null, "Ctrl+4", OpenRoutines);
        if (HasRoutineViews)
        {
            yield return new("new-routine", "New routine", null, null, () => StartRoutine());
        }

        foreach (var routine in routineEditing.Saved)
        {
            yield return new($"routine.run.{routine.Id}", $"Run {routine.Name} now", "Routine", null, () => _ = RunRoutineAsync(routine));
        }
    }
}
