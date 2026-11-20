using System.Collections.ObjectModel;
using System.Collections.Specialized;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ReaderRowsTests
{
    [Fact]
    public void CollapsingAnAncestorKeepsCountsAndRestoresTheNestedCollapse()
    {
        var all = new ReaderDestination(ReaderScope.All, 0, "All", 0, 8);
        var folder = new ReaderDestination(ReaderScope.Folder, 1, "News", 0, 7);
        var nested = new ReaderDestination(ReaderScope.Folder, 2, "Local", 1, 5);
        var nestedFeed = new ReaderDestination(ReaderScope.Feed, 1, "City", 2, 5);
        var sibling = new ReaderDestination(ReaderScope.Feed, 2, "National", 1, 2);
        var unfiled = new ReaderDestination(ReaderScope.Feed, 3, "Radio", 0, 1);
        ReaderDestination[] catalog = [all, folder, nested, nestedFeed, sibling, unfiled];
        var collapsed = new HashSet<long> { nested.Id, folder.Id };

        var closed = ReaderRows.VisibleDestinations(catalog, collapsed);

        Assert.Equal([all, folder, unfiled], closed);
        Assert.Same(folder, closed[1]);
        Assert.Equal(7, closed[1].Count);

        collapsed.Remove(folder.Id);

        Assert.Equal([all, folder, nested, sibling, unfiled], ReaderRows.VisibleDestinations(catalog, collapsed));
        collapsed.Clear();
        Assert.Equal(catalog, ReaderRows.VisibleDestinations(catalog, collapsed));
    }

    [Fact]
    public void AFeedKnowsTheFoldersThatHoldIt()
    {
        var folder = new ReaderDestination(ReaderScope.Folder, 1, "News", 0, 7);
        var nested = new ReaderDestination(ReaderScope.Folder, 2, "Local", 1, 5, ParentId: 1);
        var nestedFeed = new ReaderDestination(ReaderScope.Feed, 1, "City", 2, 5, ParentId: 2);
        var unfiled = new ReaderDestination(ReaderScope.Feed, 3, "Radio", 0, 1);
        ReaderDestination[] catalog = [folder, nested, nestedFeed, unfiled];

        Assert.Equal([2L, 1L], ReaderRows.AncestorFolders(catalog, nestedFeed));
        Assert.Equal([1L], ReaderRows.AncestorFolders(catalog, nested));
        Assert.Empty(ReaderRows.AncestorFolders(catalog, unfiled));
        // A folder that is gone from the catalog ends the walk.
        Assert.Empty(ReaderRows.AncestorFolders(catalog, unfiled with { ParentId = 9 }));
    }

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
