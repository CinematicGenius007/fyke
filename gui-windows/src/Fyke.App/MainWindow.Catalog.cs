using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private enum CatalogEditKind { CreateFolder, Rename, Move, Remove }

    private sealed record CatalogEditDraft(CatalogEditKind Kind, ReaderDestination? Item);

    private CatalogEdits catalogEdits = null!;
    private CatalogEditDraft? catalogDraft;
    private bool savingCatalogEdit;
    private bool IsCatalogEditOpen => CatalogEditOverlay?.Visibility == Visibility.Visible;

    private void InitializeCatalogEditing()
    {
        catalogEdits = new CatalogEdits(client);
        CatalogEditOverlay.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(CatalogEditKeyDown), true);
    }

    private void PrepareDestinationActions(Grid row, ReaderDestination item)
    {
        if (item.Scope == ReaderScope.Starred)
        {
            row.ContextFlyout = null;
            return;
        }

        if (row.ContextFlyout is not null)
        {
            return;
        }

        var flyout = new MenuFlyout();
        var rename = Add("Rename", target => OpenCatalogEdit(CatalogEditKind.Rename, target));
        var move = Add("Move to…", target => OpenCatalogEdit(CatalogEditKind.Move, target));
        var create = Add("New folder", target => OpenCatalogEdit(CatalogEditKind.CreateFolder, target));
        var addFeed = Add("Add feed here", target => OpenAddFeed(target.Id));
        var refresh = Add("Refresh", target => _ = RefreshSubscriptionsAsync(target.Scope == ReaderScope.Feed ? target : null));
        var mark = Add("Mark all read", target => StartBulkMark(target));
        var remove = Add("Remove…", target => OpenCatalogEdit(CatalogEditKind.Remove, target));
        flyout.Opening += (_, _) =>
        {
            var scope = (row.DataContext as ReaderDestination)?.Scope;
            var editable = scope is ReaderScope.Feed or ReaderScope.Folder;
            rename.Visibility = move.Visibility = editable ? Visibility.Visible : Visibility.Collapsed;
            create.Visibility = scope is ReaderScope.All or ReaderScope.Folder ? Visibility.Visible : Visibility.Collapsed;
            create.Text = scope == ReaderScope.Folder ? "New folder inside" : "New folder";
            addFeed.Visibility = scope == ReaderScope.Folder ? Visibility.Visible : Visibility.Collapsed;
            refresh.Visibility = scope is ReaderScope.All or ReaderScope.Feed ? Visibility.Visible : Visibility.Collapsed;
            refresh.Text = scope == ReaderScope.Feed ? "Refresh feed" : "Refresh all feeds";
            refresh.IsEnabled = !refreshingSubscriptions;
            mark.IsEnabled = CanChangeBulkMarks;
            remove.Visibility = editable ? Visibility.Visible : Visibility.Collapsed;
            remove.Text = scope == ReaderScope.Folder ? "Delete folder…" : "Remove feed…";
        };
        row.ContextFlyout = flyout;

        MenuFlyoutItem Add(string label, Action<ReaderDestination> run)
        {
            var action = new MenuFlyoutItem { Text = label };
            action.Click += (_, _) =>
            {
                if (row.DataContext is ReaderDestination target)
                {
                    run(target);
                }
            };
            flyout.Items.Add(action);
            return action;
        }
    }

    private void OpenCatalogEdit(CatalogEditKind kind, ReaderDestination? item = null)
    {
        if (!readerConnected || !CloseCatalogEdit() || !CloseAddFeed())
        {
            return;
        }

        if (item is { } requested)
        {
            item = catalog.FirstOrDefault(row => row.Scope == requested.Scope && row.Id == requested.Id);
        }

        if (kind != CatalogEditKind.CreateFolder && item is not { Scope: ReaderScope.Feed or ReaderScope.Folder })
        {
            return;
        }

        CloseSearch();
        ClosePalette();
        catalogDraft = new CatalogEditDraft(kind, item);
        CatalogEditHeading.Text = kind switch
        {
            CatalogEditKind.Rename => $"Rename {item!.Title}",
            CatalogEditKind.Move => $"Move {item!.Title}",
            CatalogEditKind.Remove => item!.Scope == ReaderScope.Folder ? $"Delete {item.Title}?" : $"Remove {item.Title}?",
            _ => item is { Scope: ReaderScope.Folder } ? $"New folder in {item.Title}" : "New folder",
        };
        var moving = kind == CatalogEditKind.Move;
        var removing = kind == CatalogEditKind.Remove;
        CatalogEditName.Visibility = moving || removing ? Visibility.Collapsed : Visibility.Visible;
        CatalogMoveTarget.Visibility = moving ? Visibility.Visible : Visibility.Collapsed;
        CatalogDeleteContents.Visibility = Visibility.Collapsed;
        CatalogDeleteContents.IsChecked = false;
        CatalogEditName.Text = kind == CatalogEditKind.Rename ? item!.Title : string.Empty;
        CatalogEditHint.Text = kind == CatalogEditKind.Rename && item!.Scope == ReaderScope.Feed
            ? "Clear the name to use the feed’s own title." : string.Empty;
        CatalogEditHint.Visibility = CatalogEditHint.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (removing)
        {
            UpdateRemovalHint(item!);
        }
        if (moving)
        {
            var choices = FolderChoice.FromCatalog(catalog, "Top level",
                item is { Scope: ReaderScope.Folder } ? item.Id : null);
            CatalogMoveTarget.ItemsSource = choices;
            CatalogMoveTarget.SelectedItem = choices.FirstOrDefault(choice => choice.Id == item!.ParentId) ?? choices[0];
        }

        CatalogEditStatus.Visibility = Visibility.Collapsed;
        Control focus = removing ? CatalogEditCancel : moving ? CatalogMoveTarget : CatalogEditName;
        ShowReaderOverlay(CatalogEditOverlay, focus);
        if (!moving && !removing)
        {
            CatalogEditName.SelectAll();
        }

        UpdateCatalogEditControls();
    }

    private bool CloseCatalogEdit(bool restoreFocus = true)
    {
        if (savingCatalogEdit)
        {
            return false;
        }

        if (IsCatalogEditOpen)
        {
            HideReaderOverlay(CatalogEditOverlay, PaletteButton, restoreFocus);
            catalogDraft = null;
            CatalogMoveTarget.ItemsSource = null;
        }

        return true;
    }

    private void CatalogEditBackdropPressed(object sender, PointerRoutedEventArgs args)
    {
        args.Handled = true;
        CloseCatalogEdit();
    }

    private void CatalogEditCancelClicked(object sender, RoutedEventArgs args) => CloseCatalogEdit();

    private void CatalogEditKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape && !CatalogMoveTarget.IsDropDownOpen)
        {
            args.Handled = true;
            CloseCatalogEdit();
        }
        else if (args.Key == VirtualKey.Enter && catalogDraft?.Kind != CatalogEditKind.Remove
            && CatalogEditName.FocusState != FocusState.Unfocused
            && CatalogEditConfirm.IsEnabled)
        {
            args.Handled = true;
            _ = SaveCatalogEditAsync();
        }
    }

    private void CatalogEditNameChanged(object sender, TextChangedEventArgs args) => UpdateCatalogEditControls();

    private void CatalogEditTargetChanged(object sender, SelectionChangedEventArgs args) => UpdateCatalogEditControls();

    private void UpdateCatalogEditControls()
    {
        if (!IsCatalogEditOpen || catalogDraft is not { } draft)
        {
            return;
        }

        CatalogEditName.IsEnabled = CatalogMoveTarget.IsEnabled = CatalogEditCancel.IsEnabled = !savingCatalogEdit;
        CatalogDeleteContents.IsEnabled = !savingCatalogEdit;
        CatalogEditConfirm.IsEnabled = readerConnected && !savingCatalogEdit && (draft.Kind switch
        {
            CatalogEditKind.Move => CatalogMoveTarget.SelectedItem is FolderChoice choice && choice.Id != draft.Item!.ParentId,
            CatalogEditKind.Rename when draft.Item!.Scope == ReaderScope.Feed => CatalogEditName.Text.Trim() != draft.Item.Title,
            CatalogEditKind.Rename => !string.IsNullOrWhiteSpace(CatalogEditName.Text) && CatalogEditName.Text.Trim() != draft.Item!.Title,
            CatalogEditKind.Remove => true,
            _ => !string.IsNullOrWhiteSpace(CatalogEditName.Text),
        });
        CatalogEditConfirm.Content = draft.Kind switch
        {
            CatalogEditKind.Move => "Move",
            CatalogEditKind.Rename => "Save name",
            CatalogEditKind.Remove => draft.Item!.Scope == ReaderScope.Folder ? "Delete folder" : "Remove feed",
            _ => "Create folder",
        };
    }

    private void CatalogEditConfirmClicked(object sender, RoutedEventArgs args) => _ = SaveCatalogEditAsync();

    private async Task SaveCatalogEditAsync()
    {
        if (savingCatalogEdit || !readerConnected || !CatalogEditConfirm.IsEnabled || catalogDraft is not { } draft)
        {
            return;
        }

        var name = CatalogEditName.Text;
        var parent = (CatalogMoveTarget.SelectedItem as FolderChoice)?.Id;
        var deleteContents = CatalogDeleteContents.IsChecked == true;
        var removal = draft.Kind == CatalogEditKind.Remove ? CatalogRemoval.FromCatalog(draft.Item!, catalog) : null;
        savingCatalogEdit = true;
        CatalogEditStatus.Text = "Saving…";
        CatalogEditStatus.Visibility = Visibility.Visible;
        UpdateCatalogEditControls();
        var saved = false;
        try
        {
            var ct = lifetime.Token;
            await (draft.Kind switch
            {
                CatalogEditKind.Rename => catalogEdits.RenameAsync(draft.Item!, name, ct),
                CatalogEditKind.Move => catalogEdits.MoveAsync(draft.Item!, parent, ct),
                CatalogEditKind.Remove => catalogEdits.RemoveAsync(draft.Item!, deleteContents, ct),
                _ => catalogEdits.CreateFolderAsync(name, draft.Item is { Scope: ReaderScope.Folder } folder ? folder.Id : null, ct),
            });
            saved = true;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (!lifetime.IsCancellationRequested && error is DaemonException or TimeoutException or JsonException)
        {
            CatalogEditStatus.Text = error switch
            {
                DaemonRpcException rpc when rpc.Is("FolderExists") => "A folder with that name already exists there.",
                DaemonRpcException rpc when rpc.Is("FolderCycle") => "Choose a folder outside the one you’re moving.",
                DaemonRpcException rpc when rpc.Is("NoSuchFolder") => "That folder is unavailable.",
                DaemonOutcomeUnknownException => "Fyke couldn’t confirm the change. Check the sidebar before trying again.",
                _ => "Fyke couldn’t save this change. Try again.",
            };
        }
        finally
        {
            savingCatalogEdit = false;
        }

        if (!lifetime.IsCancellationRequested)
        {
            if (saved)
            {
                if (draft.Kind == CatalogEditKind.Move)
                {
                    // An article can leave the current timeline when its feed moves to another folder.
                    SetTimelineSelection(null);
                }
                else if (removal is not null)
                {
                    ApplyCatalogRemoval(removal, deleteContents);
                }

                CloseCatalogEdit();
            }
            else
            {
                UpdateCatalogEditControls();
            }

            _ = LoadReaderAsync(refreshCatalog: true);
        }
    }
}
