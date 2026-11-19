using System;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace Fyke.App;

/// <summary>The single-key commands macOS and the terminal app share (gui/Sources/Reader/RootView.swift).</summary>
/// <remarks>M, S, C and R live with the features they drive. Every key here is ignored while an
/// overlay or Settings covers the reader, so typing never triggers one.</remarks>
public sealed partial class MainWindow
{
    private bool unreadOnly;
    private Uri? articlePage;
    private long? fetchingFullText;

    private void InitializeKeys() => Root.PreviewKeyDown += SearchSlashKeyDown;

    private void NavigationShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!readerConnected || IsReaderCovered)
        {
            return;
        }

        args.Handled = sender.Key switch
        {
            VirtualKey.J => MoveSelection(1),
            VirtualKey.K => MoveSelection(-1),
            VirtualKey.N => NextUnread(),
            VirtualKey.U => ToggleUnreadOnly(),
            VirtualKey.O => OpenArticlePage(),
            VirtualKey.F => FetchFullText(),
            VirtualKey.A => Run(() => OpenAddFeed()),
            VirtualKey.T => Run(OpenTextSettings),
            _ => false,
        };

        static bool Run(Action action)
        {
            action();
            return true;
        }
    }

    // A KeyboardAccelerator cannot take "/": WinUI can fail fast formatting an OEM key's name,
    // as with Ctrl+, in Settings.
    private void SearchSlashKeyDown(object sender, KeyRoutedEventArgs args)
    {
        const VirtualKey slash = (VirtualKey)0xBF;
        if (args.OriginalKey != slash || !readerConnected || IsReaderCovered || args.KeyStatus.WasKeyDown
            || FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox or PasswordBox or RichEditBox
            || IsModifierDown(VirtualKey.Control) || IsModifierDown(VirtualKey.Menu) || IsModifierDown(VirtualKey.Shift))
        {
            return;
        }

        args.Handled = true;
        OpenSearch();
    }

    private static bool IsModifierDown(VirtualKey key) =>
        (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;

    /// <summary>Selects the next or previous article, which opens it, as J and K do on macOS.</summary>
    private bool MoveSelection(int offset)
    {
        if (articles.Count == 0)
        {
            return false;
        }

        var index = Timeline.SelectedIndex;
        if (index < 0)
        {
            index = offset > 0 ? -1 : articles.Count;
        }

        var next = Math.Clamp(index + offset, 0, articles.Count - 1);
        if (next != Timeline.SelectedIndex)
        {
            Timeline.SelectedIndex = next;
            Timeline.ScrollIntoView(articles[next]);
        }

        return true;
    }

    /// <summary>Opens the first unread article after the selected one. None after it does nothing.</summary>
    private bool NextUnread()
    {
        for (var i = Timeline.SelectedIndex + 1; i < articles.Count; i++)
        {
            if (!articles[i].Read)
            {
                Timeline.SelectedIndex = i;
                Timeline.ScrollIntoView(articles[i]);
                return true;
            }
        }

        return false;
    }

    private bool ToggleUnreadOnly()
    {
        unreadOnly = !unreadOnly;
        _ = LoadReaderAsync();
        return true;
    }

    /// <summary>Opens the article's own page in the browser. Windows has no in-app page view yet,
    /// so O and Shift+O both do what Shift+O does on macOS.</summary>
    private bool OpenArticlePage()
    {
        if (articlePage is not { } page)
        {
            return false;
        }

        _ = Launcher.LaunchUriAsync(page);
        return true;
    }

    private void OpenTextSettings()
    {
        OpenSettings();
        if (IsSettingsOpen)
        {
            SettingsTabs.SelectedItem = ReadingSettingsTab;
            TextSizeSlider.Focus(FocusState.Programmatic);
        }
    }

    private bool FetchFullText()
    {
        if (!articleReady || openArticle is not { } article || fetchingFullText is not null)
        {
            return false;
        }

        _ = FetchFullTextAsync(article);
        return true;
    }

    /// <summary>Fetches the article from its page now, then shows it again if that found more.</summary>
    private async Task FetchFullTextAsync(TimelineArticle article)
    {
        fetchingFullText = article.Id;
        ShowArticleNote("Fetching the article…");
        try
        {
            var outcome = await reader.FetchFullAsync(article.Id, lifetime.Token);
            if (openArticle?.Id != article.Id || lifetime.IsCancellationRequested)
            {
                return;
            }

            if (outcome == FullTextOutcome.Done)
            {
                _ = OpenArticleAsync(openArticle);
            }
            else
            {
                ShowArticleNote(outcome == FullTextOutcome.Later
                    ? "Could not reach the page. It will be tried again."
                    : "No fuller article found on the page");
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            if (openArticle?.Id == article.Id)
            {
                ShowArticleNote(error is DaemonOutcomeUnknownException
                    ? "Fyke couldn’t confirm the fetch. The article is still available."
                    : "Fyke couldn’t fetch the article. Try again.");
            }
        }
        finally
        {
            fetchingFullText = null;
        }
    }

    // The line under the article's marks, shared by mark failures and full-text fetches.
    private void ShowArticleNote(string text)
    {
        MarkStatus.Text = text;
        MarkStatus.Visibility = Visibility.Visible;
    }
}
