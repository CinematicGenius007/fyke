using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class AskingTests
{
    // The job ask.run answers with: the row of the jobs table, as jobs.list lists it.
    private const string JobReply = """
        {"id":7,"lens_id":null,"runner_id":null,"stage":"answer","status":"queued",
         "input":{"view_id":null,"rule":{},"recipe_id":1,"question":"What changed?","writer":"claude","preview":false},
         "attempts":0,"error":null,"created_at":1795154168543,"finished_at":null,"artifact_id":null}
        """;

    private const string AnswerReply = """
        {"id":3,"kind":"answer","title":"What changed?","input_count":1,
         "sections":[{"heading":null,"claims":[{"text":"Storage got faster.","sources":[1,2]}]},
                     {"heading":"Also","claims":[{"text":"Nothing else.","sources":[]}]}],
         "citations":[{"id":11,"title":"Storage engine","url":"https://example.com/a","read":0,"number":1},
                      {"id":12,"title":null,"read":1,"number":2}]}
        """;

    [Fact]
    public async Task RunAsksOverEveryFeedWithAnEmptyRule()
    {
        JsonElement? sent = null;
        var asking = new Asking(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("ask.run", method);
                sent = parameters;
                return JsonElement.Parse(JobReply);
            },
        });

        var job = await asking.RunAsync("What changed?", null, CancellationToken.None);

        Assert.Equal(7, job.Id);
        Assert.Equal("answer", job.Work);
        Assert.True(job.IsActive);
        Assert.Equal("What changed?", sent!.Value.GetProperty("question").GetString());
        Assert.Equal(JsonValueKind.Object, sent.Value.GetProperty("rule").ValueKind);
        Assert.False(sent.Value.TryGetProperty("view_id", out var view) && view.ValueKind != JsonValueKind.Null);
    }

    [Fact]
    public async Task RunAsksOverAViewWithoutARule()
    {
        JsonElement? sent = null;
        var asking = new Asking(new FakeClient
        {
            OnCall = (_, parameters) =>
            {
                sent = parameters;
                return JsonElement.Parse(JobReply);
            },
        });

        await asking.RunAsync("What changed?", 4, CancellationToken.None);

        Assert.Equal(4, sent!.Value.GetProperty("view_id").GetInt64());
        Assert.False(sent.Value.TryGetProperty("rule", out var rule) && rule.ValueKind != JsonValueKind.Null);
    }

    [Fact]
    public async Task AnswerReadsSectionsAndCitations()
    {
        var asking = new Asking(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("answers.get", method);
                Assert.Equal(3, parameters!.Value.GetProperty("id").GetInt64());
                return JsonElement.Parse(AnswerReply);
            },
        });

        var answer = await asking.AnswerAsync(3, CancellationToken.None);

        Assert.Equal(2, answer.Parts.Count);
        Assert.Equal([1, 2], answer.Parts[0].Items[0].Numbers);
        Assert.True(answer.Cited[1].Read);
    }

    [Fact]
    public void FollowUpNamesTheQuestionBefore()
    {
        var session = new AskSession();
        session.Start(4);

        Assert.Null(session.Begin("   "));
        Assert.Equal("What changed?", session.Begin(" What changed? "));
        Assert.True(session.IsAsking);
        Assert.Null(session.Begin("Why?"));

        session.Answered(new Brief { Id = 3 });
        Assert.False(session.IsAsking);
        Assert.Equal("Earlier question: What changed?\nFollow-up: Why?", session.Begin("Why?"));
        Assert.Equal(["What changed?", "Why?"], session.Turns.Select(turn => turn.Question));
        Assert.Equal(4, session.ViewId);

        session.Start(null);
        Assert.Empty(session.Turns);
        Assert.Null(session.ViewId);
    }

    [Fact]
    public void FinishedReadsTheJobOfTheLatestTurn()
    {
        var session = new AskSession();
        session.Begin("What changed?");
        session.Queued(7);

        Assert.Null(session.Finished([new WriterJob { Id = 7, Status = "running" }]));
        Assert.Null(session.Finished([new WriterJob { Id = 8, Status = "done", ArtifactId = 9 }]));
        Assert.True(session.IsAsking);
        Assert.Equal(3, session.Finished([new WriterJob { Id = 7, Status = "done", ArtifactId = 3 }]));
    }

    [Theory]
    [InlineData("failed", "Codex is not signed in.", "Codex is not signed in.")]
    [InlineData("failed", null, "The writer stopped.")]
    [InlineData("cancelled", null, "You cancelled it.")]
    [InlineData("done", null, "The writer finished without an answer.")]
    public void FinishedSaysWhyThereIsNoAnswer(string status, string? error, string problem)
    {
        var session = new AskSession();
        session.Begin("What changed?");
        session.Queued(7);

        Assert.Null(session.Finished([new WriterJob { Id = 7, Status = status, Error = error }]));
        Assert.Equal(problem, session.Latest!.Problem);
        Assert.False(session.IsAsking);
        Assert.Equal("What changed?", session.Retract());
        Assert.Empty(session.Turns);
    }

    [Fact]
    public void RetractKeepsAnAnsweredTurn()
    {
        var session = new AskSession();
        session.Begin("What changed?");
        session.Answered(new Brief { Id = 3 });

        Assert.Null(session.Retract());
        Assert.Single(session.Turns);
    }

    [Fact]
    public async Task WordsMatchMacOs()
    {
        var answer = await new Asking(new FakeClient { OnCall = (_, _) => JsonElement.Parse(AnswerReply) })
            .AnswerAsync(3, CancellationToken.None);

        Assert.Equal("in all your feeds", AskText.Scope(null));
        Assert.Equal("in Engineering", AskText.Scope("Engineering"));
        Assert.Equal("in Engineering", AskText.Header("in Engineering", null));
        Assert.Equal("in Engineering · 2 articles read", AskText.Header("in Engineering", answer));
        Assert.Equal("Storage got faster. [1] [2]\n\nAlso\nNothing else.\n\n[1] Storage engine <https://example.com/a>\n[2] Untitled",
            AskText.Copy(answer));
    }
}
