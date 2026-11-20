using System.Globalization;
using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class RecipesTests
{
    // recipes.get as the daemon writes it: builtin is SQLite's 1 or 0.
    private const string RecipeReply = """
        {"id":1,"name":"Morning brief","builtin":1,"revision":3,"text":"Be brief.","note":"","created_at":1795154168543}
        """;

    [Fact]
    public async Task GetReadsTheRecipe()
    {
        var recipes = new Recipes(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("recipes.get", method);
                Assert.False(parameters!.Value.TryGetProperty("revision", out var revision) && revision.ValueKind != JsonValueKind.Null);
                return JsonElement.Parse(RecipeReply);
            },
        });

        var recipe = await recipes.GetAsync(1, CancellationToken.None);

        Assert.Equal("Morning brief", recipe.DisplayName);
        Assert.True(recipe.Builtin);
        Assert.Equal(3, recipe.Revision);
        Assert.Equal("Be brief.", recipe.Text);
    }

    [Fact]
    public async Task HistoryListsNewestFirstAndReadsOldText()
    {
        var recipes = new Recipes(new FakeClient
        {
            OnCall = (method, parameters) => method switch
            {
                "recipes.history" => JsonElement.Parse("""
                    {"items":[{"recipe_id":1,"revision":1,"text":"A","note":"","created_at":1},
                              {"recipe_id":1,"revision":2,"text":"B","note":"Undo reset","created_at":2}]}
                    """),
                _ => JsonElement.Parse(
                    $$"""{"id":1,"name":"R","builtin":0,"revision":{{parameters!.Value.GetProperty("revision").GetInt64()}},"text":"Old"}"""),
            },
        });

        var history = await recipes.HistoryAsync(1, CancellationToken.None);

        Assert.Equal([2L, 1L], history.Select(revision => revision.Revision));
        Assert.Equal("Undo reset", history[0].Note);
        Assert.Equal("Old", await recipes.RevisionTextAsync(1, 1, CancellationToken.None));
    }

    [Fact]
    public async Task SaveSendsTheExpectedRevision()
    {
        JsonElement? sent = null;
        var recipes = new Recipes(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("recipes.put", method);
                sent = parameters;
                return JsonElement.Parse(RecipeReply.Replace("\"revision\":3", "\"revision\":4", StringComparison.Ordinal));
            },
        });

        var saved = await recipes.SaveAsync(new Recipe { Id = 1, Name = "Morning brief", Revision = 3 }, "New", 3, CancellationToken.None);

        Assert.Equal(4, saved.Revision);
        Assert.Equal(1, sent!.Value.GetProperty("id").GetInt64());
        Assert.Equal("Morning brief", sent.Value.GetProperty("name").GetString());
        Assert.Equal("New", sent.Value.GetProperty("text").GetString());
        Assert.Equal(3, sent.Value.GetProperty("expected_revision").GetInt64());
    }

    [Fact]
    public async Task AConflictCarriesTheNewerRecipe()
    {
        var data = JsonElement.Parse($$"""{"kind":"revision_conflict","current":{{RecipeReply}}}""");
        var recipes = new Recipes(new FakeClient
        {
            OnCall = (_, _) => throw new DaemonRpcException("RevisionConflict", -32000, "revision_conflict", data),
        });

        var conflict = await Assert.ThrowsAsync<RecipeConflictException>(() =>
            recipes.ResetAsync(new Recipe { Id = 1, Revision = 2 }, CancellationToken.None));

        Assert.Equal(3, conflict.Current!.Revision);
        Assert.Equal("Be brief.", conflict.Current.Text);
    }

    [Fact]
    public async Task TryWritesOverAViewOrTheUnreadArticles()
    {
        var sent = new List<JsonElement>();
        var recipes = new Recipes(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("briefs.try", method);
                sent.Add(parameters!.Value);
                return JsonElement.Parse("""{"id":9,"stage":"brief","status":"queued"}""");
            },
        });

        Assert.Equal(9, (await recipes.TryAsync(1, "Draft", 4, CancellationToken.None)).Id);
        await recipes.TryAsync(1, "Draft", null, CancellationToken.None);

        Assert.Equal(4, sent[0].GetProperty("view_id").GetInt64());
        Assert.Equal("Draft", sent[0].GetProperty("text").GetString());
        Assert.Equal("unread", sent[1].GetProperty("rule").GetProperty("state").GetString());
    }

    [Fact]
    public void DraftKeepsEditsThroughAConflict()
    {
        var draft = new RecipeDraft();
        draft.Load(new Recipe { Id = 1, Revision = 3, Text = "Mine" });
        Assert.False(draft.IsDirty);

        draft.Text = "  ";
        Assert.True(draft.IsDirty);
        Assert.False(draft.CanSave);

        draft.Text = "Edited";
        Assert.False(draft.Refresh(new Recipe { Id = 1, Revision = 4, Text = "Theirs" }));
        draft.Conflicted(new Recipe { Id = 1, Revision = 4, Text = "Theirs" });
        Assert.Equal(4, draft.KeepMine());
        Assert.Equal("Edited", draft.Text);

        draft.TakeTheirs();
        Assert.Equal("Theirs", draft.Text);
        Assert.Null(draft.Conflict);
        Assert.True(draft.Refresh(new Recipe { Id = 1, Revision = 5, Text = "Newer" }));
        Assert.Equal("Newer", draft.Text);

        draft.Text = "x";
        draft.Revert();
        Assert.False(draft.IsDirty);
    }

    [Fact]
    public void TrialFollowsItsJob()
    {
        var trial = new RecipeTrial();
        Assert.False(trial.IsRunning);
        trial.Started(9);
        Assert.Null(trial.Finished([new WriterJob { Id = 9, Status = "running" }]));
        Assert.Null(trial.Finished([new WriterJob { Id = 8, Status = "done", ArtifactId = 1 }]));
        Assert.Equal(5, trial.Finished([new WriterJob { Id = 9, Status = "done", ArtifactId = 5 }]));

        trial.Written(new Brief { Id = 5 });
        Assert.False(trial.IsRunning);

        trial.Started(10);
        Assert.Null(trial.Result);
        Assert.Null(trial.Finished([new WriterJob { Id = 10, Status = "done" }]));
        Assert.Equal("The writer finished but returned nothing to show.", trial.Problem);
    }

    [Fact]
    public void WordsMatchMacOs()
    {
        var previous = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.InvariantCulture;
        try
        {
            var now = DateTimeOffset.FromUnixTimeMilliseconds(1795154168543).AddHours(2);
            var recipe = new Recipe { Id = 1, Revision = 3, CreatedAt = 1795154168543 };
            Assert.StartsWith("Tells Codex how to write the brief · revision 3 · edited ",
                RecipeText.Subtitle(recipe, "Codex", now), StringComparison.Ordinal);
            Assert.Equal("Tells the writer how to write the brief · revision 3",
                RecipeText.Subtitle(recipe with { CreatedAt = null }, null, now));
            Assert.Equal("Writes over the 12 articles of this brief with the text in Edit, saved or not.",
                RecipeText.TrialIntro(new Brief { InputCount = 12 }));
            Assert.Equal("This recipe changed elsewhere (revision 4).", RecipeText.ConflictTitle(new Recipe { Revision = 4 }));
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }
}
