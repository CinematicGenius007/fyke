using System.Text;
using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class OpmlTransferTests
{
    private const string Document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><head><title>Écouter</title></head></opml>";

    [Fact]
    public async Task ImportsTheSelectedPathWithDaemonDefaultsAndReturnsCounts()
    {
        var path = Path.Combine(Path.GetTempPath(), "Mes abonnements.opml");
        var edits = new CatalogEdits(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("opml.import", method);
                var fields = JsonSerializer.SerializeToElement(parameters).EnumerateObject().ToArray();
                Assert.Single(fields);
                Assert.Equal(path, fields[0].Value.GetString());
                return JsonSerializer.SerializeToElement(new { added = 2, existing = 1 });
            },
        });

        Assert.Equal(new OpmlImportResult(2, 1), await edits.ImportOpmlAsync(path, CancellationToken.None));
    }

    [Fact]
    public async Task ExportsTheDocumentUnchangedAndRefusesAnEmptyReply()
    {
        var document = Document;
        var edits = new CatalogEdits(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("opml.export", method);
                Assert.Null(parameters);
                return JsonSerializer.SerializeToElement(new { opml = document });
            },
        });

        Assert.Equal(Document, await edits.ExportOpmlAsync(CancellationToken.None));
        document = string.Empty;
        await Assert.ThrowsAsync<DaemonProtocolException>(() => edits.ExportOpmlAsync(CancellationToken.None));
    }

    [Fact]
    public async Task ReplacesAnExistingFileWithUtf8OnlyAfterACompleteWrite()
    {
        var directory = Directory.CreateTempSubdirectory();
        try
        {
            var path = Path.Combine(directory.FullName, "Mes abonnements.opml");
            await File.WriteAllTextAsync(path, "Previous export");

            await Assert.ThrowsAnyAsync<OperationCanceledException>(
                () => OpmlExportFile.SaveAsync(path, Document, new CancellationToken(canceled: true)));
            Assert.Equal("Previous export", await File.ReadAllTextAsync(path));

            await OpmlExportFile.SaveAsync(path, Document, CancellationToken.None);
            Assert.Equal(Encoding.UTF8.GetBytes(Document), await File.ReadAllBytesAsync(path));
            Assert.Equal([path], Directory.GetFileSystemEntries(directory.FullName));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task RemovesTheTemporaryFileWhenReplacementFails()
    {
        var directory = Directory.CreateTempSubdirectory();
        try
        {
            var destination = directory.CreateSubdirectory("feeds.opml").FullName;
            var error = await Record.ExceptionAsync(() => OpmlExportFile.SaveAsync(destination, Document, CancellationToken.None));

            Assert.True(error is IOException or UnauthorizedAccessException, error?.ToString());
            Assert.Equal([destination], Directory.GetFileSystemEntries(directory.FullName));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }
}
