using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private bool viewDialogOpen;

    private void EditViewClicked(object sender, RoutedEventArgs args)
    {
        if (destination is { Scope: ReaderScope.View } view)
        {
            _ = OpenViewEditorAsync(id: view.Id);
        }
    }

    private void SaveSearchViewClicked(object sender, RoutedEventArgs args) => SaveSearchView();

    private void SaveSearchViewShortcut(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsSearchOpen && SaveSearchViewButton.IsEnabled)
        {
            args.Handled = true;
            SaveSearchView();
        }
    }

    private void SaveSearchView() => _ = OpenViewEditorAsync(ViewRule.FromSearch(SearchQuery.Text, SearchUnread.IsChecked == true));

    private Task OpenViewEditorAsync(ViewRule? initialRule = null, long? id = null) => RunViewDialogAsync(async () =>
    {
        var existing = id is { } viewId ? await reader.Views.GetAsync(viewId, lifetime.Token) : null;
        if (lifetime.IsCancellationRequested)
        {
            return;
        }

        var rule = existing?.Rule ?? initialRule ?? new ViewRule();
        var suggestion = rule.Words ?? (rule.State == "unread" ? "Unread" : string.Empty);
        var name = existing?.Name ?? (Encoding.UTF8.GetByteCount(suggestion) <= 200 ? suggestion : string.Empty);
        var editor = new ViewEditor(name, rule, catalog);
        var dialog = CreateViewDialog(existing is null ? "New saved view" : "Edit saved view", editor.Content, "Save view");
        dialog.SecondaryButtonText = "Preview";
        dialog.DefaultButton = ContentDialogButton.Primary;
        dialog.Opened += (_, _) => editor.FocusName();
        var busy = false;
        var requiresReload = false;
        SavedView? saved = null;

        dialog.Closing += (_, args) => args.Cancel = busy;
        dialog.PrimaryButtonClick += async (_, args) => await ApplyAsync(args, preview: false);
        dialog.SecondaryButtonClick += async (_, args) => await ApplyAsync(args, preview: true);

        await dialog.ShowAsync();
        if (lifetime.IsCancellationRequested)
        {
            return;
        }

        if (saved is not null && existing is null)
        {
            NavigateToDestination(new(ReaderScope.View, saved.Id, saved.Name, 0, 0, RuleSummary: saved.Sentence), refreshCatalog: true);
            var made = saved;
            OfferViewUndo($"Saved “{made.Name}” as a view.", $"Fyke couldn’t take back “{made.Name}”.", async () =>
            {
                await ViewUndo.UndoCreateAsync(reader.Views, made, lifetime.Token);
                return null;
            }, leaving: made.Id);
        }
        else if (saved is not null || requiresReload)
        {
            await LoadReaderAsync(refreshCatalog: true);
            if (saved is not null && existing is not null && !SameView(existing, saved))
            {
                var before = existing;
                OfferViewUndo($"Changed “{saved.Name}”.", $"Fyke couldn’t put back “{before.Name}”.",
                    async () => await ViewUndo.UndoEditAsync(reader.Views, before, lifetime.Token));
            }
        }

        async Task ApplyAsync(ContentDialogButtonClickEventArgs args, bool preview)
        {
            args.Cancel = true;
            if (busy || requiresReload || lifetime.IsCancellationRequested)
            {
                return;
            }

            var title = editor.Name;
            if (!preview && (title.Length == 0 || Encoding.UTF8.GetByteCount(title) > 200))
            {
                editor.ShowStatus("Enter a name for the view. Use a shorter name if needed.");
                editor.FocusName();
                return;
            }
            if (editor.CaptureRule() is not { } edited)
            {
                return;
            }

            var deferral = args.GetDeferral();
            busy = true;
            dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = false;
            editor.SetInputEnabled(false);
            editor.ShowStatus(preview ? "Checking matches…" : "Saving view…");
            try
            {
                if (preview)
                {
                    var result = await reader.Views.PreviewAsync(edited, lifetime.Token);
                    editor.ShowStatus($"{CountLabel(result.Total, "matching article")} · {result.Unread:N0} unread");
                }
                else
                {
                    saved = await reader.Views.SaveAsync(title, edited, existing, lifetime.Token);
                    args.Cancel = false;
                }
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
            {
            }
            catch (DaemonRpcException error) when (error.Is("RevisionConflict") || error.Is("NoSuchView"))
            {
                requiresReload = true;
                editor.ShowStatus("This view changed elsewhere. Close the editor to load the latest version.");
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
            {
                requiresReload = !preview && (error is DaemonOutcomeUnknownException or TimeoutException or DaemonProtocolException or JsonException);
                editor.ShowStatus(ViewFailure(error));
            }
            finally
            {
                busy = false;
                editor.SetInputEnabled(true);
                dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = !requiresReload;
                deferral.Complete();
            }
        }
    });

    private int? ViewMovePosition(long id, int offset)
    {
        var views = catalog.Where(row => row.Scope == ReaderScope.View).ToArray();
        var index = Array.FindIndex(views, view => view.Id == id);
        var target = index + offset;
        return index >= 0 && target >= 0 && target < views.Length ? target : null;
    }

    private Task MoveViewAsync(long id, int offset) => RunViewDialogAsync(async () =>
    {
        if (ViewMovePosition(id, offset) is { } position)
        {
            await reader.Views.MoveAsync(id, position, lifetime.Token);
            await LoadReaderAsync(refreshCatalog: true);
        }
    });

    /// <summary>
    /// Deletes at once and offers Undo, as on macOS, instead of asking first. Routines that
    /// look in the view are turned off and detached; Undo makes the view again at its place
    /// and points them back at it.
    /// </summary>
    private Task DeleteViewAsync(ReaderDestination view) => RunViewDialogAsync(async () =>
    {
        var removed = await reader.Views.GetAsync(view.Id, lifetime.Token);
        var position = ViewMovePosition(view.Id, 0) ?? 0;
        IReadOnlyList<Routine> users = [];
        var result = await reader.Views.RemoveAsync(view.Id, detach: false, lifetime.Token);
        if (result.Kind == "in_use")
        {
            var ids = result.RoutineIds ?? [];
            users = [.. (await routines.ListAsync(lifetime.Token)).Where(routine => routine.Id is { } id && ids.Contains(id))];
            result = await reader.Views.RemoveAsync(view.Id, detach: true, lifetime.Token);
        }

        if (!result.Ok)
        {
            throw new DaemonProtocolException("The daemon did not confirm the saved view removal.");
        }

        if (!lifetime.IsCancellationRequested && destination is { Scope: ReaderScope.View } active && active.Id == view.Id)
        {
            NavigateToDestination(catalog.First(row => row.Scope == ReaderScope.All), refreshCatalog: true);
        }
        else
        {
            await LoadReaderAsync(refreshCatalog: true);
        }

        OfferViewUndo(ViewUndo.Removed(removed.Name, users.Count), $"Fyke couldn’t restore “{removed.Name}”.",
            async () => await ViewUndo.UndoRemoveAsync(reader.Views, routines, removed, position, users, lifetime.Token));
    });

    private static bool SameView(SavedView a, SavedView b) => a.Name == b.Name && a.Sentence == b.Sentence;

    /// <summary>Shows the notice for a view change, whose Undo (the button or Ctrl+Z) runs
    /// <paramref name="undo"/> and opens the view it returns.</summary>
    private void OfferViewUndo(string message, string failure, Func<Task<SavedView?>> undo, long? leaving = null)
    {
        ShowBulkNotice(message, offerUndo: true);
        noticeUndo = async () =>
        {
            try
            {
                if (leaving is { } id && destination is { Scope: ReaderScope.View } open && open.Id == id)
                {
                    NavigateToDestination(catalog.First(row => row.Scope == ReaderScope.All), refreshCatalog: false);
                }

                var view = await undo();
                if (view is not null)
                {
                    NavigateToDestination(new(ReaderScope.View, view.Id, view.Name, 0, 0, RuleSummary: view.Sentence), refreshCatalog: true);
                }
                else
                {
                    await LoadReaderAsync(refreshCatalog: true);
                }
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
            {
            }
            catch (Exception error) when (error is DaemonException or TimeoutException or JsonException or ArgumentException or RoutineConflictException)
            {
                ShowBulkNotice($"{failure} {ViewFailure(error)}");
                await LoadReaderAsync(refreshCatalog: true);
            }
        };
    }

    private async Task RunViewDialogAsync(Func<Task> action)
    {
        if (!readerConnected || viewDialogOpen || lifetime.IsCancellationRequested || !CloseAddFeed() || !CloseCatalogEdit())
        {
            return;
        }

        viewDialogOpen = true;
        CloseSearch();
        ClosePalette();
        try
        {
            await action();
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            SetSubscriptionStatus(ViewFailure(error));
            await LoadReaderAsync(refreshCatalog: true);
        }
        finally
        {
            viewDialogOpen = false;
        }
    }

    private ContentDialog CreateViewDialog(string title, object content, string action) => new()
    {
        XamlRoot = Root.XamlRoot,
        RequestedTheme = Root.RequestedTheme,
        Title = title,
        Content = content,
        PrimaryButtonText = action,
        CloseButtonText = "Cancel",
    };

    private static string ViewFailure(Exception error) => error switch
    {
        DaemonRpcException rpc when rpc.IsUnknownMethod => "This version of the Fyke daemon doesn’t support saved views.",
        DaemonRpcException rpc when rpc.Is("NoSuchView") => "This view has already been deleted.",
        DaemonRpcException rpc when rpc.Is("NoSuchFeed") || rpc.Is("NoSuchFolder") =>
            "One of the selected feeds or folders is unavailable. Remove it from the selection and try again.",
        DaemonRpcException rpc when rpc.Is("InvalidRule") => "Check the filters. Enter a host such as example.com and paths starting with /.",
        DaemonOutcomeUnknownException or TimeoutException or DaemonProtocolException or JsonException =>
            "Fyke couldn’t confirm the result. Check the sidebar before trying again.",
        _ => "Fyke couldn’t complete the saved view action. Try again.",
    };
}
