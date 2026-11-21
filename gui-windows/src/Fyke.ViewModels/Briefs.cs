using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>A brief as <c>briefs.list</c> names it, before its text is read.</summary>
public sealed record BriefSummary
{
    public long Id { get; init; }
    public string? Kind { get; init; }
    public string? Title { get; init; }
    public long? CreatedAt { get; init; }
    public string? Writer { get; init; }
    public long? RecipeId { get; init; }
    public long? RecipeRevision { get; init; }
    public long InputCount { get; init; }
    public long OmittedCount { get; init; }
    public long? ViewId { get; init; }
    public string? ViewName { get; init; }

    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "Brief" : Title;
}

/// <summary>One claim of a section and the numbers of the sources it cites.</summary>
public sealed record BriefClaim(string? Text, int[]? Sources)
{
    public IReadOnlyList<int> Numbers => Sources ?? [];
}

public sealed record BriefSection(string? Heading, BriefClaim[]? Claims)
{
    public IReadOnlyList<BriefClaim> Items => Claims ?? [];
}

/// <summary>An article a brief cites, under the number its claims use.</summary>
public sealed record BriefCitation
{
    /// <summary>The article's id.</summary>
    public long Id { get; init; }
    public int Number { get; init; }
    public string? Title { get; init; }
    public string? FeedTitle { get; init; }
    public string? Snippet { get; init; }
    public string? Url { get; init; }
    public long? SortAt { get; init; }

    [JsonConverter(typeof(FlagConverter))]
    public bool Read { get; init; }

    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "Untitled" : Title;
}

/// <summary>A brief with its text, as <c>briefs.get</c> returns it.</summary>
public sealed record Brief
{
    public long Id { get; init; }
    public string? Kind { get; init; }
    public string? Title { get; init; }
    public long? CreatedAt { get; init; }
    public string? Writer { get; init; }
    public string? Producer { get; init; }
    public long? RecipeId { get; init; }
    public string? RecipeName { get; init; }
    public long? RecipeRevision { get; init; }
    public long InputCount { get; init; }
    public long OmittedCount { get; init; }
    public long? DurationMs { get; init; }
    public long? ViewId { get; init; }
    public string? ViewName { get; init; }
    public BriefSection[]? Sections { get; init; }
    public BriefCitation[]? Citations { get; init; }

    /// <summary>Older records name the citations "sources".</summary>
    public BriefCitation[]? Sources { get; init; }

    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? "Brief" : Title;

    public IReadOnlyList<BriefSection> Parts => Sections ?? [];

    /// <summary>The cited articles in number order, each numbered by its place when the record leaves it out.</summary>
    public IReadOnlyList<BriefCitation> Cited => [.. (Citations ?? Sources ?? [])
        .Select((citation, index) => citation.Number > 0 ? citation : citation with { Number = index + 1 })];

    public string? WrittenBy => Writer ?? Producer;
}

/// <summary>A job the daemon runs in the background, such as writing a brief.</summary>
public sealed record WriterJob
{
    public long Id { get; init; }
    public string? Kind { get; init; }
    public string? Stage { get; init; }
    public string? Status { get; init; }
    public WriterJobInput? Input { get; init; }
    public string? Error { get; init; }
    public long? CreatedAt { get; init; }
    public long? FinishedAt { get; init; }
    public long? ArtifactId { get; init; }

    /// <summary>The job's kind, where a trial of a recipe is "try": a brief that is not kept.</summary>
    public string Work => Input?.Preview == true ? "try" : Kind ?? Stage ?? "job";

    public bool IsActive => Status is null or "queued" or "running";

    public bool IsFailed => Status == "failed";

    public bool IsDone => Status == "done";

    public string? Writer => Input?.Writer;

    public long? RoutineId => Input?.RoutineId;
}

public sealed record WriterJobInput
{
    [JsonConverter(typeof(FlagConverter))]
    public bool Preview { get; init; }

    public string? Writer { get; init; }
    public long? RoutineId { get; init; }
}

public sealed record BriefRecipe(long Id, string? Name, long Revision);

/// <summary>What the Today row in the sidebar says without being opened.</summary>
public enum TodayBadge
{
    None,
    Writing,
    NewBrief,
}

/// <summary>A row of the brief list.</summary>
public sealed record BriefListItem(long Id, string Detail, string Title, string From, bool Newest)
{
    public string AccessibleName => $"{Title}, {Detail}, {From}";
}

/// <summary>What Today shows in place of a brief, if anything.</summary>
public enum TodayState
{
    Brief,
    Unavailable,
    Writing,
    Failed,
    Empty,
}

/// <summary>Everything Today needs to choose what it shows.</summary>
public sealed record TodaySnapshot(bool Available, IReadOnlyList<BriefSummary> Briefs, IReadOnlyList<WriterJob> Jobs,
    IReadOnlyList<BriefRecipe> Recipes)
{
    public static readonly TodaySnapshot Empty = new(true, [], [], []);

    private static readonly string[] BriefKinds = ["brief", "digest", "synthesize"];

    /// <summary>The brief being written now, if any. Answers and trials are written elsewhere.</summary>
    public WriterJob? Writing => Jobs.FirstOrDefault(job => job.IsActive && BriefKinds.Contains(job.Work));

    /// <summary>The last brief that failed in the past day, when nothing has been written since.</summary>
    public WriterJob? Failed(DateTimeOffset now)
    {
        var dayAgo = now.AddDays(-1).ToUnixTimeMilliseconds();
        return Jobs.FirstOrDefault(job => job.IsFailed && BriefKinds.Contains(job.Work)
            && (job.FinishedAt ?? job.CreatedAt ?? 0) > dayAgo
            && !Jobs.Any(later => later.Work == job.Work && later.RoutineId == job.RoutineId && later.Id > job.Id
                && (later.IsDone || later.IsActive)));
    }

    /// <summary>The chosen brief, or the newest when none is chosen or the chosen one is gone.</summary>
    public BriefSummary? Selected(long? id) => Briefs.FirstOrDefault(brief => brief.Id == id) ?? (Briefs.Count > 0 ? Briefs[0] : null);

    /// <summary>
    /// Writing, failed and empty are said in place of the brief. A brief written after the job
    /// started, or after it failed, is newer news, so it shows instead.
    /// </summary>
    public TodayState State(long? selectedId, DateTimeOffset now)
    {
        if (!Available)
        {
            return TodayState.Unavailable;
        }

        var selected = Selected(selectedId);
        if (Writing is { } job && (selected is null || (job.CreatedAt ?? 0) > (selected.CreatedAt ?? 0)))
        {
            return TodayState.Writing;
        }

        if (Failed(now) is { } failed && (failed.FinishedAt ?? 0) > (selected?.CreatedAt ?? 0))
        {
            return TodayState.Failed;
        }

        return selected is null ? TodayState.Empty : TodayState.Brief;
    }

    public string? RecipeName(long? id) => Recipes.FirstOrDefault(recipe => recipe.Id == id)?.Name;

    /// <summary>The recipe a new brief uses: the chosen brief's, or the first.</summary>
    public long? RecipeFor(long? selectedId) => Selected(selectedId)?.RecipeId ?? (Recipes.Count > 0 ? Recipes[0].Id : null);

    /// <summary>A spinner while a brief is written; a dot for a brief that has not been seen.</summary>
    public TodayBadge Badge(bool showingToday, long? seenId) =>
        Writing is not null ? TodayBadge.Writing
        : !showingToday && Briefs.Count > 0 && Briefs[0].Id != seenId ? TodayBadge.NewBrief
        : TodayBadge.None;

    /// <summary>The list rows, newest first; the newest title is drawn as unread.</summary>
    public IReadOnlyList<BriefListItem> Rows(Func<long, string?> viewNamed) =>
        [.. Briefs.Select((brief, index) => new BriefListItem(brief.Id, BriefText.RowDetail(brief, viewNamed),
            brief.DisplayTitle, BriefText.From(brief, 0), index == 0))];
}

/// <summary>The words Today and a brief use, the same as the macOS reader's.</summary>
public static class BriefText
{
    public static string Count(long number, string noun, string? plural = null) =>
        string.Format(CultureInfo.CurrentCulture, "{0:N0} {1}", number, number == 1 ? noun : plural ?? noun + "s");

    /// <summary>"Claude Code" for the writer the daemon calls "claude".</summary>
    public static string WriterName(string? writer) => writer?.ToLowerInvariant() switch
    {
        "claude" or "claude-code" or "claude_code" => "Claude Code",
        "codex" => "Codex",
        null => "a writer",
        _ => writer,
    };

    /// <summary>The writer as a job names it, capitalized: "Claude".</summary>
    public static string JobWriter(string? writer, string fallback = "The writer") =>
        string.IsNullOrEmpty(writer) ? fallback : CultureInfo.CurrentCulture.TextInfo.ToTitleCase(writer.ToLowerInvariant());

    public static DateTimeOffset? Time(long? milliseconds) =>
        milliseconds is { } value ? DateTimeOffset.FromUnixTimeMilliseconds(value).ToLocalTime() : null;

    /// <summary>"Friday, 20 Nov": the date the Today list starts with.</summary>
    public static string Today(DateTimeOffset now) => now.ToString("dddd, d MMM", CultureInfo.CurrentCulture);

    /// <summary>"November 20".</summary>
    public static string Day(DateTimeOffset date) => date.ToString("MMMM d", CultureInfo.CurrentCulture);

    /// <summary>The last week by weekday, older by date.</summary>
    public static string Relative(DateTimeOffset date, DateTimeOffset now) =>
        (now.LocalDateTime.Date - date.LocalDateTime.Date).TotalDays < 7
            ? date.ToString("dddd", CultureInfo.CurrentCulture)
            : date.ToString("MMM d", CultureInfo.CurrentCulture);

    /// <summary>What a brief read: its view's name, or all feeds.</summary>
    public static string Place(string? viewName, long? viewId, Func<long, string?> viewNamed) =>
        viewName ?? (viewId is { } id ? viewNamed(id) : null) ?? "All feeds";

    /// <summary>"Morning · 08:30" above a brief's title in the list.</summary>
    public static string RowDetail(BriefSummary brief, Func<long, string?> viewNamed) =>
        Join(Place(brief.ViewName, brief.ViewId, viewNamed), Time(brief.CreatedAt)?.ToString("HH:mm", CultureInfo.CurrentCulture));

    /// <summary>"Morning · November 20" above a brief's title in the reader.</summary>
    public static string Header(Brief brief, Func<long, string?> viewNamed) =>
        Join(Place(brief.ViewName, brief.ViewId, viewNamed), Time(brief.CreatedAt) is { } date ? Day(date) : null);

    public static string From(BriefSummary brief, int citations) =>
        "From " + Count(Math.Max(brief.InputCount, citations), "article");

    /// <summary>The line under the sources: what matched and was not read, or read and not cited.</summary>
    public static string? SourcesNote(Brief brief)
    {
        var cited = brief.Cited.Count;
        if (brief.OmittedCount > 0)
        {
            return Count(brief.OmittedCount, "more article") + " matched but did not fit, so the writer did not read them.";
        }

        return brief.InputCount > cited ? Count(brief.InputCount - cited, "more", "more") + " read but not cited" : null;
    }

    /// <summary>The claim and its sources as a screen reader says them.</summary>
    public static string Spoken(BriefClaim claim) =>
        (claim.Text ?? string.Empty) + (claim.Numbers.Count == 0 ? string.Empty
            : " Sources " + string.Join(", ", claim.Numbers) + ".");

    /// <summary>"Written by Claude Code with your Morning brief recipe · rev 3", split where the recipe is bold.</summary>
    public static (string Before, string Recipe, string After) MadeWith(Brief brief, string? recipeName) =>
        ($"Written by {WriterName(brief.WrittenBy)} with your ", recipeName ?? brief.RecipeName ?? "recipe",
            (brief.RecipeRevision is { } revision ? $" · rev {revision}" : string.Empty)
            + (brief.DurationMs is { } ms ? $" · {ms / 1000} s" : string.Empty));

    public static string CitationDetail(BriefCitation citation, DateTimeOffset now) =>
        Join(citation.Number.ToString(CultureInfo.CurrentCulture), citation.FeedTitle,
            Time(citation.SortAt) is { } date ? Relative(date, now) : null);

    public static string WritingDetail(WriterJob job, DateTimeOffset now) =>
        job.Writer is null ? "Started just now"
            : $"{JobWriter(job.Writer)} · started {(Time(job.CreatedAt) is { } date ? Relative(date, now) : "now")}";

    public static string WritingSeconds(WriterJob job, DateTimeOffset now) =>
        string.Format(CultureInfo.CurrentCulture,
            "{0} · {1} s so far, usually under a minute. Nothing changes in your articles while it writes; keep reading.",
            JobWriter(job.Writer), Math.Max(0, (long)(now - (Time(job.CreatedAt) ?? now)).TotalSeconds));

    public static string FailedDetail(WriterJob job) =>
        (string.IsNullOrWhiteSpace(job.Error) ? "It stopped before it finished." : job.Error.Trim())
        + " Nothing was lost: your articles and earlier briefs are as they were.";

    private static string Join(params string?[] parts) =>
        string.Join(" · ", parts.Where(part => !string.IsNullOrEmpty(part)));
}

/// <summary>Uses the daemon's brief and job operations, the same ones the macOS reader uses.</summary>
public sealed class Briefs(IDaemonClient client)
{
    public const int ListLimit = 50;

    /// <summary>
    /// Reads the briefs, jobs and recipes. A daemon that predates briefs answers unknown method,
    /// and Today then says so in place.
    /// </summary>
    public async Task<TodaySnapshot> LoadAsync(CancellationToken ct)
    {
        try
        {
            var limit = new JsonObject { ["limit"] = ListLimit };
            var briefs = await ReadAsync("briefs.list", limit, WireJson.Default.BriefList, ct).ConfigureAwait(false);
            var jobs = await ReadAsync("jobs.list", new JsonObject { ["limit"] = ListLimit }, WireJson.Default.JobList, ct)
                .ConfigureAwait(false);
            var recipes = await ReadAsync("recipes.list", null, WireJson.Default.RecipeList, ct).ConfigureAwait(false);
            return new TodaySnapshot(true,
                [.. (briefs.Items ?? []).Where(brief => brief.Kind is null or "digest")],
                jobs.Items ?? [], recipes.Items ?? []);
        }
        catch (DaemonRpcException error) when (error.IsUnknownMethod)
        {
            return TodaySnapshot.Empty with { Available = false };
        }
    }

    public Task<Brief> GetAsync(long id, CancellationToken ct) =>
        ReadAsync("briefs.get", new JsonObject { ["id"] = id }, WireJson.Default.Brief, ct);

    /// <summary>
    /// Writes a brief of a view, or of the unread articles when there is none. The daemon reads
    /// at most the newest 60 of them, and answers with the job it queued.
    /// </summary>
    public Task RunAsync(long? viewId, long? recipeId, CancellationToken ct) =>
        client.CallAsync("briefs.run", new JsonObject
        {
            ["view_id"] = viewId,
            ["rule"] = viewId is null ? new JsonObject { ["state"] = "unread" } : null,
            ["recipe_id"] = recipeId,
        }, ct);

    public Task CancelAsync(long jobId, CancellationToken ct) =>
        client.CallAsync("jobs.cancel", new JsonObject { ["id"] = jobId }, ct);

    /// <summary>The events after which Today reads again.</summary>
    public static bool Concerns(DaemonEvent change) =>
        change.IsGap || change.Type is "job.changed" or "artifact.new" or "recipe.changed";

    private async Task<T> ReadAsync<T>(string method, JsonObject? parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);

    internal sealed record BriefList(BriefSummary[]? Items);

    internal sealed record JobList(WriterJob[]? Items);

    internal sealed record RecipeList(BriefRecipe[]? Items);
}

/// <summary>Reads a flag the daemon writes as true or false, or as SQLite's 1 or 0.</summary>
internal sealed class FlagConverter : JsonConverter<bool>
{
    public override bool Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType switch
        {
            JsonTokenType.True => true,
            JsonTokenType.False or JsonTokenType.Null => false,
            JsonTokenType.Number => reader.GetInt64() != 0,
            _ => throw new JsonException("A flag must be true, false, 1 or 0."),
        };

    public override void Write(Utf8JsonWriter writer, bool value, JsonSerializerOptions options) => writer.WriteBooleanValue(value);
}
