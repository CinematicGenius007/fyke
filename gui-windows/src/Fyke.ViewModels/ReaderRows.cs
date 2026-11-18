using System.Collections.ObjectModel;

namespace Fyke.ViewModels;

/// <summary>Applies a fresh page while retaining unchanged rows and their native list containers.</summary>
public static class ReaderRows
{
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
