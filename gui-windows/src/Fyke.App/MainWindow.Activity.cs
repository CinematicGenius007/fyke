using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Fyke.App;

/// <summary>
/// Activity, as on macOS (gui/Sources/Reader/Activity.swift): one line of background work at the
/// foot of the sidebar, and the panel it opens with what runs now, what needs you and what finished
/// today. A failing feed shows a warning in its row, and the warning tells what happened.
/// </summary>
public sealed partial class MainWindow
{
    private ActivityJobs activityJobs = null!;
    private IReadOnlyList<WriterJob> activityJobList = [];
    private CancellationTokenSource? activityRequest;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? activityTimer;
    private DateTimeOffset? activityUpdatedAt;
    private int activityChangesPending;
    private bool activityOpen;

    private ActivityState Activity => new(activityJobList, FailingFeeds(), routineEditing.Saved, activityUpdatedAt);

    private IReadOnlyList<FailingFeed> FailingFeeds() =>
        [.. catalog.Where(row => row.Scope == ReaderScope.Feed && row.IsFailing)
            .Select(row => new FailingFeed(row.Id, row.Title, row.Entries, row.Health!))];

    private void InitializeActivity()
    {
        activityJobs = new ActivityJobs(client);
        activityTimer = DispatcherQueue.CreateTimer();
        activityTimer.Interval = TimeSpan.FromSeconds(30);
        activityTimer.Tick += (_, _) => RenderActivity();
        RenderActivity();
    }

    /// <summary>Work starting, changing or finishing reloads the jobs, wherever the reader is.</summary>
    private void QueueActivityChange(DaemonEvent change)
    {
        if (ActivityJobs.Concerns(change) && Interlocked.Exchange(ref activityChangesPending, 1) == 0)
        {
            _ = DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref activityChangesPending, 0);
                if (readerConnected && !lifetime.IsCancellationRequested)
                {
                    _ = LoadActivityAsync();
                }
            });
        }
    }

    private async Task LoadActivityAsync()
    {
        if (!readerConnected || lifetime.IsCancellationRequested)
        {
            return;
        }

        activityRequest?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        activityRequest = request;
        try
        {
            activityJobList = await activityJobs.ListAsync(request.Token);
            request.Token.ThrowIfCancellationRequested();
            RenderActivity();
            if (IsRoutinesShown)
            {
                RenderRoutineRows();
            }
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // Activity keeps what it last read; the next change or reconnect reads again.
        }
        finally
        {
            if (ReferenceEquals(activityRequest, request))
            {
                activityRequest = null;
            }
        }
    }

    private void StopActivity()
    {
        activityRequest?.Cancel();
        ActivityFlyout.Hide();
        activityJobList = [];
        activityUpdatedAt = null;
        RenderActivity();
    }

    /// <summary>The feeds were read again: the status line says when, and failing feeds count.</summary>
    private void ActivityCatalogLoaded()
    {
        activityUpdatedAt = DateTimeOffset.Now;
        RenderActivity();
    }

    /// <summary>The status line, then the panel when it is open.</summary>
    private void RenderActivity()
    {
        var now = DateTimeOffset.Now;
        var state = Activity;
        var words = readerConnected ? ActivityText.Status(state, now) : string.Empty;
        var attention = state.NeedsAttention(now);
        ActivityWords.Text = words.Length == 0 ? " " : words;
        ActivityWords.Foreground = ThemeBrush(attention ? "InkBrush" : "MutedBrush");
        ActivitySpinner.IsActive = state.IsBusy;
        ActivitySpinner.Visibility = state.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ActivityDot.Visibility = state.IsBusy ? Visibility.Collapsed : Visibility.Visible;
        ActivityDot.Style = AppResources.FromApp<Style>(attention ? "ActivityDot" : "ActivityQuietDot");
        AutomationProperties.SetName(ActivityButton, $"Activity: {words}");
        ActivityButton.IsEnabled = readerConnected;
        if (activityTimer is { } timer)
        {
            // Seconds tick while running work is shown; otherwise only "Updated …" moves.
            timer.Interval = TimeSpan.FromSeconds(activityOpen && state.IsBusy ? 1 : 30);
            if (readerConnected)
            {
                timer.Start();
            }
            else
            {
                timer.Stop();
            }
        }

        if (activityOpen)
        {
            RenderActivityPanel(state, now);
        }
    }

    private void RenderActivityPanel(ActivityState state, DateTimeOffset now)
    {
        ActivityGroups.Children.Clear();
        var active = state.Active;
        var needsYou = state.NeedsYou(now);
        var earlier = state.Earlier(now);

        ActivityGroups.Children.Add(ActivityGroup("Now"));
        if (active.Count == 0)
        {
            ActivityGroups.Children.Add(ActivityLine(ActivityText.NothingRunning));
        }

        foreach (var job in active)
        {
            ActivityGroups.Children.Add(RunningRow(state, job, now));
        }

        if (needsYou.Count > 0 || state.FailingFeeds.Count > 0)
        {
            ActivityGroups.Children.Add(ActivityGroup("Needs you"));
            foreach (var job in needsYou)
            {
                ActivityGroups.Children.Add(FailedRow(state, job));
            }

            if (state.FailingFeeds.Count > 0)
            {
                ActivityGroups.Children.Add(FailingFeedsRow(state.FailingFeeds));
            }
        }

        if (earlier.Count > 0)
        {
            ActivityGroups.Children.Add(ActivityGroup("Earlier today"));
            foreach (var job in earlier)
            {
                ActivityGroups.Children.Add(DoneRow(state, job));
            }
        }

        ActivityNext.Text = ActivityText.Next(state) ?? string.Empty;
    }

    private TextBlock ActivityGroup(string title)
    {
        var label = briefRenderer.Label(title.ToUpperInvariant(), 11, "BriefMuted", nameof(ReaderFontWeights.SectionLabel), spacing: 60);
        label.Margin = new Thickness(16, 12, 16, 4);
        AutomationProperties.SetName(label, title);
        AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level2);
        return label;
    }

    private TextBlock ActivityLine(string text)
    {
        var line = briefRenderer.Note(text, 13, "BriefMuted");
        line.Margin = new Thickness(16, 4, 16, 4);
        return line;
    }

    private Grid RunningRow(ActivityState state, WriterJob job, DateTimeOffset now)
    {
        var row = new Grid { ColumnSpacing = 8, Padding = new Thickness(16, 4, 12, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = state.Describe(job);
        row.Children.Add(new ProgressRing { IsActive = true, Style = AppResources.FromApp<Style>("BriefSpinner"), MinWidth = 0, MinHeight = 0 });
        var name = ActivityLabel(title, 13, "BriefInk");
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        var detail = ActivityLabel(ActivityText.Running(job, now), 12, "BriefMuted");
        Grid.SetColumn(detail, 2);
        row.Children.Add(detail);
        var cancel = new Button
        {
            Width = 24,
            Height = 24,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Content = new FontIcon { Glyph = "\uE711", FontSize = 10 },
        };
        var label = $"Cancel {ActivityText.Title(job.Work).ToLowerInvariant()}";
        AutomationProperties.SetName(cancel, label);
        ToolTipService.SetToolTip(cancel, label);
        cancel.Click += (_, _) => _ = CancelActivityJobAsync(job.Id);
        Grid.SetColumn(cancel, 3);
        row.Children.Add(cancel);
        AutomationProperties.SetName(row, $"{title}, {ActivityText.Running(job, now)}");
        return row;
    }

    private async Task CancelActivityJobAsync(long id)
    {
        try
        {
            await activityJobs.CancelAsync(id, lifetime.Token);
            await LoadActivityAsync();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // The job's next change, or the next open of Activity, shows where it stands.
            await LoadActivityAsync();
        }
    }

    /// <summary>What failed, what is safe, and the one thing to do.</summary>
    private Border FailedRow(ActivityState state, WriterJob job)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new Ellipse
        {
            Style = AppResources.FromApp<Style>("ActivityDot"),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 6, 0, 0),
        });
        var words = new StackPanel { Spacing = 4 };
        var title = ActivityText.FailedTitle(state, job);
        var detail = ActivityText.FailedDetail(job);
        words.Children.Add(ActivityLabel(title, 13, "BriefInk", wrap: true, medium: true));
        words.Children.Add(ActivityLabel(detail, 12, "BriefSoft", wrap: true));
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var action = new Button
        {
            Content = ActivityText.FailedAction(job),
            VerticalAlignment = VerticalAlignment.Top,
            Style = AppResources.FromApp<Style>("BriefPrimaryAction"),
        };
        action.Click += (_, _) =>
        {
            ActivityFlyout.Hide();
            if (ActivityText.IsWriterProblem(job))
            {
                OpenAgentsSettings();
            }
            else if (ActivityText.IsWriting(job))
            {
                _ = WriteBriefAsync();
            }
            else
            {
                _ = RefreshSubscriptionsAsync(null);
            }
        };
        Grid.SetColumn(action, 2);
        grid.Children.Add(action);
        var row = new Border { Child = grid, Style = AppResources.FromApp<Style>("ActivityFailure") };
        AutomationProperties.SetName(row, $"{title}. {detail}");
        return row;
    }

    private Grid FailingFeedsRow(IReadOnlyList<FailingFeed> feeds)
    {
        var grid = new Grid { ColumnSpacing = 8, Padding = new Thickness(20, 12, 20, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new FontIcon { Glyph = "\uE7BA", FontSize = 11, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0) });
        var words = new StackPanel { Spacing = 4 };
        var title = ActivityText.FeedsTitle(feeds);
        words.Children.Add(ActivityLabel(title, 13, "BriefInk", wrap: true, medium: true));
        words.Children.Add(ActivityLabel(ActivityText.FeedsKept, 12, "BriefSoft", wrap: true));
        Grid.SetColumn(words, 1);
        grid.Children.Add(words);
        var show = new Button
        {
            Content = "Show",
            VerticalAlignment = VerticalAlignment.Top,
            Style = AppResources.FromApp<Style>("BriefSecondaryAction"),
        };
        AutomationProperties.SetAutomationId(show, "ActivityShowFeed");
        AutomationProperties.SetName(show, $"Show {feeds[0].Name}");
        show.Click += (_, _) =>
        {
            ActivityFlyout.Hide();
            if (catalog.FirstOrDefault(row => row.Scope == ReaderScope.Feed && row.Id == feeds[0].Id) is { } feed)
            {
                ShowFeedHealth(feed, null);
            }
        };
        Grid.SetColumn(show, 2);
        grid.Children.Add(show);
        AutomationProperties.SetName(grid, $"{title}. {ActivityText.FeedsKept}");
        return grid;
    }

    private Grid DoneRow(ActivityState state, WriterJob job)
    {
        var row = new Grid { ColumnSpacing = 8, Height = 32, Padding = new Thickness(16, 0, 16, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var done = job.IsDone;
        row.Children.Add(new FontIcon
        {
            Glyph = ActivityText.DoneGlyph(job),
            FontSize = 11,
            Foreground = ThemeBrush(done ? "InkSoftBrush" : "MutedBrush"),
        });
        var text = ActivityText.Done(state, job);
        var name = ActivityLabel(text, 13, "BriefInk");
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        var time = ActivityLabel(ActivityText.Finished(job), 12, "BriefMuted");
        Grid.SetColumn(time, 2);
        row.Children.Add(time);
        AutomationProperties.SetName(row, $"{text}, {time.Text}");
        return row;
    }

    /// <summary>Interface text in the UI face: trimmed to a line, or wrapped.</summary>
    private TextBlock ActivityLabel(string text, double size, string style, bool wrap = false,
        string weight = nameof(ReaderFontWeights.Ui), bool medium = false)
    {
        var label = briefRenderer.Label(text, size, style, weight);
        if (wrap)
        {
            label.TextWrapping = TextWrapping.Wrap;
        }
        else
        {
            label.TextTrimming = TextTrimming.CharacterEllipsis;
            label.VerticalAlignment = VerticalAlignment.Center;
        }

        if (medium)
        {
            label.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
        }

        return label;
    }

    private static Brush ThemeBrush(string key) => AppResources.FromApp<Brush>(key);

    private void ActivityOpening(object sender, object args)
    {
        activityOpen = true;
        RenderActivity();
        _ = LoadActivityAsync();
    }

    private void ActivityClosed(object sender, object args)
    {
        activityOpen = false;
        RenderActivity();
    }

    private void ActivityShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!readerConnected)
        {
            return;
        }

        args.Handled = true;
        if (activityOpen)
        {
            ActivityFlyout.Hide();
        }
        else
        {
            OpenActivity();
        }
    }

    private void OpenActivity()
    {
        if (readerConnected && !lifetime.IsCancellationRequested)
        {
            ClosePalette();
            ActivityFlyout.ShowAt(ActivityButton);
        }
    }

    private void ActivityRefreshClicked(object sender, RoutedEventArgs args)
    {
        ActivityFlyout.Hide();
        _ = RefreshSubscriptionsAsync(null);
    }

    private void ActivityRoutinesClicked(object sender, RoutedEventArgs args)
    {
        ActivityFlyout.Hide();
        OpenRoutines();
    }

    private void FeedHealthClicked(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { DataContext: ReaderDestination feed } anchor)
        {
            ShowFeedHealth(feed, anchor);
        }
    }

    /// <summary>
    /// What happened to a feed, what is kept, and the one next action, beside its row. Without an
    /// anchor it opens the folders that hide the feed and opens beside its row.
    /// </summary>
    private void ShowFeedHealth(ReaderDestination feed, FrameworkElement? anchor)
    {
        if (feed.Health is not { } health)
        {
            return;
        }

        if (anchor is null)
        {
            // The popup points at the feed, so the folders that hide it open first.
            RevealDestination(feed);
            Destinations.ScrollIntoView(feed);
            Destinations.UpdateLayout();
            anchor = Destinations.ContainerFromItem(feed) as FrameworkElement ?? Destinations;
        }

        var flyout = new Flyout
        {
            Placement = FlyoutPlacementMode.RightEdgeAlignedTop,
            FlyoutPresenterStyle = AppResources.FromApp<Style>("ActivityPopover"),
        };
        var panel = new StackPanel { Width = 380 };
        AutomationProperties.SetName(panel, ActivityText.HealthTitle(feed.Title, health));
        AutomationProperties.SetAutomationId(panel, "FeedHealth");
        var words = new StackPanel { Spacing = 8, Padding = new Thickness(16) };
        var title = ActivityLabel(ActivityText.HealthTitle(feed.Title, health), 14, "BriefInk", wrap: true, weight: nameof(ReaderFontWeights.SectionLabel));
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        words.Children.Add(title);
        words.Children.Add(ActivityLabel(ActivityText.HealthDetail(health, feed.Entries), 13, "BriefSoft", wrap: true));
        panel.Children.Add(words);

        if (health.LastError is { } error)
        {
            var line = new Grid { ColumnSpacing = 12 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.Children.Add(ActivityLabel("Error", 12, "BriefMuted"));
            var message = ActivityLabel(error, 12, "BriefInk", wrap: true);
            message.MaxLines = 3;
            message.TextTrimming = TextTrimming.CharacterEllipsis;
            message.IsTextSelectionEnabled = true;
            message.FontFamily = AppResources.FromApp<FontFamily>("FontCode");
            AutomationProperties.SetAutomationId(message, "FeedHealthError");
            Grid.SetColumn(message, 1);
            line.Children.Add(message);
            panel.Children.Add(new Border { Child = line, Style = AppResources.FromApp<Style>("ActivityError") });
        }

        var actions = new Grid { Padding = new Thickness(12), ColumnSpacing = 8 };
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (Uri.TryCreate(health.SiteUrl, UriKind.Absolute, out var site) && site.Scheme is "http" or "https")
        {
            var open = new Button { Content = "Open site", Style = AppResources.FromApp<Style>("BriefQuietAction") };
            open.Click += (_, _) =>
            {
                flyout.Hide();
                _ = Windows.System.Launcher.LaunchUriAsync(site);
            };
            actions.Children.Add(open);
        }

        var refresh = new Button { Content = ActivityText.HealthAction(health), Style = AppResources.FromApp<Style>("BriefPrimaryAction") };
        AutomationProperties.SetAutomationId(refresh, "FeedHealthRefresh");
        refresh.Click += (_, _) =>
        {
            flyout.Hide();
            _ = RefreshSubscriptionsAsync(feed);
        };
        Grid.SetColumn(refresh, 2);
        actions.Children.Add(refresh);
        panel.Children.Add(actions);

        flyout.Content = panel;
        flyout.Opened += (_, _) => refresh.Focus(FocusState.Programmatic);
        flyout.ShowAt(anchor);
    }

    private IEnumerable<PaletteResult> PaletteActivity()
    {
        yield return new("activity", "Show activity", null, "Ctrl+0", OpenActivity);
    }
}
