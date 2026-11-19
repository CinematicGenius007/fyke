using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private const string FolderDisclosureSaveProblem = "Fyke couldn’t save which folders are collapsed. The sidebar still works.";

    private readonly HashSet<long> collapsedFolders = [];
    private bool folderCatalogShown;
    private bool folderDisclosureDirty;
    private Task? folderDisclosureSave;
    private bool waitingForFolderSaveOnClose;

    private void RestoreFolderDisclosure(ReaderPreferences loaded)
    {
        if (!folderCatalogShown && !loaded.InvalidConfig)
        {
            collapsedFolders.Clear();
            collapsedFolders.UnionWith(loaded.CollapsedFolderIds);
        }
    }

    private void UpdateFolderCatalog(IReadOnlyList<ReaderDestination> rows)
    {
        folderCatalogShown = true;
        if (collapsedFolders.Count > 0)
        {
            var previousCount = collapsedFolders.Count;
            collapsedFolders.IntersectWith(rows.Where(row => row.Scope == ReaderScope.Folder).Select(row => row.Id));
            if (collapsedFolders.Count != previousCount)
            {
                QueueFolderDisclosureSave();
            }
        }
    }

    private void QueueFolderDisclosureSave()
    {
        folderDisclosureDirty = true;
        TrySaveFolderDisclosure();
    }

    private void TrySaveFolderDisclosure()
    {
        if (readerConnected && folderDisclosureDirty && folderDisclosureSave is not { IsCompleted: false }
            && !lifetime.IsCancellationRequested)
        {
            folderDisclosureSave = SaveFolderDisclosureAsync();
        }
    }

    private async Task SaveFolderDisclosureAsync()
    {
        var ct = lifetime.Token;
        try
        {
            // Serialize writes so a rapid second click cannot be overwritten by the first save.
            while (folderDisclosureDirty && readerConnected)
            {
                folderDisclosureDirty = false;
                var snapshot = collapsedFolders.Order().ToArray();
                await readerSettings.SetCollapsedFoldersAsync(snapshot, ct);
                var saved = await readerSettings.ReadAsync(ct);
                ct.ThrowIfCancellationRequested();
                if (saved.InvalidConfig || !snapshot.SequenceEqual(saved.CollapsedFolderIds))
                {
                    throw new DaemonProtocolException("The daemon did not confirm the collapsed folders.");
                }
            }

            if (!folderDisclosureDirty && !ct.IsCancellationRequested && SubscriptionStatus.Text == FolderDisclosureSaveProblem)
            {
                SubscriptionStatus.Visibility = Visibility.Collapsed;
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            folderDisclosureDirty = true;
            SetSubscriptionStatus(FolderDisclosureSaveProblem);
        }
    }

    private async void FinishFolderDisclosureBeforeClose(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (waitingForFolderSaveOnClose)
        {
            args.Cancel = true;
            return;
        }

        if (folderDisclosureSave is not { IsCompleted: false } save)
        {
            return;
        }

        args.Cancel = true;
        waitingForFolderSaveOnClose = true;
        try
        {
            await save.WaitAsync(TimeSpan.FromSeconds(1));
        }
        catch (TimeoutException)
        {
            // Closing the window stays bounded if the daemon is no longer responding.
        }
        finally
        {
            AppWindow.Closing -= FinishFolderDisclosureBeforeClose;
            Close();
        }
    }
}
