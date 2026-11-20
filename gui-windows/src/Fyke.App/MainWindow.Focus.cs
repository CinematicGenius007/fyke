using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private Control? focusBeforeOverlay;

    private bool IsReaderOverlayOpen => IsSearchOpen || IsPaletteOpen || IsAddFeedOpen || IsCatalogEditOpen || viewDialogOpen
        || IsCatchUpOpen;

    // Ask covers the article, so single-key commands neither act on it unseen nor fire while a question is typed.
    private bool IsReaderCovered => IsReaderOverlayOpen || IsSettingsOpen || IsAskShown || IsRecipeShown
        || IsRoutinesShown;

    private void ShowReaderOverlay(Grid overlay, Control initialFocus)
    {
        focusBeforeOverlay = FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
        ReaderShell.IsHitTestVisible = false;
        overlay.Visibility = Visibility.Visible;
        initialFocus.Focus(FocusState.Programmatic);
    }

    private void HideReaderOverlay(Grid overlay, Button opener, bool restoreFocus)
    {
        overlay.Visibility = Visibility.Collapsed;
        ReaderShell.IsHitTestVisible = true;
        if (restoreFocus && focusBeforeOverlay?.Focus(FocusState.Programmatic) != true)
        {
            opener.Focus(FocusState.Programmatic);
        }

        focusBeforeOverlay = null;
    }

    private void HandleOverlayKeys(KeyRoutedEventArgs args, TextBox query, ListView results, Action close, Action<object> open)
    {
        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            close();
        }
        else if (results.Items.Count > 0 && query.FocusState != FocusState.Unfocused
            && args.Key is VirtualKey.Up or VirtualKey.Down)
        {
            args.Handled = true;
            var step = args.Key == VirtualKey.Up ? -1 : 1;
            results.SelectedIndex = Math.Clamp(results.SelectedIndex + step, 0, results.Items.Count - 1);
            results.ScrollIntoView(results.SelectedItem);
        }
        else if (args.Key == VirtualKey.Enter && results.SelectedItem is { } item
            && FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox or ListViewItem or ListView)
        {
            args.Handled = true;
            open(item);
        }
    }

    private void PaneFocusShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!readerConnected || IsReaderOverlayOpen)
        {
            return;
        }

        var reverse = sender.Modifiers == VirtualKeyModifiers.Shift;
        var pane = FocusManager.GetFocusedElement(Root.XamlRoot) as DependencyObject;
        while (pane is UIElement && pane != SidebarPane && pane != TimelinePane && pane != ArticlePane && pane != SettingsPane
            && pane != RoutinesPane)
        {
            pane = VisualTreeHelper.GetParent(pane);
        }

        if (IsRoutinesShown)
        {
            if (pane == SidebarPane)
            {
                FocusList(RoutineRows);
            }
            else
            {
                FocusSidebar();
            }
        }
        else if (IsSettingsOpen)
        {
            if (pane == SidebarPane)
            {
                CloseSettingsButton.Focus(FocusState.Keyboard);
            }
            else
            {
                FocusSidebar();
            }
        }
        else if ((pane == SidebarPane && !reverse) || (pane == ArticlePane && reverse))
        {
            FocusTimeline();
        }
        else if ((pane == TimelinePane && !reverse) || (pane == SidebarPane && reverse))
        {
            FocusArticle();
        }
        else
        {
            FocusSidebar();
        }

        args.Handled = true;
    }

    private void FocusSidebar() => FocusList(Destinations);

    private void FocusTimeline()
    {
        if (IsTodayShown)
        {
            if (BriefRows.Items.Count > 0)
            {
                FocusList(BriefRows);
            }
            else
            {
                WriteBriefButton.Focus(FocusState.Keyboard);
            }
        }
        else if (Timeline.Items.Count == 0)
        {
            SearchButton.Focus(FocusState.Keyboard);
        }
        else
        {
            FocusList(Timeline);
        }
    }

    private void FocusArticle() => ArticleScroller.Focus(FocusState.Keyboard);

    private static void FocusList(ListView list)
    {
        if (list.SelectedItem is not { } selected || list.ContainerFromItem(selected) is not ListViewItem row
            || !row.Focus(FocusState.Keyboard))
        {
            list.Focus(FocusState.Keyboard);
        }
    }
}
