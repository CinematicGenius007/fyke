using System.Globalization;
using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class BriefsTests
{
    // Replies the daemon gave in tools/e2e_features.py, trimmed to what Today reads.
    private const string ListReply = """
        {"items":[{"id":1,"title":"Morning brief","created_at":1795154168586,"writer":"claude","recipe_id":1,
          "recipe_revision":3,"input_count":2,"omitted_count":0,"view_id":1}]}
        """;

    private const string JobsReply = """
        {"items":[{"id":1,"lens_id":null,"runner_id":null,"stage":"brief","status":"done",
          "input":{"view_id":1,"rule":{"state":"unread"},"recipe_id":1,"recipe_revision":3,"question":null,
            "writer":"claude","timeout_seconds":180,"preview":false,"entry_ids":null},
          "attempts":1,"error":null,"created_at":1795154168543,"finished_at":1795154168586,"artifact_id":1}]}
        """;

    private const string RecipesReply = """
        {"items":[{"id":1,"name":"Morning brief","revision":3,"builtin":1,"text":"Write a brief.","note":"","created_at":1},
                  {"id":2,"name":"Custom","revision":1,"builtin":0,"text":"Be concise","note":"First","created_at":1}]}
        """;

    private const string GetReply = """
        {"id":1,"kind":"digest","producer":"claude","title":"Morning brief","created_at":1795154168586,"recipe_id":1,
         "recipe_revision":3,"view_id":1,"writer":"claude","input_count":4,"omitted_count":0,"preview":0,
         "body_blocks":[{"t":"p","c":[{"t":"text","v":"Storage news."}]}],
         "citations":[
           {"id":11,"title":"Storage engine 0","url":"https://example.com/a","sort_at":1795154167913,
            "feed_title":"Engineering","snippet":"Storage engine compiler news.","read":0,"number":1},
           {"id":12,"title":"Storage engine 1","url":"https://example.com/b","sort_at":1795154167913,
            "feed_title":"Engineering","snippet":"More news.","read":1,"number":2}],
         "sources":[{"id":11,"title":"Storage engine 0","read":0,"number":1}],
         "recipe_name":"Morning brief","view_name":"Engineering",
         "output":{"title":"Morning brief","sections":[]},
         "sections":[{"heading":"News","claims":[{"text":"Storage news.","sources":[2]},{"text":"Both.","sources":[1,2]}]}]}
        """;

    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeMilliseconds(1795154168586 + 60_000);

    [Fact]
    public async Task LoadReadsBriefsJobsAndRecipes()
    {
        var calls = new List<(string Method, JsonElement? Parameters)>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add((method, parameters));
                return JsonElement.Parse(method switch
                {
                    "briefs.list" => ListReply,
                    "jobs.list" => JobsReply,
                    "recipes.list" => RecipesReply,
                    _ => throw new InvalidOperationException(method),
                });
            },
        };

        var today = await new Briefs(client).LoadAsync(CancellationToken.None);

        Assert.True(today.Available);
        var brief = Assert.Single(today.Briefs);
        Assert.Equal(("Morning brief", 2L, 1L), (brief.DisplayTitle, brief.InputCount, brief.ViewId));
        var job = Assert.Single(today.Jobs);
        Assert.Equal(("brief", "claude", false, true), (job.Work, job.Writer, job.IsActive, job.IsDone));
        Assert.Equal("Custom", today.RecipeName(2));
        Assert.Equal(["briefs.list", "jobs.list", "recipes.list"], calls.Select(call => call.Method));
        Assert.Equal(Briefs.ListLimit, calls[0].Parameters!.Value.GetProperty("limit").GetInt32());
        Assert.Equal(TodayState.Brief, today.State(null, Now));
    }

    [Fact]
    public async Task AnOlderDaemonMakesTodayUnavailable()
    {
        var client = new FakeClient
        {
            OnCall = (_, _) => throw new DaemonRpcException("UnknownMethod", -32601, null, null),
        };

        var today = await new Briefs(client).LoadAsync(CancellationToken.None);

        Assert.False(today.Available);
        Assert.Equal(TodayState.Unavailable, today.State(null, Now));
    }

    [Fact]
    public async Task OtherFailuresReachTheCaller()
    {
        var client = new FakeClient
        {
            OnCall = (_, _) => throw new DaemonRpcException("Busy", -32000, "Busy", null),
        };

        await Assert.ThrowsAsync<DaemonRpcException>(() => new Briefs(client).LoadAsync(CancellationToken.None));
    }

    [Fact]
    public async Task GetReadsSectionsAndCitations()
    {
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("briefs.get", method);
                Assert.Equal(1, parameters!.Value.GetProperty("id").GetInt64());
                return JsonElement.Parse(GetReply);
            },
        };

        var brief = await new Briefs(client).GetAsync(1, CancellationToken.None);

        var section = Assert.Single(brief.Parts);
        Assert.Equal("News", section.Heading);
        Assert.Equal([[2], [1, 2]], section.Items.Select(claim => claim.Numbers.ToArray()));
        Assert.Equal([(11L, 1, false), (12L, 2, true)], brief.Cited.Select(c => (c.Id, c.Number, c.Read)));
        Assert.Equal("Storage news. Sources 2.", BriefText.Spoken(section.Items[0]));
        Assert.Equal("2 more read but not cited", BriefText.SourcesNote(brief));
        Assert.Equal(("Written by Claude Code with your ", "Custom", " · rev 3"), BriefText.MadeWith(brief, "Custom"));
        Assert.Equal("Morning brief", BriefText.MadeWith(brief, null).Recipe);
    }

    [Fact]
    public void CitationsWithoutNumbersAreNumberedInOrder()
    {
        var brief = new Brief { Sources = [new BriefCitation { Id = 5 }, new BriefCitation { Id = 6 }] };

        Assert.Equal([(5L, 1), (6L, 2)], brief.Cited.Select(c => (c.Id, c.Number)));
        Assert.Equal("Untitled", brief.Cited[0].DisplayTitle);
    }

    [Fact]
    public void OmittedArticlesAreNamedBeforeUncitedOnes()
    {
        var brief = new Brief { InputCount = 9, OmittedCount = 1, Citations = [new BriefCitation { Id = 1, Number = 1 }] };

        Assert.Equal("1 more article matched but did not fit, so the writer did not read them.", BriefText.SourcesNote(brief));
        Assert.Null(BriefText.SourcesNote(brief with { InputCount = 1, OmittedCount = 0 }));
    }

    [Fact]
    public async Task RunWritesTheUnreadArticlesWhenThereIsNoView()
    {
        var sent = new List<JsonElement>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("briefs.run", method);
                sent.Add(parameters!.Value);
                return JsonElement.Parse("""{"job_id":3}""");
            },
        };
        var briefs = new Briefs(client);

        await briefs.RunAsync(null, 2, CancellationToken.None);
        await briefs.RunAsync(7, null, CancellationToken.None);

        Assert.Equal("unread", sent[0].GetProperty("rule").GetProperty("state").GetString());
        Assert.Equal(JsonValueKind.Null, sent[0].Optional("view_id").ValueKind);
        Assert.Equal(2, sent[0].GetProperty("recipe_id").GetInt64());
        Assert.Equal(7, sent[1].GetProperty("view_id").GetInt64());
        Assert.Equal(JsonValueKind.Null, sent[1].Optional("rule").ValueKind);
    }

    [Fact]
    public void AWritingJobShowsUntilANewerBriefArrives()
    {
        var older = new BriefSummary { Id = 1, CreatedAt = 1_000 };
        var writing = new WriterJob { Id = 2, Stage = "brief", Status = "running", CreatedAt = 2_000 };
        var today = TodaySnapshot.Empty with { Briefs = [older], Jobs = [writing] };

        Assert.Same(writing, today.Writing);
        Assert.Equal(TodayState.Writing, today.State(null, Now));
        Assert.Equal(TodayState.Brief, (today with { Briefs = [new BriefSummary { Id = 3, CreatedAt = 3_000 }] }).State(null, Now));
    }

    [Fact]
    public void AnswersAndTrialsAreNotBriefsBeingWritten()
    {
        var trial = new WriterJob { Id = 1, Stage = "brief", Status = "queued", Input = new WriterJobInput { Preview = true } };
        var answer = new WriterJob { Id = 2, Stage = "answer", Status = "running" };
        var today = TodaySnapshot.Empty with { Jobs = [trial, answer] };

        Assert.Equal("try", trial.Work);
        Assert.Null(today.Writing);
        Assert.Equal(TodayState.Empty, today.State(null, Now));
    }

    [Fact]
    public void AFailureShowsUntilSomethingReplacesItOrADayPasses()
    {
        var finished = Now.AddHours(-1).ToUnixTimeMilliseconds();
        var failed = new WriterJob { Id = 4, Stage = "brief", Status = "failed", Error = "Timed out.", FinishedAt = finished };
        var today = TodaySnapshot.Empty with { Jobs = [failed], Briefs = [new BriefSummary { Id = 1, CreatedAt = finished - 5 }] };

        Assert.Equal(TodayState.Failed, today.State(null, Now));
        Assert.Equal("Timed out. Nothing was lost: your articles and earlier briefs are as they were.", BriefText.FailedDetail(failed));
        Assert.Equal(TodayState.Brief, today.State(null, Now.AddDays(2)));
        var replaced = today with { Jobs = [new WriterJob { Id = 5, Stage = "brief", Status = "done" }, failed] };
        Assert.Equal(TodayState.Brief, replaced.State(null, Now));
    }

    [Fact]
    public void TheChosenBriefFallsBackToTheNewest()
    {
        var today = TodaySnapshot.Empty with { Briefs = [new BriefSummary { Id = 9 }, new BriefSummary { Id = 4 }] };

        Assert.Equal(4, today.Selected(4)?.Id);
        Assert.Equal(9, today.Selected(77)?.Id);
        Assert.Equal(9, today.Selected(null)?.Id);
    }

    [Fact]
    public void TheSidebarSaysWhenABriefIsWrittenOrNew()
    {
        var today = TodaySnapshot.Empty with { Briefs = [new BriefSummary { Id = 9 }, new BriefSummary { Id = 4 }] };

        Assert.Equal(TodayBadge.NewBrief, today.Badge(showingToday: false, seenId: 4));
        Assert.Equal(TodayBadge.None, today.Badge(showingToday: false, seenId: 9));
        Assert.Equal(TodayBadge.None, today.Badge(showingToday: true, seenId: null));
        var writing = today with { Jobs = [new WriterJob { Id = 1, Stage = "digest", Status = "queued" }] };
        Assert.Equal(TodayBadge.Writing, writing.Badge(showingToday: true, seenId: 9));
        var row = new ReaderDestination(ReaderScope.Today, 0, "Today", 0, 0, Badge: TodayBadge.NewBrief);
        Assert.Equal("Today, new brief", row.AccessibleName);
    }

    [Fact]
    public void ListRowsMarkTheNewestAndUseTheRecipeOfTheChosenBrief()
    {
        var today = TodaySnapshot.Empty with
        {
            Briefs = [new BriefSummary { Id = 9, Title = "Evening", InputCount = 3 }, new BriefSummary { Id = 4, RecipeId = 2 }],
            Recipes = [new BriefRecipe(1, "Morning brief", 3), new BriefRecipe(2, "Custom", 1)],
        };

        var rows = today.Rows(_ => null);

        Assert.Equal([(9L, "Evening", true), (4L, "Brief", false)], rows.Select(row => (row.Id, row.Title, row.Newest)));
        Assert.Equal("From 3 articles", rows[0].From);
        Assert.Equal(2, today.RecipeFor(4));
        Assert.Equal(1, today.RecipeFor(9));
        Assert.Null(TodaySnapshot.Empty.RecipeFor(null));
    }

    [Fact]
    public void WordsMatchTheMacReader()
    {
        var culture = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
        try
        {
            Assert.Equal("Claude Code", BriefText.WriterName("claude"));
            Assert.Equal("Codex", BriefText.WriterName("codex"));
            Assert.Equal("a writer", BriefText.WriterName(null));
            Assert.Equal("Claude", BriefText.JobWriter("claude"));
            Assert.Equal("From 1 article", BriefText.From(new BriefSummary { InputCount = 1 }, 0));
            Assert.Equal("From 3 articles", BriefText.From(new BriefSummary { InputCount = 1 }, 3));
            var brief = new BriefSummary { ViewId = 7, CreatedAt = 0 };
            Assert.StartsWith("Morning · ", BriefText.RowDetail(brief, id => id == 7 ? "Morning" : null), StringComparison.Ordinal);
            Assert.StartsWith("All feeds", BriefText.RowDetail(brief with { ViewId = null }, _ => null), StringComparison.Ordinal);
            var job = new WriterJob { CreatedAt = Now.AddSeconds(-12).ToUnixTimeMilliseconds() };
            Assert.Equal("Started just now", BriefText.WritingDetail(job, Now));
            Assert.StartsWith("The writer · 12 s so far", BriefText.WritingSeconds(job, Now), StringComparison.Ordinal);
            var twoDaysAgo = Now.AddDays(-2).ToLocalTime();
            Assert.Equal(twoDaysAgo.ToString("dddd", CultureInfo.CurrentCulture), BriefText.Relative(twoDaysAgo, Now));
            var weeksAgo = Now.AddDays(-20).ToLocalTime();
            Assert.Equal(weeksAgo.ToString("MMM d", CultureInfo.CurrentCulture), BriefText.Relative(weeksAgo, Now));
        }
        finally
        {
            CultureInfo.CurrentCulture = culture;
        }
    }
}
