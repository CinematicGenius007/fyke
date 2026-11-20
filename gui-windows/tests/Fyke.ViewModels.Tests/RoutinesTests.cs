using System.Globalization;
using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class RoutinesTests
{
    // routines.list as the daemon writes it: schedule_json and actions_json decoded, enabled as 1 or 0.
    private const string RoutineReply = """
        {"id":3,"name":"Morning databases","view_id":7,"schedule":{"kind":"weekly","time":"07:30","days":[5,1]},
         "actions":[{"kind":"brief","recipe_id":1},{"kind":"tag","tag":"db"}],"enabled":1,"revision":2,
         "created_at":1,"last_run_at":null,"next_run_at":1795154168543}
        """;

    [Fact]
    public async Task ListReadsTheDaemonsRoutines()
    {
        var routines = new Routines(new FakeClient
        {
            OnCall = (method, _) =>
            {
                Assert.Equal("routines.list", method);
                return JsonElement.Parse($$"""{"items":[{{RoutineReply}}]}""");
            },
        });

        var routine = Assert.Single(await routines.ListAsync(CancellationToken.None));

        Assert.Equal(3, routine.Id);
        Assert.Equal(7, routine.ViewId);
        Assert.True(routine.Enabled);
        Assert.Equal("weekly", routine.Schedule.Kind);
        Assert.Equal([5, 1], routine.Schedule.Days);
        Assert.Equal(1, routine.Actions[0].RecipeId);
        Assert.Equal("db", routine.Actions[1].Tag);
        Assert.Equal(1795154168543, routine.NextRunAt);
    }

    [Fact]
    public async Task SaveSendsTheDefinitionAndRevision()
    {
        var sent = new List<JsonElement>();
        var routines = new Routines(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("routines.put", method);
                sent.Add(parameters!.Value);
                return JsonElement.Parse(RoutineReply);
            },
        });

        var draft = Routine.Draft(7, "Databases", 1);
        await routines.SaveAsync(draft, CancellationToken.None);
        await routines.SaveAsync(draft with { Id = 3, Revision = 2, Schedule = new RoutineSchedule { Kind = "manual", Time = "07:30" } },
            CancellationToken.None);

        Assert.Equal("Morning databases", sent[0].GetProperty("name").GetString());
        Assert.Equal(7, sent[0].GetProperty("view_id").GetInt64());
        Assert.False(sent[0].TryGetProperty("id", out _));
        Assert.Equal("weekdays", sent[0].GetProperty("schedule").GetProperty("kind").GetString());
        Assert.Equal("07:30", sent[0].GetProperty("schedule").GetProperty("time").GetString());
        Assert.Equal(1, sent[0].GetProperty("actions")[0].GetProperty("recipe_id").GetInt64());
        Assert.Equal("notify", sent[0].GetProperty("actions")[1].GetProperty("kind").GetString());
        Assert.Equal(2, sent[1].GetProperty("expected_revision").GetInt64());
        Assert.False(sent[1].GetProperty("schedule").TryGetProperty("time", out _));
    }

    [Fact]
    public async Task AConflictCarriesTheNewerRoutine()
    {
        var data = JsonElement.Parse($$"""{"kind":"revision_conflict","current":{{RoutineReply}}}""");
        var routines = new Routines(new FakeClient
        {
            OnCall = (_, _) => throw new DaemonRpcException("RevisionConflict", -32000, "revision_conflict", data),
        });

        var conflict = await Assert.ThrowsAsync<RoutineConflictException>(() =>
            routines.SaveAsync(new Routine { Id = 3, Name = "x", ViewId = 7, Revision = 1, Actions = [new()] }, CancellationToken.None));

        Assert.Equal(2, conflict.Current!.Revision);
    }

    [Fact]
    public async Task DryRunReadsDaysAndActions()
    {
        var routines = new Routines(new FakeClient
        {
            OnCall = (method, _) =>
            {
                Assert.Equal("routines.dry_run", method);
                return JsonElement.Parse("""
                    {"days":[{"from":1,"start":1,"until":2,"date":"2026-11-16","count":4,"actions":[]},
                             {"from":2,"start":2,"until":3,"date":"2026-11-17","count":0,"actions":[]}],
                     "actions":[{"kind":"brief","count":4,"summary":"Write a brief from 4 articles"}]}
                    """);
            },
        });

        var dry = await routines.DryRunAsync(3, CancellationToken.None);

        Assert.Equal([4L, 0L], dry.Days.Select(day => day.Count));
        Assert.Equal("Write a brief from 4 articles", dry.Actions[0].Summary);
    }

    [Fact]
    public void DraftsAndDefinitionsCompareAsEdited()
    {
        var draft = Routine.Draft(null, null, 2, "Is Postgres fast?", [new RoutineAction { Kind = "brief" }, new RoutineAction { Kind = "notify" }]);
        Assert.Equal("Is Postgres fast?", draft.Name);
        Assert.Equal(2, draft.Actions[0].RecipeId);
        Assert.False(draft.CanSave);
        Assert.True((draft with { ViewId = 1 }).CanSave);

        var saved = draft with { Id = 1, ViewId = 1, Revision = 4, NextRunAt = 5 };
        Assert.True(saved.SameDefinition(saved with { Revision = 5, NextRunAt = 9 }));
        Assert.False(saved.SameDefinition(saved with { Actions = [.. saved.Actions.Take(1)] }));
        Assert.True(new RoutineSchedule { Kind = "weekly", Days = [1, 5] }.Equals(new RoutineSchedule { Kind = "weekly", Days = [5, 1] }));
    }

    [Fact]
    public void WordsMatchMacOs()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        try
        {
            Assert.Equal("Every weekday", RoutineText.RepeatWords(new RoutineSchedule { Kind = "weekdays" }));
            Assert.Equal("Every Monday", RoutineText.RepeatWords(new RoutineSchedule { Kind = "weekly", Days = [1] }));
            Assert.Equal("On Mon, Fri", RoutineText.RepeatWords(new RoutineSchedule { Kind = "weekly", Days = [5, 1] }));
            Assert.Equal("Every Sunday", RoutineText.RepeatWords(new RoutineSchedule { Kind = "weekly", Days = [0] }));
            Assert.Equal("Only when I run it", RoutineText.RepeatWords(new RoutineSchedule()));
            Assert.Equal("Weekdays 07:30", RoutineText.Summary(new RoutineSchedule { Kind = "weekdays", Time = "07:30" }));
            Assert.Equal("Friday 18:00", RoutineText.Summary(new RoutineSchedule { Kind = "weekly", Time = "18:00", Days = [5] }));
            Assert.Equal("Manual", RoutineText.Summary(new RoutineSchedule { Time = "07:30" }));
            Assert.Equal(48, RoutineText.HalfHours.Count);
            Assert.Equal("23:30", RoutineText.HalfHours[^1]);

            var routine = new Routine
            {
                Name = "R", Schedule = new RoutineSchedule { Kind = "daily", Time = "09:00" },
                Actions = [new RoutineAction { Kind = "mark_read" }, new RoutineAction { Kind = "notify" }],
            };
            Assert.Equal("Daily 09:00 · mark read · notify", RoutineText.Line(routine));
            Assert.Equal("Not run yet", RoutineText.Status(routine, DateTimeOffset.Now));
            Assert.Equal("Paused", RoutineText.Status(routine with { Enabled = false }, DateTimeOffset.Now));
            Assert.Equal("R (not saved)", RoutineText.ListName(routine));
            Assert.Equal("Runs only when you press Run now.", RoutineText.Next(routine with { Schedule = new() }, null, false));
            Assert.Null(RoutineText.SidebarNext([routine]));
            Assert.NotNull(RoutineText.SidebarNext([routine with { NextRunAt = 1795154168543 }]));

            Assert.Equal("Nothing would have matched last week.", RoutineText.DryRunSummary([0, 0]));
            Assert.Equal("Would have caught 1 article on one day.", RoutineText.DryRunSummary([0, 1]));
            Assert.Equal("Would have caught 38 articles over 5 days, about 8 each.", RoutineText.DryRunSummary([10, 8, 0, 7, 6, 7, 0]));
            Assert.Equal([0.0, 0.12, 1.0], RoutineText.Bars([0, 1, 100]));
            Assert.Equal("M", RoutineText.DayLabel(new RoutineDryRun.DryRunDay { Date = "2026-11-16" }));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [Fact]
    public void EditingKeepsADraftFirstAndKnowsWhatChanged()
    {
        var first = new Routine { Id = 1, Name = "One", ViewId = 7, Revision = 1, Actions = [new()] };
        var second = first with { Id = 2, Name = "Two" };
        var editing = new RoutineEditing();

        editing.Load([first, second]);
        Assert.Equal(first, editing.Editing);
        Assert.False(editing.Dirty);

        editing.Edit(routine => routine with { Name = "Renamed" });
        Assert.True(editing.CanSave);

        // Its own switch flipped from the list: the edits stay, over the new revision.
        editing.Load([first with { Enabled = false, Revision = 2 }, second]);
        Assert.Equal("Renamed", editing.Editing!.Name);
        Assert.Equal(2, editing.Editing.Revision);
        Assert.False(editing.Editing.Enabled);

        // Changed elsewhere: the edits stay at the old revision, so saving conflicts.
        editing.Load([first with { Name = "Theirs", Revision = 3 }, second]);
        Assert.Equal(2, editing.Editing!.Revision);

        editing.Start(Routine.Draft(7, "Databases", 1));
        Assert.Equal([null, 1L, 2L], editing.Rows.Select(row => row.Id));
        Assert.True(editing.Dirty);
        editing.Select(second);
        Assert.Equal(second, editing.Editing);
        editing.Select(editing.Rows[0]);
        Assert.Null(editing.Editing!.Id);

        editing.Stored(editing.Editing with { Id = 9, Revision = 1 });
        Assert.Null(editing.Unsaved);
        Assert.Equal([9L, 1L, 2L], editing.Rows.Select(row => row.Id));
        Assert.False(editing.Dirty);

        editing.Removed(9);
        Assert.Equal(1, editing.Editing!.Id);
    }

    [Fact]
    public void ListRowsSayWhatTheRoutineDoes()
    {
        var row = RoutineListItem.From(new Routine
        {
            Id = 1, Name = "Morning", Enabled = false,
            Schedule = new RoutineSchedule { Kind = "weekdays", Time = "07:30" },
            Actions = [new RoutineAction { Kind = "brief" }, new RoutineAction { Kind = "notify" }],
        }, DateTimeOffset.Now);

        Assert.Equal("Weekdays 07:30 · brief · notify", row.Line);
        Assert.Equal("Paused", row.Status);
        Assert.Equal("Resume Morning", row.ToggleName);
        Assert.True(row.CanToggle);
    }
}
