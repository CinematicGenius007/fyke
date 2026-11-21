namespace Fyke.ViewModels;

/// <summary>
/// The way back from creating, editing or removing a saved view, as on macOS
/// (gui/Sources/Reader/Features.swift). Each change happens at once and the notice offers
/// Undo, instead of asking first (docs/design-rules.md, "Undo instead of confirm").
/// </summary>
public static class ViewUndo
{
    /// <summary>Takes back a view just made. Routines cannot use it yet, but detaching keeps
    /// the removal from failing if one was pointed at it since.</summary>
    public static Task<ViewRemoval> UndoCreateAsync(SavedViews views, SavedView made, CancellationToken ct) =>
        views.RemoveAsync(made.Id, detach: true, ct);

    /// <summary>Puts back the name and rule a view had before an edit, over its current revision.</summary>
    public static async Task<SavedView> UndoEditAsync(SavedViews views, SavedView before, CancellationToken ct)
    {
        var now = await views.GetAsync(before.Id, ct).ConfigureAwait(false);
        return await views.SaveAsync(before.Name, before.Rule, now, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Makes a removed view again at its old place, and points the routines that used it back
    /// at it, as they were before removal turned them off. A routine changed or removed
    /// since is left as it is now.
    /// </summary>
    public static async Task<SavedView> UndoRemoveAsync(SavedViews views, Routines routines, SavedView removed, int position,
        IReadOnlyList<Routine> users, CancellationToken ct)
    {
        var made = await views.SaveAsync(removed.Name, removed.Rule, null, ct).ConfigureAwait(false);
        await views.MoveAsync(made.Id, position, ct).ConfigureAwait(false);
        if (users.Count == 0)
        {
            return made;
        }

        var current = (await routines.ListAsync(ct).ConfigureAwait(false))
            .Where(routine => routine.Id is not null)
            .ToDictionary(routine => routine.Id!.Value);
        foreach (var routine in users)
        {
            if (routine.Id is { } id && current.TryGetValue(id, out var now) && now.ViewId is null)
            {
                await routines.SaveAsync(routine with { ViewId = made.Id, Revision = now.Revision }, ct).ConfigureAwait(false);
            }
        }

        return made;
    }

    /// <summary>The notice after removing a view.</summary>
    public static string Removed(string name, int routinesTurnedOff) => routinesTurnedOff switch
    {
        0 => $"Deleted “{name}”.",
        1 => $"Deleted “{name}” and turned off the routine that used it.",
        _ => $"Deleted “{name}” and turned off the {routinesTurnedOff} routines that used it.",
    };
}
