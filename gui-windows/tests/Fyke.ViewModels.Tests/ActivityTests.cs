using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ActivityTests
{
    private static readonly DateTimeOffset Now = new(new DateTime(2026, 11, 20, 15, 0, 0, DateTimeKind.Local));

    private static long Ms(DateTimeOffset time) => time.ToUnixTimeMilliseconds();

    private static WriterJob Job(long id, string kind, string? status, DateTimeOffset created, DateTimeOffset? finished = null,
        string? error = null, long? routineId = null, string? writer = null) => new()
    {
        Id = id,
        Kind = kind,
        Status = status,
        CreatedAt = Ms(created),
        FinishedAt = finished is { } done ? Ms(done) : null,
        Error = error,
        Input = new WriterJobInput { RoutineId = routineId, Writer = writer },
    };

    private static readonly Routine Morning = new() { Id = 3, Name = "Morning databases", NextRunAt = Ms(Now.AddHours(2)) };

    [Fact]
    public async Task JobsAreReadAsTheDaemonWritesThem()
    {
        var activity = new ActivityJobs(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("jobs.list", method);
                Assert.Equal(50, parameters!.Value.GetProperty("limit").GetInt32());
                // jobs.list returns table rows: stage, status, input (from input_json) and times in ms.
                return JsonElement.Parse("""
                    {"items":[{"id":9,"stage":"routine","status":"failed","input":{"routine_id":3,"matches":[1,2]},
                      "error":"NoSuchView","created_at":1795154168543,"finished_at":1795154169543,"artifact_id":null}]}
                    """);
            },
        });

        var job = Assert.Single(await activity.ListAsync(CancellationToken.None));

        Assert.Equal("routine", job.Work);
        Assert.True(job.IsFailed);
        Assert.Equal(3, job.RoutineId);
        Assert.Equal("NoSuchView", job.Error);
    }

    [Fact]
    public void CancelSendsTheJob()
    {
        string? sent = null;
        var activity = new ActivityJobs(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                sent = $"{method} {parameters!.Value.GetProperty("id").GetInt64()}";
                return JsonElement.Parse("{}");
            },
        });

        _ = activity.CancelAsync(4, CancellationToken.None);

        Assert.Equal("jobs.cancel 4", sent);
        Assert.True(ActivityJobs.Concerns(new DaemonEvent(1, "job.changed", 4)));
        Assert.False(ActivityJobs.Concerns(new DaemonEvent(1, "entry.new", 4)));
    }

    [Fact]
    public void GroupsRunningFailedAndFinishedWork()
    {
        var jobs = new[]
        {
            Job(10, "brief", "running", Now.AddSeconds(-12), writer: "claude"),
            Job(9, "routine", "failed", Now.AddHours(-1), Now.AddHours(-1), "The view is gone.", routineId: 3),
            // A failed brief that a later brief replaced does not need you.
            Job(8, "answer", "done", Now.AddHours(-2), Now.AddHours(-2)),
            Job(7, "answer", "failed", Now.AddHours(-3), Now.AddHours(-3)),
            Job(6, "brief", "cancelled", Now.AddHours(-4), Now.AddHours(-4)),
            // Yesterday's work is not Earlier today, and a failure older than a day needs no one.
            Job(5, "brief", "failed", Now.AddDays(-2), Now.AddDays(-2)),
        };
        var state = new ActivityState(jobs, [], [Morning], Now.AddMinutes(-5));

        Assert.Equal([10L], state.Active.Select(job => job.Id));
        Assert.Equal([9L], state.NeedsYou(Now).Select(job => job.Id));
        Assert.Equal([8L, 7L, 6L], state.Earlier(Now).Select(job => job.Id));
        Assert.True(state.IsBusy);
        Assert.True(state.NeedsAttention(Now));
        Assert.Equal(9, state.FailedRun(3, Now)?.Id);
        Assert.Null(state.FailedRun(4, Now));

        Assert.Equal("Morning databases", state.Describe(jobs[1]));
        Assert.Equal("Writing a brief", state.Describe(jobs[0]));
        Assert.Equal("Morning databases did not finish", ActivityText.FailedTitle(state, jobs[1]));
        Assert.Equal("The view is gone. Your articles are untouched.", ActivityText.FailedDetail(jobs[1]));
        Assert.Equal("It stopped. Your articles are untouched.", ActivityText.FailedDetail(jobs[4]));
        Assert.Equal("Claude · 12 s", ActivityText.Running(jobs[0], Now));
        Assert.Equal("Writing a brief · cancelled", ActivityText.Done(state, jobs[4]));
        Assert.Equal("Answering a question", ActivityText.Done(state, jobs[2]));
        Assert.Equal("", ActivityText.DoneGlyph(jobs[2]));
        Assert.Equal("", ActivityText.DoneGlyph(jobs[4]));
        Assert.Equal("", ActivityText.DoneGlyph(jobs[3]));
    }

    [Fact]
    public void EarlierTodayKeepsSix()
    {
        var jobs = Enumerable.Range(1, 9).Select(id => Job(20 - id, "brief", "done", Now.AddMinutes(-id), Now.AddMinutes(-id))).ToArray();

        Assert.Equal(ActivityState.EarlierLimit, new ActivityState(jobs, [], [], null).Earlier(Now).Count);
    }

    [Fact]
    public void StatusSaysTheMostUrgentThingFirst()
    {
        var running = Job(10, "brief", "queued", Now);
        var other = Job(11, "answer", "running", Now);
        var failed = Job(9, "brief", "failed", Now.AddHours(-1), Now.AddHours(-1));
        var feed = new FailingFeed(2, "Systems", 40, new FeedHealth(3, "HTTP 503", null));

        Assert.Equal("Writing a brief…", ActivityText.Status(new([running], [feed], [], Now), Now));
        Assert.Equal("Answering a question… · 1 more", ActivityText.Status(new([other, running], [], [], Now), Now));
        Assert.Equal("1 thing needs you", ActivityText.Status(new([failed], [], [], Now), Now));
        Assert.Equal("2 things need you", ActivityText.Status(new([failed], [feed], [], Now), Now));
        Assert.Equal("Updated now", ActivityText.Status(new([], [], [], Now.AddSeconds(-20)), Now));
        Assert.Equal("Updated 5 minutes ago", ActivityText.Status(new([], [], [], Now.AddMinutes(-5)), Now));
        Assert.Equal("Updated 2 hours ago", ActivityText.Status(new([], [], [], Now.AddHours(-2)), Now));
        Assert.Equal("Updated yesterday", ActivityText.Status(new([], [], [], Now.AddDays(-1)), Now));
        Assert.Equal(string.Empty, ActivityText.Status(ActivityState.Empty, Now));
        Assert.False(ActivityState.Empty.NeedsAttention(Now));
    }

    [Fact]
    public void AWriterThatIsNotSignedInIsFixedInWriters()
    {
        var signIn = Job(1, "brief", "failed", Now, Now, "Claude Code is not signed in.");
        var other = Job(2, "brief", "failed", Now, Now, "The writer stopped.");
        var routine = Job(3, "routine", "failed", Now, Now, "Not signed in");

        Assert.Equal("Writers", ActivityText.FailedAction(signIn));
        Assert.Equal("Try again", ActivityText.FailedAction(other));
        Assert.Equal("Try again", ActivityText.FailedAction(routine));
    }

    [Fact]
    public void FeedHealthWords()
    {
        var failing = new FeedHealth(3, "HTTP 503", "https://example.net");
        var working = new FeedHealth(0, null, null);
        var one = new FailingFeed(2, "Systems", 40, failing);

        Assert.True(failing.IsFailing);
        Assert.False(working.IsFailing);
        Assert.False(new FeedHealth(2, null, null).IsFailing);
        Assert.Equal("Systems is not loading", ActivityText.FeedsTitle([one]));
        Assert.Equal("2 feeds are not loading", ActivityText.FeedsTitle([one, one with { Id = 3 }]));
        Assert.Equal("Systems is not loading", ActivityText.HealthTitle("Systems", failing));
        Assert.Equal("Systems", ActivityText.HealthTitle("Systems", working));
        Assert.Equal("It failed 3 times in a row. Its 40 articles are kept, and Fyke keeps trying on its own.",
            ActivityText.HealthDetail(failing, 40));
        Assert.Equal("Its last fetch worked. Its 1 article are here.", ActivityText.HealthDetail(working, 1));
        Assert.Equal("Try again now", ActivityText.HealthAction(failing));
        Assert.Equal("Refresh now", ActivityText.HealthAction(working));
    }

    [Fact]
    public void TheNextRoutineAndAFailedRunInTheList()
    {
        var paused = new Routine { Id = 4, Name = "Paused", Enabled = false, NextRunAt = Ms(Now.AddMinutes(10)) };
        var state = new ActivityState([], [], [paused, Morning], null);

        Assert.Same(Morning, state.NextRoutine);
        Assert.StartsWith("Next: Morning databases, ", ActivityText.Next(state), StringComparison.Ordinal);
        Assert.Null(ActivityText.Next(ActivityState.Empty));

        var failed = Job(9, "routine", "failed", Now, Now, "  The view is gone.  ", routineId: 3);
        var row = RoutineListItem.From(Morning, Now, failed);
        Assert.True(row.Failed);
        Assert.False(row.Working);
        Assert.Equal("The view is gone.", row.Status);
        Assert.Equal("Last run failed", RoutineListItem.From(Morning, Now, failed with { Error = null }).Status);
        Assert.False(RoutineListItem.From(Morning, Now).Failed);
    }
}
