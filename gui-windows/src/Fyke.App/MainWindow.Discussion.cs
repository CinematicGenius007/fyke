using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private const int ReplyIndent = 16;
    private const int VisibleReplyDepth = 6;
    private ObservableCollection<DiscussionRow> visibleComments = [];
    private readonly HashSet<int> collapsedComments = [];
    private IReadOnlyList<DiscussionRow>? discussionRows;
    private DiscussionLink? discussionLink;
    private CancellationTokenSource? discussionRequest;
    private ArticleBlockRenderer commentRenderer = null!;
    private long discussionEntryId;

    private void InitializeDiscussion()
    {
        commentRenderer = new ArticleBlockRenderer(ReaderFaces.Shared, readerFonts, readerTextStyle);
        DiscussionComments.ElementClearing += (_, args) =>
        {
            if (args.Element is ContentPresenter presenter)
            {
                presenter.Content = null;
            }
        };
    }

    private void ResetDiscussion()
    {
        discussionRequest?.Cancel();
        discussionRequest = null;
        discussionLink = null;
        discussionRows = null;
        ArticleDiscussion.Visibility = Visibility.Collapsed;
        visibleComments.Clear();
        collapsedComments.Clear();
    }

    private void SetDiscussion(long entryId, DiscussionLink? link)
    {
        if (link is null)
        {
            return;
        }

        discussionEntryId = entryId;
        discussionLink = link;
        ArticleDiscussion.Visibility = Visibility.Visible;
        DiscussionWebsite.NavigateUri = link.Address;
        var isHackerNews = link.HackerNewsItem is not null;
        DiscussionWebsite.Content = isHackerNews ? "Open on Hacker News" : "Open discussion";
        AutomationProperties.SetAcceleratorKey(DiscussionWebsite, isHackerNews ? string.Empty : "C");
        if (isHackerNews)
        {
            ShowDiscussionState("Comments on Hacker News", "Read the thread here, under the article.",
                "Show comments", showWebsite: false);
        }
        else
        {
            ShowDiscussionState("Discussion", link.Address.Host);
        }
    }

    private void ShowDiscussionState(string heading, string detail, string? action = null, bool showWebsite = true)
    {
        DiscussionHeading.Text = heading;
        DiscussionDetail.Text = detail;
        DiscussionDetail.Visibility = detail.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        DiscussionAction.Content = action;
        DiscussionAction.Visibility = action is null ? Visibility.Collapsed : Visibility.Visible;
        DiscussionWebsite.Visibility = showWebsite ? Visibility.Visible : Visibility.Collapsed;
    }

    private Action? DiscussionLinkAction(Uri address) =>
        discussionLink?.HackerNewsItem is ulong item && DiscussionLink.GetHackerNewsItem(address) == item
            ? OpenDiscussionHere : null;

    private void DiscussionActionClicked(object sender, RoutedEventArgs args) => OpenDiscussionHere();

    private async void DiscussionShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!readerConnected || IsReaderCovered || discussionLink is null)
        {
            return;
        }

        args.Handled = true;
        await OpenCurrentDiscussionAsync();
    }

    private async Task OpenCurrentDiscussionAsync()
    {
        if (!readerConnected || discussionLink is not { } link)
        {
            return;
        }

        if (link.HackerNewsItem is not null)
        {
            OpenDiscussionHere();
        }
        else if (!await Launcher.LaunchUriAsync(link.Address) && ReferenceEquals(discussionLink, link))
        {
            ShowDiscussionState("Discussion", "Windows couldn’t open this link. Try opening it again.");
        }
    }

    private void OpenDiscussionHere()
    {
        if (!readerConnected || lifetime.IsCancellationRequested || discussionLink?.HackerNewsItem is null)
        {
            return;
        }

        DiscussionHeading.StartBringIntoView(new BringIntoViewOptions { VerticalAlignmentRatio = 0 });
        if (discussionRows is null && discussionRequest is null)
        {
            _ = LoadDiscussionAsync(discussionEntryId);
        }
    }

    private async Task LoadDiscussionAsync(long entryId)
    {
        using var request = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        discussionRequest = request;
        ShowDiscussionState("Loading comments from Hacker News…", string.Empty, showWebsite: false);
        try
        {
            var thread = await reader.DiscussionAsync(entryId, request.Token);
            request.Token.ThrowIfCancellationRequested();
            discussionRows = DiscussionRows.FromComments(thread.Comments);
            var count = discussionRows.Count;
            var number = count.ToString("N0", CultureInfo.CurrentCulture);
            var detail = thread.Truncated ? $"The first {number} from Hacker News. The rest are on the site."
                : count == 0 ? "No one has commented yet." : "From Hacker News";
            ShowDiscussionState(count == 1 ? "1 comment" : $"{number} comments", detail);
            visibleComments = new ObservableCollection<DiscussionRow>(discussionRows);
            DiscussionComments.ItemsSource = visibleComments;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch (Exception error) when (!request.IsCancellationRequested
            && error is DaemonException or TimeoutException or JsonException)
        {
            ShowDiscussionState("The comments did not load", "You can keep reading the article.",
                "Try again");
        }
        finally
        {
            if (ReferenceEquals(discussionRequest, request))
            {
                discussionRequest = null;
            }
        }
    }

    private void UpdateVisibleComments()
    {
        if (discussionRows is { } rows)
        {
            ReaderRows.Reconcile(visibleComments, DiscussionRows.Visible(rows, collapsedComments), row => row.Index);
        }
    }

    private void PrepareDiscussionComment(ItemsRepeater sender, ItemsRepeaterElementPreparedEventArgs args)
    {
        if (args.Element is ContentPresenter presenter && args.Index >= 0 && args.Index < visibleComments.Count)
        {
            presenter.Content = CreateDiscussionComment(visibleComments[args.Index]);
        }
    }

    private Grid CreateDiscussionComment(DiscussionRow row)
    {
        var comment = row.Comment;
        var depth = Math.Clamp(comment.Depth, 0, VisibleReplyDepth);
        var container = new Grid();
        var lineStyle = AppResources.FromApp<Style>("DiscussionReplyLine");
        for (var level = 0; level < depth; level++)
        {
            container.Children.Add(new Border { Style = lineStyle, Margin = new Thickness(level * ReplyIndent, 0, 0, 0) });
        }

        var content = new StackPanel { Spacing = 6, Margin = new Thickness(depth * ReplyIndent, 0, 0, 0) };
        container.Children.Add(content);
        var author = string.IsNullOrWhiteSpace(comment.Author) ? "Deleted comment" : comment.Author;
        var caption = author;
        if (comment.At is long timestamp && timestamp >= DateTimeOffset.MinValue.ToUnixTimeMilliseconds()
            && timestamp <= DateTimeOffset.MaxValue.ToUnixTimeMilliseconds())
        {
            var date = DateTimeOffset.FromUnixTimeMilliseconds(timestamp).ToLocalTime();
            caption = $"{author} · {date.ToString("g", CultureInfo.CurrentCulture)}";
        }

        var metadata = ReaderFaces.Shared.Bind(new TextBlock
        {
            Text = caption,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
        }, nameof(ReaderFaces.Ui));
        readerFonts.Bind(metadata, TextBlock.FontWeightProperty, nameof(ReaderFontWeights.SectionLabel));
        if (row.ReplyCount == 0 && comment.Blocks.Length == 0)
        {
            content.Children.Add(metadata);
            return container;
        }

        var icon = new FontIcon { FontSize = 12 };
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        label.Children.Add(icon);
        label.Children.Add(metadata);
        var toggle = new Button
        {
            Content = label, Padding = new Thickness(4), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left,
        };
        ReaderFaces.Shared.Bind(toggle, Control.CornerRadiusProperty, nameof(ReaderFaces.RadiusControl));
        var body = new StackPanel { Spacing = 8 };
        content.Children.Add(toggle);
        content.Children.Add(body);
        toggle.Click += (_, _) =>
        {
            if (!collapsedComments.Remove(row.Index))
            {
                collapsedComments.Add(row.Index);
            }

            ApplyDisclosure();
            UpdateVisibleComments();
        };
        ApplyDisclosure();
        return container;

        void ApplyDisclosure()
        {
            var folded = collapsedComments.Contains(row.Index);
            icon.Glyph = folded ? "\uE76C" : "\uE70D";
            var action = folded ? "Expand" : "Collapse";
            AutomationProperties.SetName(toggle, $"{action} comment by {author}");
            var hidden = !folded || row.ReplyCount == 0 ? null
                : row.ReplyCount == 1 ? "1 reply hidden" : $"{row.ReplyCount:N0} replies hidden";
            metadata.Text = hidden is null ? caption : $"{caption} · {hidden}";
            AutomationProperties.SetHelpText(toggle, hidden ?? string.Empty);
            ToolTipService.SetToolTip(toggle, $"{action} comment");
            body.Visibility = folded ? Visibility.Collapsed : Visibility.Visible;
            if (!folded && body.Children.Count == 0)
            {
                commentRenderer.Append(body, comment.Blocks);
            }
        }
    }
}
