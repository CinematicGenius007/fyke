using System;
using System.Collections.Generic;
using System.Linq;
using Fyke.ViewModels;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI.Text;

namespace Fyke.App;

internal enum InlineTone
{
    Working,
    Failed,
    Empty,
}

/// <summary>A state said in place of content: what is happening, and what can be done about it.</summary>
internal sealed record InlineStateView(InlineTone Tone, string Label, string Title, string Detail,
    (string Text, Action Run)? Primary = null, (string Text, Action Run)? Secondary = null);

/// <summary>
/// Draws a brief like an article, as the macOS reader does (gui/Sources/Reader/Brief.swift): each
/// claim is followed by the numbers of the articles it cites, and every number is one hover from
/// its source. Hovering a number shows the source; clicking keeps it open.
/// </summary>
internal sealed class BriefRenderer(FontFamily reading, FontFamily ui, ReaderFontWeights weights, ReaderTextStyle textStyle)
{
    private const double PopoverWidth = 340;
    private Flyout? popover;
    private Button? popoverMark;
    private bool pinned;

    /// <summary>The brief, its sources and what made it, in place of what the column held.</summary>
    public void ShowBrief(Panel column, Brief brief, string header, string? recipeName, DateTimeOffset now,
        Action<BriefCitation> open, Action? openRecipe = null)
    {
        ClosePopover();
        column.Children.Clear();
        column.Children.Add(Tag("AI BRIEF", header));
        column.Children.Add(Title(brief.DisplayTitle, 40, "BriefTitle"));
        AppendBody(column, brief, now, open);
        column.Children.Add(MadeWith(brief, recipeName, openRecipe));
    }

    /// <summary>Writing, failed, empty or unavailable, said where the brief would be.</summary>
    public void ShowState(Panel column, InlineStateView state)
    {
        ClosePopover();
        column.Children.Clear();
        column.Children.Add(State(state));
    }

    /// <summary>A generated tag and the line beside it: "AI BRIEF  Engineering · November 20".</summary>
    public StackPanel Tag(string tag, string detail)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 16) };
        row.Children.Add(new Border
        {
            Style = Shared("BriefTag"),
            Child = Label(tag, 11, "BriefSoft", nameof(ReaderFontWeights.SectionLabel), spacing: 45),
        });
        var place = Label(detail, 13, "BriefMuted");
        place.VerticalAlignment = VerticalAlignment.Center;
        place.TextTrimming = TextTrimming.CharacterEllipsis;
        row.Children.Add(place);
        return row;
    }

    /// <summary>A page title in the reading face, selectable and announced as the page's heading.</summary>
    public TextBlock Title(string text, double size, string automationId)
    {
        var title = Reading(text, size, "BriefInk", nameof(ReaderFontWeights.Title));
        title.CharacterSpacing = -15;
        title.Margin = new Thickness(0, 0, 0, 24);
        title.IsTextSelectionEnabled = true;
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        AutomationProperties.SetAutomationId(title, automationId);
        return title;
    }

    /// <summary>A line of interface text in one of the brief styles, such as BriefMuted.</summary>
    public TextBlock Note(string text, double size, string style)
    {
        var note = Label(text, size, style);
        note.TextWrapping = TextWrapping.Wrap;
        return note;
    }

    /// <summary>The claims with their citation numbers, then the sources.</summary>
    public void AppendBody(Panel column, Brief brief, DateTimeOffset now, Action<BriefCitation> open)
    {
        var citations = brief.Cited.ToDictionary(citation => citation.Number);
        foreach (var section in brief.Parts)
        {
            if (!string.IsNullOrWhiteSpace(section.Heading))
            {
                var heading = Reading(section.Heading, 22, "BriefInk", nameof(ReaderFontWeights.Title));
                heading.Margin = new Thickness(0, 12, 0, 8);
                AutomationProperties.SetHeadingLevel(heading, AutomationHeadingLevel.Level2);
                column.Children.Add(heading);
            }

            column.Children.Add(Paragraph(section.Items, citations, now, open));
        }

        column.Children.Add(Sources(brief, open));
    }

    /// <summary>A state said in place of content, with what can be done about it.</summary>
    public StackPanel State(InlineStateView state)
    {
        var panel = new StackPanel { MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 24, 0, 0) };
        AutomationProperties.SetAutomationId(panel, "TodayState");

        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 0, 0, 12) };
        if (state.Tone == InlineTone.Working)
        {
            label.Children.Add(new ProgressRing { Style = Shared("BriefSpinner"), IsActive = true });
        }
        else if (state.Tone == InlineTone.Failed)
        {
            label.Children.Add(new Ellipse { Style = Shared("BriefDot") });
        }

        label.Children.Add(Label(state.Label.ToUpperInvariant(), 11, state.Tone == InlineTone.Empty ? "BriefMuted" : "BriefUnread",
            nameof(ReaderFontWeights.SectionLabel), spacing: 60));
        panel.Children.Add(label);

        var title = Reading(state.Title, 26, "BriefInk", nameof(ReaderFontWeights.Title));
        title.Margin = new Thickness(0, 0, 0, 12);
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        AutomationProperties.SetLiveSetting(title, AutomationLiveSetting.Polite);
        panel.Children.Add(title);

        var detail = Reading(state.Detail, 17, "BriefSoft", nameof(ReaderFontWeights.Reading));
        detail.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        detail.LineHeight = 26;
        panel.Children.Add(detail);

        if (state.Primary is not null || state.Secondary is not null)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 24, 0, 0) };
            if (state.Primary is { } primary)
            {
                actions.Children.Add(Action(primary.Text, primary.Run,
                    state.Tone == InlineTone.Working ? "BriefSecondaryAction" : "BriefPrimaryAction"));
            }

            if (state.Secondary is { } secondary)
            {
                actions.Children.Add(Action(secondary.Text, secondary.Run, "BriefQuietAction"));
            }

            panel.Children.Add(actions);
        }

        return panel;
    }

    public void ClosePopover() => popover?.Hide();

    private RichTextBlock Paragraph(IReadOnlyList<BriefClaim> claims, Dictionary<int, BriefCitation> citations,
        DateTimeOffset now, Action<BriefCitation> open)
    {
        var text = new RichTextBlock
        {
            Style = Shared("BriefParagraph"),
            FontFamily = reading,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 24),
        };
        textStyle.BindBrief(text);
        weights.Bind(text, RichTextBlock.FontWeightProperty, nameof(ReaderFontWeights.Reading));
        AutomationProperties.SetName(text, string.Join(" ", claims.Select(BriefText.Spoken)));
        var paragraph = new Paragraph();
        foreach (var claim in claims)
        {
            paragraph.Inlines.Add(new Run { Text = (claim.Text ?? string.Empty).TrimEnd() });
            for (var index = 0; index < claim.Numbers.Count; index++)
            {
                var number = claim.Numbers[index];
                var last = index == claim.Numbers.Count - 1;
                paragraph.Inlines.Add(new InlineUIContainer
                {
                    Child = citations.TryGetValue(number, out var citation)
                        ? Mark(citation, last, now, open)
                        : Label(last ? $"{number}" : $"{number},", 12, "BriefUnread", nameof(ReaderFontWeights.SectionLabel)),
                });
            }

            paragraph.Inlines.Add(new Run { Text = " " });
        }

        text.Blocks.Add(paragraph);
        return text;
    }

    // The number sits five points above the line, like a superscript.
    private Button Mark(BriefCitation citation, bool last, DateTimeOffset now, Action<BriefCitation> open)
    {
        var mark = new Button
        {
            Style = Shared("BriefCitation"),
            FontFamily = ui,
            Content = last ? $"{citation.Number}" : $"{citation.Number},",
            RenderTransform = new TranslateTransform { Y = -5 },
        };
        AutomationProperties.SetName(mark, $"Source {citation.Number}");
        AutomationProperties.SetHelpText(mark, "Shows the cited article");
        mark.PointerEntered += (_, _) =>
        {
            if (!pinned)
            {
                ShowPopover(mark, citation, now, open, pin: false);
            }
        };
        mark.Click += (_, _) =>
        {
            if (pinned && ReferenceEquals(popoverMark, mark))
            {
                ClosePopover();
            }
            else
            {
                ShowPopover(mark, citation, now, open, pin: true);
            }
        };
        return mark;
    }

    private void ShowPopover(Button mark, BriefCitation citation, DateTimeOffset now, Action<BriefCitation> open, bool pin)
    {
        ClosePopover();
        var flyout = new Flyout
        {
            FlyoutPresenterStyle = Shared("BriefPopover"),
            Content = Popover(citation, now, () =>
            {
                ClosePopover();
                open(citation);
            }),
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
            // A hover leaves when the pointer does, a moment after it crosses the gap; a click stays.
            ShowMode = pin ? FlyoutShowMode.Standard : FlyoutShowMode.TransientWithDismissOnPointerMoveAway,
        };
        flyout.Closed += (_, _) =>
        {
            if (ReferenceEquals(popover, flyout))
            {
                popover = null;
                pinned = false;
                if (popoverMark is { } previous)
                {
                    previous.Style = Shared("BriefCitation");
                }

                popoverMark = null;
            }
        };
        popover = flyout;
        popoverMark = mark;
        pinned = pin;
        mark.Style = Shared("BriefActiveCitation");
        flyout.ShowAt(mark, new FlyoutShowOptions
        {
            Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft,
            ShowMode = flyout.ShowMode,
        });
    }

    private StackPanel Popover(BriefCitation citation, DateTimeOffset now, Action open)
    {
        var panel = new StackPanel { Width = PopoverWidth };
        AutomationProperties.SetName(panel, $"Source {citation.Number}: {citation.DisplayTitle}");
        var detail = Label(BriefText.CitationDetail(citation, now), 12, "BriefMuted");
        detail.Margin = new Thickness(0, 0, 0, 4);
        panel.Children.Add(detail);
        var title = Reading(citation.DisplayTitle, 17, "BriefInk", nameof(ReaderFontWeights.Title));
        title.Margin = new Thickness(0, 0, 0, 8);
        panel.Children.Add(title);
        if (!string.IsNullOrWhiteSpace(citation.Snippet))
        {
            var quote = new Grid { ColumnSpacing = 10, Margin = new Thickness(0, 0, 0, 12) };
            quote.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            quote.ColumnDefinitions.Add(new ColumnDefinition());
            quote.Children.Add(new Border { Style = Shared("BriefQuoteBar") });
            var words = Reading($"“{citation.Snippet.Trim()}”", 14, "BriefSoft", nameof(ReaderFontWeights.Reading));
            words.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
            words.LineHeight = 21;
            words.MaxLines = 4;
            words.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(words, 1);
            quote.Children.Add(words);
            panel.Children.Add(quote);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(-10, 0, 0, 0) };
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        label.Children.Add(new TextBlock { Text = "Open article", FontFamily = ui, FontSize = 13 });
        label.Children.Add(new FontIcon { Glyph = "\uE751", FontSize = 10 });
        var button = new Button { Style = Shared("BriefQuietAction"), Content = label, FontFamily = ui };
        AutomationProperties.SetName(button, "Open article");
        AutomationProperties.SetAutomationId(button, "OpenCitedArticle");
        button.Click += (_, _) => open();
        actions.Children.Add(button);
        var where = Label("Opens here, in the reader", 12, "BriefMuted");
        where.VerticalAlignment = VerticalAlignment.Center;
        actions.Children.Add(where);
        panel.Children.Add(actions);
        return panel;
    }

    // The numbered sources under the brief.
    private StackPanel Sources(Brief brief, Action<BriefCitation> open)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 8, 0, 32) };
        var rule = new Border { Style = Shared("ArticleRule"), Margin = new Thickness(0, 0, 0, 20) };
        panel.Children.Add(rule);
        var label = Label("SOURCES", 11, "BriefMuted", nameof(ReaderFontWeights.SectionLabel), spacing: 60);
        label.Margin = new Thickness(0, 0, 0, 8);
        AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level2);
        panel.Children.Add(label);

        foreach (var citation in brief.Cited)
        {
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var number = Label($"{citation.Number}", 13, "BriefUnread");
            number.FontWeight = FontWeights.Medium;
            number.VerticalAlignment = VerticalAlignment.Center;
            var title = Reading(citation.DisplayTitle, 17, citation.Read ? "BriefRead" : "BriefUnread", nameof(ReaderFontWeights.TimelineTitle));
            title.TextWrapping = TextWrapping.NoWrap;
            title.TextTrimming = TextTrimming.CharacterEllipsis;
            title.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(title, 1);
            var feed = Label(citation.FeedTitle ?? string.Empty, 12, "BriefMuted");
            feed.Margin = new Thickness(16, 0, 0, 0);
            feed.MaxWidth = 200;
            feed.TextTrimming = TextTrimming.CharacterEllipsis;
            feed.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(feed, 2);
            row.Children.Add(number);
            row.Children.Add(title);
            row.Children.Add(feed);

            var button = new Button { Style = Shared("BriefSourceRow"), Content = row };
            AutomationProperties.SetName(button, $"Source {citation.Number}, {citation.DisplayTitle}, {citation.FeedTitle}");
            button.PointerEntered += (_, _) => title.TextDecorations = TextDecorations.Underline;
            button.PointerExited += (_, _) => title.TextDecorations = TextDecorations.None;
            button.Click += (_, _) => open(citation);
            panel.Children.Add(button);
        }

        if (BriefText.SourcesNote(brief) is { } note)
        {
            var text = Label(note, 13, "BriefMuted");
            text.Margin = new Thickness(28, 8, 0, 0);
            text.TextWrapping = TextWrapping.Wrap;
            panel.Children.Add(text);
        }

        return panel;
    }

    // "Written by Codex with your Morning brief recipe · rev 3".
    // "Written by Codex with your Morning brief recipe · rev 3", and Edit recipe, which opens it.
    private StackPanel MadeWith(Brief brief, string? recipeName, Action? openRecipe)
    {
        var (before, recipe, after) = BriefText.MadeWith(brief, recipeName);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon { Glyph = "\uE8A5", Style = Shared("BriefSoftIcon") });
        var text = Label(string.Empty, 13, "BriefSoft");
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Inlines.Add(new Run { Text = before });
        text.Inlines.Add(new Run { Text = recipe, FontWeight = FontWeights.SemiBold });
        text.Inlines.Add(new Run { Text = after });
        AutomationProperties.SetAutomationId(text, "BriefMadeWith");
        row.Children.Add(text);
        if (openRecipe is not null)
        {
            var edit = Action("Edit recipe", openRecipe, "BriefQuietAction");
            edit.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties.SetAutomationId(edit, "BriefEditRecipe");
            row.Children.Add(edit);
        }

        return row;
    }

    private Button Action(string text, Action run, string style)
    {
        var button = new Button { Style = Shared(style), Content = text, FontFamily = ui, FontSize = 13 };
        button.Click += (_, _) => run();
        return button;
    }

    /// <summary>A line of interface text in the UI face, with the weight the reader settings choose.</summary>
    public TextBlock Label(string text, double size, string style, string weight = nameof(ReaderFontWeights.Ui), int spacing = 0)
    {
        var label = new TextBlock { Text = text, FontFamily = ui, FontSize = size, Style = Shared(style), CharacterSpacing = spacing };
        weights.Bind(label, TextBlock.FontWeightProperty, weight);
        return label;
    }

    private TextBlock Reading(string text, double size, string style, string weight)
    {
        var block = new TextBlock
        {
            Text = text, FontFamily = reading, FontSize = size, Style = Shared(style), TextWrapping = TextWrapping.Wrap,
        };
        weights.Bind(block, TextBlock.FontWeightProperty, weight);
        return block;
    }

    private static Style Shared(string key) => AppResources.FromApp<Style>(key);
}
