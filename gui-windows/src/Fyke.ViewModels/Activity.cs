using System.Globalization;
using System.Text.Json.Nodes;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>A feed's last fetches, from <c>feeds.list</c>.</summary>
public sealed record FeedHealth(long ErrorCount, string? LastError, string? SiteUrl)
{
    /// <summary>It failed and says why, as macOS decides (gui/Sources/Reader/Features.swift, <c>isFailing</c>).</summary>
    public bool IsFailing => ErrorCount > 0 && LastError is not null;
}

/// <summary>A failing feed as Activity lists it.</summary>
public sealed record FailingFeed(long Id, string Name, long Entries, FeedHealth Health);

/// <summary>
/// Background work and what needs a person, as the macOS status line and Activity panel show them
/// (gui/Sources/Reader/Activity.swift and Library.swift).
/// </summary>
public sealed record ActivityState(IReadOnlyList<WriterJob> Jobs, IReadOnlyList<FailingFeed> FailingFeeds,
    IReadOnlyList<Routine> Routines, DateTimeOffset? UpdatedAt)
{
    public static readonly ActivityState Empty = new([], [], [], null);

    /// <summary>The most Earlier today shows.</summary>
    public const int EarlierLimit = 6;

    public IReadOnlyList<WriterJob> Active => [.. Jobs.Where(job => job.IsActive)];

    /// <summary>Failed jobs from the last day that nothing of the same kind has replaced since.</summary>
    public IReadOnlyList<WriterJob> NeedsYou(DateTimeOffset now)
    {
        var dayAgo = now.AddDays(-1).ToUnixTimeMilliseconds();
        return [.. Jobs.Where(job => job.IsFailed && (job.FinishedAt ?? job.CreatedAt ?? 0) > dayAgo
            && !Jobs.Any(later => later.Work == job.Work && later.RoutineId == job.RoutineId && later.Id > job.Id
                && (later.IsDone || later.IsActive)))];
    }

    /// <summary>Finished work since midnight that does not need a person, newest first.</summary>
    public IReadOnlyList<WriterJob> Earlier(DateTimeOffset now)
    {
        var midnight = new DateTimeOffset(now.LocalDateTime.Date).ToUnixTimeMilliseconds();
        var needsYou = NeedsYou(now).Select(job => job.Id).ToHashSet();
        return [.. Jobs.Where(job => !job.IsActive && (job.FinishedAt ?? job.CreatedAt ?? 0) >= midnight && !needsYou.Contains(job.Id))
            .Take(EarlierLimit)];
    }

    public bool IsBusy => Jobs.Any(job => job.IsActive);

    public bool NeedsAttention(DateTimeOffset now) => FailingFeeds.Count > 0 || NeedsYou(now).Count > 0;

    /// <summary>The routine that runs soonest.</summary>
    public Routine? NextRoutine => Routines.Where(routine => routine.Enabled && routine.NextRunAt is not null)
        .OrderBy(routine => routine.NextRunAt).FirstOrDefault();

    /// <summary>A routine's run by the routine's name, otherwise by its kind.</summary>
    public string Describe(WriterJob job) =>
        job.RoutineId is { } id && Routines.FirstOrDefault(routine => routine.Id == id) is { } routine
            ? routine.Name
            : ActivityText.Title(job.Work);

    /// <summary>The failed routine run the routine list warns about.</summary>
    public WriterJob? FailedRun(long routineId, DateTimeOffset now) =>
        NeedsYou(now).FirstOrDefault(job => job.RoutineId == routineId);
}

/// <summary>The words of the status line and Activity, matching macOS.</summary>
public static class ActivityText
{
    public const string NothingRunning = "Nothing running. Feeds refresh on their own.";
    public const string FeedsKept = "Their articles so far are kept. Fyke keeps trying on its own.";

    private static readonly string[] WritingKinds = ["brief", "digest", "synthesize", "try", "brief_try", "answer", "ask"];

    public static string Title(string work) => work switch
    {
        "brief" or "digest" or "synthesize" => "Writing a brief",
        "try" or "brief_try" => "Trying a recipe",
        "answer" or "ask" => "Answering a question",
        "routine" => "Running a routine",
        "refresh" => "Refreshing feeds",
        "" => "Job",
        _ => char.ToUpper(work[0], CultureInfo.CurrentCulture) + work[1..],
    };

    public static bool IsWriting(WriterJob job) => WritingKinds.Contains(job.Work);

    /// <summary>
    /// The status line, most urgent first: the running work, then what needs a person, then when
    /// the feeds were last read. The daemon reports no progress, so running work ends in an ellipsis.
    /// </summary>
    public static string Status(ActivityState state, DateTimeOffset now)
    {
        var active = state.Active;
        if (active.Count > 0)
        {
            return state.Describe(active[0]) + "…" + (active.Count > 1 ? $" · {active.Count - 1} more" : string.Empty);
        }

        var attention = state.NeedsYou(now).Count + (state.FailingFeeds.Count > 0 ? 1 : 0);
        if (attention > 0)
        {
            return attention == 1 ? "1 thing needs you" : $"{attention} things need you";
        }

        return state.UpdatedAt is { } updated ? "Updated " + Ago(updated, now) : string.Empty;
    }

    /// <summary>"now", "5 minutes ago", "yesterday": the named relative time macOS shows.</summary>
    public static string Ago(DateTimeOffset date, DateTimeOffset now)
    {
        var elapsed = now - date;
        if (elapsed.TotalMinutes < 1)
        {
            return "now";
        }

        if (elapsed.TotalHours < 1)
        {
            return BriefText.Count((long)elapsed.TotalMinutes, "minute") + " ago";
        }

        if (now.LocalDateTime.Date == date.LocalDateTime.Date)
        {
            return BriefText.Count((long)elapsed.TotalHours, "hour") + " ago";
        }

        var days = (long)(now.LocalDateTime.Date - date.LocalDateTime.Date).TotalDays;
        return days == 1 ? "yesterday" : BriefText.Count(days, "day") + " ago";
    }

    /// <summary>"Claude · 12 s" beside running work.</summary>
    public static string Running(WriterJob job, DateTimeOffset now) =>
        string.Join(" · ", new[]
        {
            string.IsNullOrEmpty(job.Writer) ? null : BriefText.JobWriter(job.Writer),
            BriefText.Time(job.CreatedAt) is { } started
                ? string.Create(CultureInfo.CurrentCulture, $"{Math.Max(0, (long)(now - started).TotalSeconds)} s")
                : null,
        }.Where(part => part is not null));

    public static string FailedTitle(ActivityState state, WriterJob job) => $"{state.Describe(job)} did not finish";

    public static string FailedDetail(WriterJob job) =>
        (string.IsNullOrWhiteSpace(job.Error) ? "It stopped." : job.Error.Trim()) + " Your articles are untouched.";

    /// <summary>A writer that is not signed in is fixed in the writer settings, anything else by trying again.</summary>
    public static bool IsWriterProblem(WriterJob job) =>
        IsWriting(job) && (job.Error ?? string.Empty).Contains("sign", StringComparison.OrdinalIgnoreCase);

    public static string FailedAction(WriterJob job) => IsWriterProblem(job) ? "Writers" : "Try again";

    public static string Done(ActivityState state, WriterJob job) =>
        state.Describe(job) + (job.Status == "cancelled" ? " · cancelled" : string.Empty);

    /// <summary>A check for done work, a dash for cancelled, an exclamation mark otherwise.</summary>
    public static string DoneGlyph(WriterJob job) => job.Status switch
    {
        "done" => "\uE73E",
        "cancelled" => "\uE738",
        _ => "\uE783",
    };

    public static string Finished(WriterJob job) =>
        BriefText.Time(job.FinishedAt ?? job.CreatedAt)?.ToString("t", CultureInfo.CurrentCulture) ?? string.Empty;

    public static string FeedsTitle(IReadOnlyList<FailingFeed> feeds) =>
        feeds.Count == 1 ? $"{feeds[0].Name} is not loading" : $"{feeds.Count} feeds are not loading";

    /// <summary>"Next: Morning databases, 07:30" at the foot of Activity.</summary>
    public static string? Next(ActivityState state) =>
        state.NextRoutine is { } routine && BriefText.Time(routine.NextRunAt) is { } at
            ? $"Next: {routine.Name}, {at.ToString("t", CultureInfo.CurrentCulture)}"
            : null;

    /// <summary>The feed health panel's heading.</summary>
    public static string HealthTitle(string name, FeedHealth health) => health.IsFailing ? $"{name} is not loading" : name;

    public static string HealthDetail(FeedHealth health, long entries) =>
        health.ErrorCount == 0
            ? $"Its last fetch worked. Its {BriefText.Count(entries, "article")} are here."
            : $"It failed {BriefText.Count(health.ErrorCount, "time")} in a row. Its {BriefText.Count(entries, "article")} are kept, and Fyke keeps trying on its own.";

    public static string HealthAction(FeedHealth health) => health.IsFailing ? "Try again now" : "Refresh now";
}

/// <summary>Reads the daemon's background work for Activity.</summary>
public sealed class ActivityJobs(IDaemonClient client)
{
    public async Task<IReadOnlyList<WriterJob>> ListAsync(CancellationToken ct) =>
        Wire.Read(await client.CallAsync("jobs.list", new JsonObject { ["limit"] = Briefs.ListLimit }, ct).ConfigureAwait(false),
            WireJson.Default.JobList, "jobs.list").Items ?? [];

    public Task CancelAsync(long id, CancellationToken ct) =>
        client.CallAsync("jobs.cancel", new JsonObject { ["id"] = id }, ct);

    /// <summary>Work started, changed or finished, or the events were missed.</summary>
    public static bool Concerns(DaemonEvent change) => change.IsGap || change.Type is "job.changed";
}
