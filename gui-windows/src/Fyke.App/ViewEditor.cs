using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace Fyke.App;

internal sealed class ViewEditor
{
    private static readonly string[] States = ["any", "unread", "starred", "later"];
    private readonly TextBox name;
    private readonly TextBox words;
    private readonly CheckBox anyWords;
    private readonly ComboBox state;
    private readonly ListView sources;
    private readonly TextBox host;
    private readonly CheckBox subdomains;
    private readonly TextBox path;
    private readonly TextBox excludedPaths;
    private readonly TextBox days;
    private readonly ScrollViewer form;
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };

    public ViewEditor(string title, ViewRule rule, IReadOnlyList<ReaderDestination> catalog)
    {
        name = Field("Name", "ViewName", title);
        words = Field("Words", "ViewWords", rule.Words);
        words.PlaceholderText = "Words in titles or articles";
        anyWords = new() { Content = "Match any word", IsChecked = rule.AnyWords };
        state = new()
        {
            Header = "Reading state",
            ItemsSource = new[] { "All articles", "Unread", "Starred", "Read later" },
            SelectedIndex = Math.Max(0, Array.IndexOf(States, rule.State)),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(state, "Reading state");
        AutomationProperties.SetAutomationId(state, "ViewReadingState");
        sources = SourcePicker(rule, catalog);
        host = Field("Article host", "ViewHost", rule.Host);
        host.PlaceholderText = "example.com";
        subdomains = new() { Content = "Include subdomains", IsChecked = rule.Subdomains };
        path = Field("Path starts with", "ViewPath", rule.PathPrefix);
        path.PlaceholderText = "/articles";
        excludedPaths = Field("Exclude paths", "ViewExcludedPaths", string.Join('\n', rule.ExcludePathPrefix));
        excludedPaths.AcceptsReturn = true;
        excludedPaths.PlaceholderText = "One path per line";
        days = Field("Published in the last (days)", "ViewWithinDays", rule.WithinDays?.ToString(CultureInfo.CurrentCulture));

        var primary = new StackPanel { Spacing = 8 };
        primary.Children.Add(name);
        primary.Children.Add(words);
        primary.Children.Add(anyWords);
        primary.Children.Add(state);
        var filters = new StackPanel { Spacing = 8 };
        filters.Children.Add(new TextBlock { Text = "Sources", FontSize = 14 });
        filters.Children.Add(new TextBlock { Text = "Select feeds or folders. An empty selection uses all feeds.", TextWrapping = TextWrapping.Wrap });
        filters.Children.Add(sources);
        filters.Children.Add(host);
        filters.Children.Add(subdomains);
        filters.Children.Add(path);
        filters.Children.Add(excludedPaths);
        filters.Children.Add(days);
        primary.Children.Add(new Expander
        {
            Header = "Sources, address and date",
            Content = filters,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            IsExpanded = rule.Feeds.Length > 0 || rule.Folders.Length > 0 || rule.Host is not null
                || rule.PathPrefix is not null || rule.ExcludePathPrefix.Length > 0 || rule.WithinDays is not null,
        });

        var layout = new Grid { RowSpacing = 8 };
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        form = new ScrollViewer { Content = primary, MaxHeight = 400, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        layout.Children.Add(form);
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        Grid.SetRow(status, 1);
        layout.Children.Add(status);
        Content = layout;
    }

    public FrameworkElement Content { get; }
    public string Name => name.Text.Trim();

    public void SetInputEnabled(bool enabled) => form.IsEnabled = enabled;

    public void FocusName()
    {
        name.Focus(FocusState.Programmatic);
        name.SelectAll();
    }

    public void ShowStatus(string message)
    {
        status.Text = message;
        status.Visibility = Visibility.Visible;
    }

    public ViewRule? CaptureRule()
    {
        var wordFilter = Optional(words.Text);
        if (wordFilter is not null && Encoding.UTF8.GetByteCount(wordFilter) > 200)
        {
            ShowStatus("Use a shorter word filter.");
            words.Focus(FocusState.Programmatic);
            return null;
        }

        long? within = null;
        if (Optional(days.Text) is { } entered)
        {
            if (!long.TryParse(entered, NumberStyles.Integer, CultureInfo.CurrentCulture, out var value) || value is < 1 or > 3650)
            {
                ShowStatus("Enter a whole number from 1 to 3650 days.");
                days.Focus(FocusState.Programmatic);
                return null;
            }
            within = value;
        }

        var selected = sources.SelectedItems.Cast<Source>().ToArray();
        var articleHost = Optional(host.Text);
        return new ViewRule
        {
            Feeds = selected.Where(item => item.Scope == ReaderScope.Feed).Select(item => item.Id).ToArray(),
            Folders = selected.Where(item => item.Scope == ReaderScope.Folder).Select(item => item.Id).ToArray(),
            State = States[state.SelectedIndex],
            Words = wordFilter,
            AnyWords = wordFilter is not null && anyWords.IsChecked == true,
            Host = articleHost,
            Subdomains = articleHost is not null && subdomains.IsChecked == true,
            PathPrefix = Optional(path.Text),
            ExcludePathPrefix = excludedPaths.Text.Split(['\r', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
            WithinDays = within,
        };
    }

    private static TextBox Field(string label, string id, string? value)
    {
        var field = new TextBox { Header = label, Text = value ?? string.Empty };
        AutomationProperties.SetName(field, label);
        AutomationProperties.SetAutomationId(field, id);
        return field;
    }

    private static string? Optional(string value) => value.Trim() is { Length: > 0 } trimmed ? trimmed : null;

    private static ListView SourcePicker(ViewRule rule, IReadOnlyList<ReaderDestination> catalog)
    {
        var selected = rule.Feeds.Select(id => (Scope: ReaderScope.Feed, Id: id))
            .Concat(rule.Folders.Select(id => (Scope: ReaderScope.Folder, Id: id))).ToHashSet();
        var choices = catalog.Where(row => row.Scope is ReaderScope.Feed or ReaderScope.Folder)
            .Select(row => new Source(row.Scope, row.Id, row.Scope == ReaderScope.Folder ? $"Folder · {row.Title}" : row.Title))
            .ToList();
        var available = choices.Select(item => (item.Scope, item.Id)).ToHashSet();
        foreach (var missing in selected.Except(available))
        {
            // Keep missing sources selected until the user deliberately changes the rule.
            choices.Add(new(missing.Scope, missing.Id, $"Unavailable {missing.Scope.ToString().ToLowerInvariant()} ({missing.Id})"));
        }

        var list = new ListView
        {
            MaxHeight = 144,
            SelectionMode = ListViewSelectionMode.Multiple,
            ItemsSource = choices,
        };
        AutomationProperties.SetName(list, "Feeds and folders");
        foreach (var choice in choices.Where(item => selected.Contains((item.Scope, item.Id))))
        {
            list.SelectedItems.Add(choice);
        }
        return list;
    }

    internal sealed record Source(ReaderScope Scope, long Id, string Label)
    {
        public override string ToString() => Label;
    }
}
