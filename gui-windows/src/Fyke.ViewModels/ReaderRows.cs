using System.Collections.ObjectModel;

namespace Fyke.ViewModels;

/// <summary>Projects visible reader rows and applies collection changes without resetting the lists.</summary>
public static class ReaderRows
{
    /// <summary>Hides descendants in the depth-first catalog while retaining its aggregate counts.</summary>
    public static IReadOnlyList<ReaderDestination> VisibleDestinations(
        IReadOnlyList<ReaderDestination> catalog, IReadOnlySet<long> collapsedFolders)
    {
        var visible = new List<ReaderDestination>(catalog.Count);
        int? hiddenBelow = null;
        foreach (var row in catalog)
        {
            if (hiddenBelow is int depth && row.Depth > depth)
            {
                continue;
            }

            visible.Add(row);
            hiddenBelow = row.Scope == ReaderScope.Folder && collapsedFolders.Contains(row.Id) ? row.Depth : null;
        }

        return visible;
    }

    public static void Reconcile<T, TKey>(
        ObservableCollection<T> current, IReadOnlyList<T> updated, Func<T, TKey> key)
        where TKey : notnull
    {
        var comparer = EqualityComparer<TKey>.Default;
        var remaining = updated.Select(key).ToHashSet(comparer);
        for (var index = current.Count - 1; index >= 0; index--)
        {
            if (!remaining.Contains(key(current[index])))
            {
                current.RemoveAt(index);
            }
        }

        var existing = current.Select(key).ToHashSet(comparer);
        for (var index = 0; index < updated.Count; index++)
        {
            var item = updated[index];
            var id = key(item);
            if (!existing.Contains(id))
            {
                current.Insert(index, item);
                continue;
            }

            // Rows already matched before this index cannot contain this key.
            var previous = index;
            while (!comparer.Equals(key(current[previous]), id))
            {
                previous++;
            }

            if (previous != index)
            {
                current.Move(previous, index);
            }

            if (!EqualityComparer<T>.Default.Equals(current[index], item))
            {
                current[index] = item;
            }
        }
    }
}
