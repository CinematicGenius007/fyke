using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class ViewUndoTests
{
    private const string ViewReply = """{"id":9,"name":"Databases","rule":{"words":"sql"},"revision":1,"sentence":"Matching sql"}""";

    private static SavedView Removed() =>
        new(4, "Databases", new ViewRule { Words = "sql" }, 3, "Matching sql", 0, 0);

    private static string Routine(long id, string viewId, int revision, bool enabled) => $$"""
        {"id":{{id}},"name":"R{{id}}","view_id":{{viewId}},"schedule":{"kind":"daily","time":"07:30"},
         "actions":[{"kind":"tag","tag":"db"}],"enabled":{{(enabled ? 1 : 0)}},"revision":{{revision}},"created_at":1}
        """;

    [Theory]
    [InlineData(0, "Deleted “News”.")]
    [InlineData(1, "Deleted “News” and turned off the routine that used it.")]
    [InlineData(3, "Deleted “News” and turned off the 3 routines that used it.")]
    public void TheNoticeSaysWhatHappenedToRoutines(int count, string expected) =>
        Assert.Equal(expected, ViewUndo.Removed("News", count));

    [Fact]
    public async Task UndoingACreateRemovesTheViewWithItsRoutinesDetached()
    {
        var calls = new List<string>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add($"{method} {parameters?.GetProperty("id")} {parameters?.GetProperty("detach")}");
                return JsonElement.Parse("""{"ok":true}""");
            },
        };

        await ViewUndo.UndoCreateAsync(new SavedViews(client), Removed(), CancellationToken.None);

        Assert.Equal(["views.remove 4 True"], calls);
    }

    [Fact]
    public async Task UndoingAnEditPutsTheOldNameAndRuleOverTheCurrentRevision()
    {
        JsonElement? put = null;
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                if (method == "views.get")
                {
                    return JsonElement.Parse("""{"id":4,"name":"Renamed","rule":{"words":"rust"},"revision":5,"sentence":"x"}""");
                }

                Assert.Equal("views.put", method);
                put = parameters!.Value.Clone();
                return JsonElement.Parse("""{"id":4,"name":"Databases","rule":{"words":"sql"},"revision":6,"sentence":"Matching sql"}""");
            },
        };

        var view = await ViewUndo.UndoEditAsync(new SavedViews(client), Removed(), CancellationToken.None);

        Assert.Equal(4, put!.Value.GetProperty("id").GetInt64());
        Assert.Equal(5, put.Value.GetProperty("expected_revision").GetInt64());
        Assert.Equal("Databases", put.Value.GetProperty("name").GetString());
        Assert.Equal("sql", put.Value.GetProperty("rule").GetProperty("words").GetString());
        Assert.Equal(6, view.Revision);
    }

    [Fact]
    public async Task UndoingARemoveMakesTheViewAgainInPlaceAndPointsItsRoutinesBack()
    {
        var calls = new List<string>();
        var puts = new List<JsonElement>();
        var client = new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add(method);
                switch (method)
                {
                    case "views.put":
                        Assert.False(parameters!.Value.TryGetProperty("id", out _));
                        return JsonElement.Parse(ViewReply);
                    case "views.move":
                        Assert.Equal(9, parameters!.Value.GetProperty("id").GetInt64());
                        Assert.Equal(2, parameters.Value.GetProperty("position").GetInt64());
                        return JsonElement.Parse("""{"ok":true}""");
                    case "routines.list":
                        // Routine 1 is still detached; 2 was pointed elsewhere since; 3 was removed.
                        return JsonElement.Parse($$"""{"items":[{{Routine(1, "null", 4, false)}},{{Routine(2, "5", 6, true)}}]}""");
                    case "routines.put":
                        puts.Add(parameters!.Value.Clone());
                        return JsonElement.Parse(Routine(1, "9", 5, true));
                    default:
                        throw new NotSupportedException(method);
                }
            },
        };
        var users = new[]
        {
            RoutineFrom(Routine(1, "4", 3, true)),
            RoutineFrom(Routine(2, "4", 3, true)),
            RoutineFrom(Routine(3, "4", 3, true)),
        };

        var view = await ViewUndo.UndoRemoveAsync(new SavedViews(client), new Routines(client), Removed(), 2, users, CancellationToken.None);

        Assert.Equal(9, view.Id);
        Assert.Equal(["views.put", "views.move", "routines.list", "routines.put"], calls);
        var put = Assert.Single(puts);
        Assert.Equal(1, put.GetProperty("id").GetInt64());
        Assert.Equal(9, put.GetProperty("view_id").GetInt64());
        Assert.Equal(4, put.GetProperty("expected_revision").GetInt64());
        Assert.True(put.GetProperty("enabled").GetBoolean());
    }

    [Fact]
    public async Task UndoingARemoveWithNoRoutinesDoesNotAskForThem()
    {
        var calls = new List<string>();
        var client = new FakeClient
        {
            OnCall = (method, _) =>
            {
                calls.Add(method);
                return JsonElement.Parse(method == "views.put" ? ViewReply : """{"ok":true}""");
            },
        };

        await ViewUndo.UndoRemoveAsync(new SavedViews(client), new Routines(client), Removed(), 0, [], CancellationToken.None);

        Assert.Equal(["views.put", "views.move"], calls);
    }

    private static Routine RoutineFrom(string json)
    {
        var client = new FakeClient { OnCall = (_, _) => JsonElement.Parse($$"""{"items":[{{json}}]}""") };
        return new Routines(client).ListAsync(CancellationToken.None).GetAwaiter().GetResult()[0];
    }
}
