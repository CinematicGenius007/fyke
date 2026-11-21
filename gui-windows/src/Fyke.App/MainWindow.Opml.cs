using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Microsoft.UI.Xaml;
using Microsoft.Windows.Storage.Pickers;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private bool transferringOpml;

    private void ImportOpmlClicked(object sender, RoutedEventArgs args) => _ = ImportOpmlAsync();

    private async Task ImportOpmlAsync()
    {
        if (!readerConnected || transferringOpml || lifetime.IsCancellationRequested)
        {
            return;
        }

        transferringOpml = true;
        try
        {
            var picker = new FileOpenPicker(AppWindow.Id);
            picker.FileTypeFilter.Add(".opml");
            picker.FileTypeFilter.Add(".xml");
            var selected = await picker.PickSingleFileAsync();
            if (selected is null || lifetime.IsCancellationRequested || !CloseAddFeed())
            {
                return;
            }

            SetSubscriptionStatus("Importing OPML…");
            var result = await catalogEdits.ImportOpmlAsync(selected.Path, lifetime.Token);
            SetSubscriptionStatus($"Added {CountLabel(result.Added, "feed")}. {CountLabel(result.Existing, "feed")} already subscribed.");
            _ = LoadReaderAsync(refreshCatalog: true);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonOutcomeUnknownException or DaemonProtocolException or TimeoutException or JsonException)
        {
            SetSubscriptionStatus("Fyke couldn’t confirm the import. Check your subscriptions before retrying.");
            _ = LoadReaderAsync(refreshCatalog: true);
        }
        catch (Exception error) when (error is DaemonException or IOException or UnauthorizedAccessException or COMException)
        {
            if (IsAddFeedOpen)
            {
                AddFeedStatus.Text = "Fyke couldn’t open the file picker. Try again.";
            }
            else
            {
                SetSubscriptionStatus("Fyke couldn’t import the file. Choose a readable OPML document and try again.");
            }
        }
        finally
        {
            transferringOpml = false;
        }
    }

    private async Task ExportOpmlAsync()
    {
        if (!readerConnected || transferringOpml || lifetime.IsCancellationRequested)
        {
            return;
        }

        transferringOpml = true;
        try
        {
            var picker = new FileSavePicker(AppWindow.Id)
            {
                SuggestedFileName = "feeds",
                DefaultFileExtension = ".opml",
            };
            picker.FileTypeChoices.Add("OPML files", [".opml"]);
            var selected = await picker.PickSaveFileAsync();
            if (selected is null || lifetime.IsCancellationRequested)
            {
                return;
            }

            SetSubscriptionStatus("Exporting subscriptions…");
            var document = await catalogEdits.ExportOpmlAsync(lifetime.Token);
            await OpmlExportFile.SaveAsync(selected.Path, document, lifetime.Token);
            SetSubscriptionStatus("Subscriptions exported.");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException
            or IOException or UnauthorizedAccessException or COMException)
        {
            SetSubscriptionStatus("Fyke couldn’t export subscriptions. Try again or choose another location.");
        }
        finally
        {
            transferringOpml = false;
        }
    }
}
