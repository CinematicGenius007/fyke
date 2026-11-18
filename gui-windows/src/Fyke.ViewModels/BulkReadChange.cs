namespace Fyke.ViewModels;

/// <summary>Tracks the confirmed read changes that a bulk action can undo.</summary>
public sealed class BulkReadChange(ReaderDestination destination)
{
    internal const int BatchSize = 1000;
    private readonly Queue<long[]> remaining = [];

    public string DestinationTitle => destination.Title;
    public int RemainingCount { get; private set; }
    public bool ReachedLimit { get; private set; }

    public bool Includes(long id) => remaining.Any(batch => Array.IndexOf(batch, id) >= 0);

    public async Task ApplyAsync(ReaderData reader, CancellationToken ct)
    {
        var scope = await reader.UnreadScopeAsync(destination, ct).ConfigureAwait(false);
        ReachedLimit = scope.ReachedLimit;
        foreach (var batch in scope.Ids.Chunk(BatchSize))
        {
            var changed = await reader.SetReadBatchAsync(batch, true, ct).ConfigureAwait(false);
            if (changed.Length > 0)
            {
                remaining.Enqueue(changed);
                RemainingCount += changed.Length;
            }
        }
    }

    public async Task UndoAsync(ReaderData reader, CancellationToken ct)
    {
        while (remaining.TryPeek(out var batch))
        {
            await reader.SetReadBatchAsync(batch, false, ct).ConfigureAwait(false);
            // A failed call leaves its batch in place for a later retry.
            remaining.Dequeue();
            RemainingCount -= batch.Length;
        }
    }
}
