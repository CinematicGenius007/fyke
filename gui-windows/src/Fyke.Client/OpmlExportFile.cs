namespace Fyke.Client;

public static class OpmlExportFile
{
    /// <summary>Writes UTF-8 beside the destination so a failed export leaves an existing file intact.</summary>
    public static async Task SaveAsync(string path, string document, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var directory = Path.GetDirectoryName(path);
        if (!Path.IsPathFullyQualified(path) || directory is null)
        {
            throw new ArgumentException("Select an absolute path for the export.", nameof(path));
        }

        var temporaryPath = Path.Combine(directory, $".fyke-{Guid.NewGuid():N}.tmp");
        var created = false;
        try
        {
            await using (var file = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                bufferSize: 4096, FileOptions.Asynchronous))
            {
                created = true;
                await using var writer = new StreamWriter(file, leaveOpen: true);
                await writer.WriteAsync(document.AsMemory(), ct).ConfigureAwait(false);
                await writer.FlushAsync(ct).ConfigureAwait(false);
            }

            ct.ThrowIfCancellationRequested();
            File.Move(temporaryPath, path, overwrite: true);
            created = false;
        }
        finally
        {
            if (created)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    // Report the export failure even when cleanup is denied.
                }
            }
        }
    }
}
