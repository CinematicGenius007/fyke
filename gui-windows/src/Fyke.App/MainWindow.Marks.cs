using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private readonly HashSet<long> pendingMarks = [];
    private bool articleReady;

    private void StarArticleClicked(object sender, RoutedEventArgs args) => ToggleArticleMark(VirtualKey.S);

    private void ReadArticleClicked(object sender, RoutedEventArgs args) => ToggleArticleMark(VirtualKey.M);

    private void ArticleMarkShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!IsReaderCovered && ToggleArticleMark(sender.Key))
        {
            args.Handled = true;
        }
    }

    private bool ToggleArticleMark(VirtualKey key)
    {
        if (!readerConnected || !articleReady || openArticle is not { } article || pendingMarks.Contains(article.Id))
        {
            return false;
        }

        if (key == VirtualKey.S)
        {
            _ = MarkArticleAsync(article.Id, read: null, starred: !article.Starred);
        }
        else
        {
            _ = MarkArticleAsync(article.Id, read: !article.Read, starred: null);
        }

        return true;
    }

    private async Task MarkArticleAsync(long id, bool? read, bool? starred)
    {
        if (lifetime.IsCancellationRequested || !pendingMarks.Add(id))
        {
            return;
        }

        MarkStatus.Visibility = Visibility.Collapsed;
        UpdateMarkControls();
        try
        {
            var marks = await reader.MarkAsync(id, read, starred, lifetime.Token);
            if (!lifetime.IsCancellationRequested)
            {
                ApplyArticleMarks(id, marks);
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (!lifetime.IsCancellationRequested && articleReady && openArticle?.Id == id)
            {
                MarkStatus.Text = error is DaemonOutcomeUnknownException
                    ? "Fyke couldn’t confirm the change. The article is still available."
                    : "Fyke couldn’t change the article marks. Try again.";
                MarkStatus.Visibility = Visibility.Visible;
            }
        }
        finally
        {
            pendingMarks.Remove(id);
            if (!lifetime.IsCancellationRequested)
            {
                UpdateMarkControls();
            }
        }
    }

    private void ApplyArticleMarks(long id, ArticleMarks marks)
    {
        if (articleReady && openArticle is { } article && article.Id == id)
        {
            openArticle = article with { Read = marks.Read, Starred = marks.Starred };
            UpdateMarkControls();
        }
    }

    private void UpdateMarkControls()
    {
        ArticleActions.Visibility = articleReady ? Visibility.Visible : Visibility.Collapsed;
        if (!articleReady || openArticle is not { } article)
        {
            return;
        }

        var canMark = readerConnected && !pendingMarks.Contains(article.Id);
        StarArticle.IsEnabled = canMark;
        ReadArticle.IsEnabled = canMark;
        UpdateMarkButton(StarArticle, StarMarkIcon, active: article.Starred,
            article.Starred ? "\uE735" : "\uE734", article.Starred ? "Remove star" : "Star article");
        UpdateMarkButton(ReadArticle, ReadMarkIcon, active: !article.Read,
            article.Read ? "\uEA3A" : "\uEA3B", article.Read ? "Mark as unread" : "Mark as read");
    }

    private void UpdateMarkButton(Button button, FontIcon icon, bool active, string glyph, string label)
    {
        icon.Glyph = glyph;
        icon.Style = Root.Resources.Get<Style>(active ? "ActiveArticleMark" : "InactiveArticleMark");
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
    }
}
