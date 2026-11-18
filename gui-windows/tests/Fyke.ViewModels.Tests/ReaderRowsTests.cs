using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderRowsTests
{
    [Fact]
    public void InsertingAHeadlineKeepsExistingRowsAndAvoidsReset()
    {
        var open = new TimelineArticle(2, "Open article", "News", false);
        var older = new TimelineArticle(1, "Older article", "News", true);
        var arrivals = new TimelineArticle(3, "New article", "News", false);
        var rows = new ObservableCollection<TimelineArticle> { open, older };
        var changes = Record(rows);

        ReaderRows.Reconcile(rows, [arrivals, open with { }, older with { }], row => row.Id);

        Assert.Equal(NotifyCollectionChangedAction.Add, Assert.Single(changes));
        Assert.Same(open, rows[1]);
        Assert.Same(older, rows[2]);
    }

    [Fact]
    public void ReconciliationRemovesMissingRowsAndUpdatesChangedState()
    {
        var first = new TimelineArticle(1, "First", "News", false);
        var second = new TimelineArticle(2, "Second", "News", false);
        var removed = new TimelineArticle(3, "Removed", null, false);
        var updated = second with { Read = true };
        var rows = new ObservableCollection<TimelineArticle> { first, second, removed };
        var changes = Record(rows);

        ReaderRows.Reconcile(rows, [updated, first with { }], row => row.Id);

        Assert.Equal([NotifyCollectionChangedAction.Remove, NotifyCollectionChangedAction.Move,
            NotifyCollectionChangedAction.Replace], changes);
        Assert.Same(updated, rows[0]);
        Assert.Same(first, rows[1]);
    }

    private static List<NotifyCollectionChangedAction> Record(ObservableCollection<TimelineArticle> rows)
    {
        var changes = new List<NotifyCollectionChangedAction>();
        rows.CollectionChanged += (_, change) => changes.Add(change.Action);
        return changes;
    }
}
