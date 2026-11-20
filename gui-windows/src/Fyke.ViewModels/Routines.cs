using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>
/// When a routine runs, in the computer's local time: <c>manual</c>, <c>daily</c>, <c>weekdays</c> or
/// <c>weekly</c> with <see cref="Time"/> as HH:MM. Weekly days are Sunday 0 through Saturday 6.
/// </summary>
public sealed record RoutineSchedule
{
    public string Kind { get; init; } = "manual";
    public string? Time { get; init; }
    public IReadOnlyList<int>? Days { get; init; }

    [JsonIgnore]
    public bool IsManual => Kind == "manual";

    public bool Equals(RoutineSchedule? other) =>
        other is not null && Kind == other.Kind && Time == other.Time
        && (Days ?? []).Order().SequenceEqual((other.Days ?? []).Order());

    public override int GetHashCode() => HashCode.Combine(Kind, Time, (Days ?? []).Sum());

    public JsonObject ToWire()
    {
        var wire = new JsonObject { ["kind"] = Kind };
        if (!IsManual)
        {
            wire["time"] = Time ?? RoutineText.DefaultTime;
        }

        if (Kind == "weekly")
        {
            wire["days"] = new JsonArray([.. (Days ?? []).Order().Select(day => (JsonNode)day)]);
        }

        return wire;
    }
}

/// <summary>What a routine does with its matches: <c>brief</c>, <c>notify</c>, <c>mark_read</c>, <c>star</c> or <c>tag</c>.</summary>
public sealed record RoutineAction
{
    public string Kind { get; init; } = "notify";
    public long? RecipeId { get; init; }
    public string? Tag { get; init; }

    public JsonObject ToWire()
    {
        var wire = new JsonObject { ["kind"] = Kind };
        if (RecipeId is { } recipe)
        {
            wire["recipe_id"] = recipe;
        }

        if (Kind == "tag")
        {
            wire["tag"] = Tag?.Trim() ?? string.Empty;
        }

        return wire;
    }
}

/// <summary>A routine as <c>routines.list</c> returns it, or a draft not saved yet (no <see cref="Id"/>).</summary>
public sealed record Routine
{
    public long? Id { get; init; }
    public string Name { get; init; } = string.Empty;
    public long? ViewId { get; init; }
    public RoutineSchedule Schedule { get; init; } = new();
    public IReadOnlyList<RoutineAction> Actions { get; init; } = [];

    [JsonConverter(typeof(FlagConverter))]
    public bool Enabled { get; init; } = true;

    public long? Revision { get; init; }
    public long? NextRunAt { get; init; }
    public long? LastRunAt { get; init; }
    public long? LastMatches { get; init; }

    [JsonIgnore]
    public bool IsSaved => Id is not null;

    /// <summary>Whether the parts a person edits are the same, ignoring the daemon's bookkeeping.</summary>
    public bool SameDefinition(Routine? other) =>
        other is not null && Id == other.Id && Name == other.Name && ViewId == other.ViewId
        && Schedule.Equals(other.Schedule) && Enabled == other.Enabled && Actions.SequenceEqual(other.Actions);

    /// <summary>Saving needs a name, a view and at least one action.</summary>
    [JsonIgnore]
    public bool CanSave => Name.Trim().Length > 0 && ViewId is not null && Actions.Count > 0;

    /// <summary>
    /// A new routine starts from a view, so nothing begins at an empty form, as on macOS
    /// (gui/Sources/Reader/Features.swift, <c>newRoutine</c>): weekdays at 07:30, brief and notify.
    /// </summary>
    public static Routine Draft(long? viewId, string? viewName, long? recipeId, string? name = null,
        IReadOnlyList<RoutineAction>? actions = null) => new()
    {
        Name = name ?? (string.IsNullOrWhiteSpace(viewName) ? "New routine" : $"Morning {viewName.Trim().ToLower(CultureInfo.CurrentCulture)}"),
        ViewId = viewId,
        Schedule = new RoutineSchedule { Kind = "weekdays", Time = RoutineText.DefaultTime },
        Actions = [.. (actions ?? [new RoutineAction { Kind = "brief" }, new RoutineAction { Kind = "notify" }])
            .Select(action => action.Kind == "brief" && action.RecipeId is null ? action with { RecipeId = recipeId } : action)],
    };
}

/// <summary>What a routine would have caught over the last seven local days, without doing it.</summary>
public sealed record RoutineDryRun
{
    public IReadOnlyList<DryRunDay> Days { get; init; } = [];
    public IReadOnlyList<DryRunAction> Actions { get; init; } = [];

    public sealed record DryRunDay
    {
        /// <summary>The local date, as yyyy-MM-dd.</summary>
        public string? Date { get; init; }
        public long Count { get; init; }
    }

    public sealed record DryRunAction
    {
        public string? Kind { get; init; }
        public string? Summary { get; init; }
    }
}

/// <summary>The words of the routine pages, matching macOS (gui/Sources/Reader/Routines.swift).</summary>
public static class RoutineText
{
    public const string DefaultTime = "07:30";

    public const string Background = "Runs in the background while Fyke’s service runs, even with this window closed.";

    public const string LookIn = "for articles new since the last run";

    public const string SaveForDryRun = "Save to see what this routine would have caught last week.";

    private static readonly string[] DayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

    /// <summary>The choices of the When line's first menu, in macOS order.</summary>
    public static IReadOnlyList<RoutineSchedule> Repeats { get; } =
    [
        new() { Kind = "weekdays" },
        new() { Kind = "daily" },
        new() { Kind = "weekly", Days = [1] },
        new() { Kind = "weekly", Days = [5] },
        new() { Kind = "manual" },
    ];

    /// <summary>Every half hour of the day, for the time menu.</summary>
    public static IReadOnlyList<string> HalfHours { get; } =
        [.. Enumerable.Range(0, 48).Select(half => string.Create(CultureInfo.InvariantCulture, $"{half / 2:00}:{half % 2 * 30:00}"))];

    /// <summary>The kinds of action, as the Add action menu offers them.</summary>
    public static IReadOnlyList<string> ActionKinds { get; } = ["brief", "notify", "mark_read", "star", "tag"];

    /// <summary>"Every weekday", "Every Monday" or "On Mon, Fri".</summary>
    public static string RepeatWords(RoutineSchedule schedule) => schedule.Kind switch
    {
        "manual" => "Only when I run it",
        "daily" => "Every day",
        "weekdays" => "Every weekday",
        _ => (schedule.Days ?? []).Order().ToArray() switch
        {
            [] => "Every week",
            [var one] => $"Every {DayName(one)}",
            var many => "On " + string.Join(", ", many.Select(day => DayName(day)[..3])),
        },
    };

    /// <summary>One line, as the routine list shows it: "Weekdays 07:30".</summary>
    public static string Summary(RoutineSchedule schedule) => (schedule.Kind switch
    {
        "manual" => "Manual",
        "daily" => $"Daily {schedule.Time}",
        "weekdays" => $"Weekdays {schedule.Time}",
        _ => $"{RepeatWords(schedule).Replace("Every ", string.Empty, StringComparison.Ordinal)} {schedule.Time}",
    }).Trim();

    public static string ActionWord(string kind) => kind switch
    {
        "mark_read" => "mark read",
        _ => kind,
    };

    /// <summary>The Add action menu's words for a kind.</summary>
    public static string Title(string kind) => kind switch
    {
        "brief" => "Write a brief",
        "notify" => "Notify me",
        "mark_read" => "Mark them read",
        "star" => "Star them",
        "tag" => "Tag them",
        _ => kind,
    };

    /// <summary>Segoe Fluent glyphs for each kind, standing in for the macOS symbols.</summary>
    public static string Glyph(string kind) => kind switch
    {
        "brief" => "",
        "notify" => "",
        "mark_read" => "",
        "star" => "",
        "tag" => "",
        _ => "",
    };

    /// <summary>"Weekdays 07:30 · brief · notify".</summary>
    public static string Line(Routine routine) =>
        string.Join(" · ", new[] { Summary(routine.Schedule) }.Concat(routine.Actions.Select(action => ActionWord(action.Kind))));

    /// <summary>"Last run 2 hours ago", "Not run yet" or "Paused".</summary>
    public static string Status(Routine routine, DateTimeOffset now)
    {
        if (!routine.Enabled)
        {
            return "Paused";
        }

        if (BriefText.Time(routine.LastRunAt) is not { } last)
        {
            return "Not run yet";
        }

        var status = $"Last run {BriefText.Relative(last, now)}";
        return routine.LastMatches is { } matches ? $"{status} · {BriefText.Count(matches, "match", "matches")}" : status;
    }

    public static string ListName(Routine routine) => routine.IsSaved ? routine.Name : $"{routine.Name} (not saved)";

    public static string Empty(bool hasViews) => hasViews
        ? "A routine runs on a schedule over one of your views."
        : "A routine looks in a view. Save a search as a view first (Ctrl+F, then Ctrl+S).";

    public static string NoneTitle(bool hasViews) => hasViews ? "No routine chosen" : "Routines start from a view";

    public static string NoneDetail(bool hasViews) => hasViews
        ? "Pick one on the left, or make one from a view."
        : "Search for what you follow, keep it with Ctrl+S, and a routine can brief it every morning.";

    public const string Conflict = "This routine changed elsewhere. Save again to replace it with yours.";

    /// <summary>Why the daemon refused, in words.</summary>
    public static string Problem(Exception error) => error switch
    {
        DaemonRpcException { Message.Length: > 0 } refusal => refusal.Message.TrimEnd('.') + ".",
        _ => "Fyke couldn’t reach its service.",
    };

    /// <summary>The footer's words under the editor.</summary>
    public static string Next(Routine routine, Routine? saved, bool dirty)
    {
        if (routine.Schedule.IsManual)
        {
            return "Runs only when you press Run now.";
        }

        if (!dirty && BriefText.Time(saved?.NextRunAt) is { } next)
        {
            return $"Next run {next.ToString("dddd t", CultureInfo.CurrentCulture)}. Missed while asleep? It runs once on wake.";
        }

        return "Missed while asleep? It runs once on wake, never twice.";
    }

    /// <summary>"Next 07:30" in the sidebar: the soonest run of any routine that is on.</summary>
    public static string? SidebarNext(IReadOnlyList<Routine> routines) =>
        routines.Where(routine => routine.Enabled).Select(routine => BriefText.Time(routine.NextRunAt)).Where(time => time is not null)
            .Min() is { } soonest
            ? $"Next {soonest.ToString("t", CultureInfo.CurrentCulture)}"
            : null;

    /// <summary>"Would have caught 38 articles over 5 days, about 8 each."</summary>
    public static string DryRunSummary(IReadOnlyList<long> counts)
    {
        var total = counts.Sum();
        var days = counts.Count(count => count > 0);
        if (total <= 0)
        {
            return "Nothing would have matched last week.";
        }

        var noun = total == 1 ? "article" : "articles";
        if (days <= 1)
        {
            return string.Create(CultureInfo.CurrentCulture, $"Would have caught {total} {noun} on one day.");
        }

        var each = (long)Math.Round((double)total / days, MidpointRounding.AwayFromZero);
        return string.Create(CultureInfo.CurrentCulture, $"Would have caught {total} {noun} over {days} days, about {each} each.");
    }

    /// <summary>
    /// Bar heights from 0 to 1 against the busiest day. A day with any match is at least a sliver,
    /// so it never looks like an empty day.
    /// </summary>
    public static IReadOnlyList<double> Bars(IReadOnlyList<long> counts)
    {
        var top = counts.Count == 0 ? 0 : counts.Max();
        return top <= 0
            ? [.. counts.Select(_ => 0.0)]
            : [.. counts.Select(count => count == 0 ? 0 : Math.Max(0.12, (double)count / top))];
    }

    /// <summary>The day's initial, as the macOS bars label it.</summary>
    public static string DayLabel(RoutineDryRun.DryRunDay day) =>
        DateOnly.TryParseExact(day.Date, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date)
            ? CultureInfo.CurrentCulture.DateTimeFormat.GetAbbreviatedDayName(date.DayOfWeek)[..1]
            : day.Date is { Length: >= 2 } text ? text[^2..] : string.Empty;

    private static string DayName(int day) => DayNames[((day % 7) + 7) % 7];
}

/// <summary>One row of the routine list.</summary>
public sealed record RoutineListItem(Routine Routine, string Status)
{
    public string Name => RoutineText.ListName(Routine);
    public string Line => RoutineText.Line(Routine);
    public bool CanToggle => Routine.IsSaved;
    public bool Enabled => Routine.Enabled;

    /// <summary>A paused routine's name is muted, as on macOS.</summary>
    public double NameOpacity => Routine.Enabled ? 1 : 0.6;

    public string ToggleName => $"{(Routine.Enabled ? "Pause" : "Resume")} {Routine.Name}";
    public string AccessibleName => $"{Name}. {Line}. {Status}";

    public static RoutineListItem From(Routine routine, DateTimeOffset now) => new(routine, RoutineText.Status(routine, now));
}

/// <summary>
/// The routine page's state: the saved routines, a new one not saved yet (listed first), and the
/// copy the editor changes. Choosing another routine drops unsaved edits, as on macOS.
/// </summary>
public sealed class RoutineEditing
{
    public IReadOnlyList<Routine> Saved { get; private set; } = [];

    /// <summary>A new routine that has not been saved yet.</summary>
    public Routine? Unsaved { get; private set; }

    /// <summary>What the editor shows, edits included.</summary>
    public Routine? Editing { get; private set; }

    /// <summary>The saved routine the editor started from.</summary>
    public Routine? Original => Find(Editing?.Id);

    public bool Dirty => Editing is { } editing && (editing.Id is null || !editing.SameDefinition(Original));

    public bool CanSave => Dirty && Editing!.CanSave;

    public IReadOnlyList<Routine> Rows => Unsaved is null ? Saved : [Unsaved, .. Saved];

    public bool IsEditing(Routine row) => Editing is { } editing && (row.Id is null ? editing.Id is null : editing.Id == row.Id);

    /// <summary>
    /// Takes a fresh list. An edited routine keeps its edits; when only its switch or bookkeeping
    /// changed elsewhere, it takes the new revision so saving does not conflict with its own switch.
    /// </summary>
    public void Load(IReadOnlyList<Routine> saved)
    {
        var before = Original;
        Saved = saved;
        if (Editing is not { Id: { } id } editing)
        {
            Editing ??= First;
            return;
        }

        if (Find(id) is not { } fresh)
        {
            Editing = Unsaved ?? First;
        }
        else if (before is null || editing.SameDefinition(before))
        {
            Editing = fresh;
        }
        else if (fresh.SameDefinition(before with { Enabled = fresh.Enabled }))
        {
            Editing = editing with
            {
                Enabled = fresh.Enabled, Revision = fresh.Revision, NextRunAt = fresh.NextRunAt,
                LastRunAt = fresh.LastRunAt, LastMatches = fresh.LastMatches,
            };
        }
    }

    /// <summary>Starts a new routine and opens it.</summary>
    public void Start(Routine draft)
    {
        Unsaved = draft with { Id = null, Revision = null };
        Editing = Unsaved;
    }

    public void Select(Routine row) => Editing = row.Id is null ? Unsaved : Find(row.Id) ?? row;

    public void Edit(Func<Routine, Routine> change)
    {
        if (Editing is null)
        {
            return;
        }

        Editing = change(Editing);
        if (Editing.Id is null)
        {
            Unsaved = Editing;
        }
    }

    /// <summary>Takes the daemon's copy after a save; a new routine stops being a draft.</summary>
    public void Stored(Routine made)
    {
        if (Editing?.Id is null)
        {
            Unsaved = null;
        }

        Saved = Find(made.Id) is null ? [made, .. Saved] : [.. Saved.Select(routine => routine.Id == made.Id ? made : routine)];
        Editing = made;
    }

    /// <summary>After a conflict: keep the edits, over the newer revision, so the next save replaces it.</summary>
    public void Rebase(Routine? current)
    {
        if (current is not null && Editing is { } editing)
        {
            Editing = editing with { Revision = current.Revision };
            Saved = [.. Saved.Select(routine => routine.Id == current.Id ? current : routine)];
        }
    }

    public void Removed(long id)
    {
        Saved = [.. Saved.Where(routine => routine.Id != id)];
        if (Editing?.Id == id)
        {
            Editing = Unsaved ?? First;
        }
    }

    public void Clear()
    {
        Saved = [];
        Unsaved = null;
        Editing = null;
    }

    private Routine? First => Saved.Count > 0 ? Saved[0] : null;

    private Routine? Find(long? id) => id is null ? null : Saved.FirstOrDefault(routine => routine.Id == id);
}

/// <summary>The routine changed elsewhere since it was opened; <see cref="Current"/> is the newer one, when sent.</summary>
public sealed class RoutineConflictException(Routine? current) : Exception("The routine changed elsewhere.")
{
    public Routine? Current { get; } = current;
}

/// <summary>Lists, saves, dry-runs and runs routines with the daemon's routine operations, as macOS does.</summary>
public sealed class Routines(IDaemonClient client)
{
    public async Task<IReadOnlyList<Routine>> ListAsync(CancellationToken ct) =>
        (await ReadAsync("routines.list", null, WireJson.Default.RoutineList, ct).ConfigureAwait(false)).Items ?? [];

    /// <summary>Creates the routine, or updates it over the revision it was read at.</summary>
    /// <exception cref="RoutineConflictException">Another revision was saved since.</exception>
    public async Task<Routine> SaveAsync(Routine routine, CancellationToken ct)
    {
        var parameters = new JsonObject
        {
            ["name"] = routine.Name.Trim(),
            ["view_id"] = routine.ViewId ?? throw new ArgumentException("A routine needs a view.", nameof(routine)),
            ["schedule"] = routine.Schedule.ToWire(),
            ["actions"] = new JsonArray([.. routine.Actions.Select(action => (JsonNode)action.ToWire())]),
            ["enabled"] = routine.Enabled,
        };
        if (routine.Id is { } id)
        {
            parameters["id"] = id;
            parameters["expected_revision"] = routine.Revision;
        }

        try
        {
            return await ReadAsync("routines.put", parameters, WireJson.Default.Routine, ct).ConfigureAwait(false);
        }
        catch (DaemonRpcException error) when (error.Is("RevisionConflict"))
        {
            throw new RoutineConflictException(Current(error.ErrorData));
        }
    }

    /// <summary>Routine changes reload the list; a gap may have missed some.</summary>
    public static bool Concerns(DaemonEvent change) => change.IsGap || change.Type == "routine.changed";

    public Task RemoveAsync(long id, CancellationToken ct) =>
        client.CallAsync("routines.remove", new JsonObject { ["id"] = id }, ct);

    public Task<RoutineDryRun> DryRunAsync(long id, CancellationToken ct) =>
        ReadAsync("routines.dry_run", new JsonObject { ["id"] = id }, WireJson.Default.RoutineDryRun, ct);

    /// <summary>Captures the matches now and queues the routine's actions.</summary>
    public Task RunAsync(long id, CancellationToken ct) =>
        client.CallAsync("routines.run", new JsonObject { ["id"] = id }, ct);

    private static Routine? Current(JsonElement? data)
    {
        try
        {
            return data is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty("current", out var current)
                && current.ValueKind == JsonValueKind.Object
                ? current.Deserialize(WireJson.Default.Routine)
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private async Task<T> ReadAsync<T>(string method, JsonObject? parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);

    internal sealed record RoutineList(Routine[]? Items);
}
