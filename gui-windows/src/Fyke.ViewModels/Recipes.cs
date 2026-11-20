using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>A recipe at one revision: the Markdown that tells the writer how to write a brief.</summary>
public sealed record Recipe
{
    public long Id { get; init; }
    public string? Name { get; init; }
    public string Text { get; init; } = string.Empty;
    public long Revision { get; init; } = 1;

    /// <summary>Whether Fyke shipped it, so it can be reset to the built-in text.</summary>
    [JsonConverter(typeof(FlagConverter))]
    public bool Builtin { get; init; }

    public string? Note { get; init; }
    public long? CreatedAt { get; init; }

    [JsonIgnore]
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "Recipe" : Name.Trim();
}

/// <summary>One saved revision of a recipe, as History lists it.</summary>
public sealed record RecipeRevision
{
    public long Revision { get; init; }
    public string? Text { get; init; }
    public string? Note { get; init; }
    public long? CreatedAt { get; init; }
}

/// <summary>The recipe changed elsewhere since it was opened; <see cref="Current"/> is the newer one, when sent.</summary>
public sealed class RecipeConflictException(Recipe? current) : Exception("The recipe changed elsewhere.")
{
    public Recipe? Current { get; } = current;
}

/// <summary>
/// The text being edited against the revision it was opened at, as on macOS
/// (gui/Sources/Reader/RecipeView.swift). Saving makes a new revision; a conflict keeps the edits.
/// </summary>
public sealed class RecipeDraft
{
    public Recipe? Recipe { get; private set; }
    public string Text { get; set; } = string.Empty;

    /// <summary>A newer revision saved elsewhere while this one was edited.</summary>
    public Recipe? Conflict { get; private set; }

    public bool IsDirty => Recipe is { } recipe && recipe.Text != Text;

    public bool CanSave => IsDirty && Text.Trim().Length > 0;

    /// <summary>Takes a recipe as read or saved, and its text.</summary>
    public void Load(Recipe recipe)
    {
        Recipe = recipe;
        Text = recipe.Text;
        Conflict = null;
    }

    /// <summary>Another client saved: the new text is taken unless this one has edits.</summary>
    public bool Refresh(Recipe fresh)
    {
        if (Recipe is not { } recipe || fresh.Id != recipe.Id || fresh.Revision == recipe.Revision || IsDirty)
        {
            return false;
        }

        Load(fresh);
        return true;
    }

    public void Revert() => Text = Recipe?.Text ?? string.Empty;

    public void Conflicted(Recipe? current) => Conflict = current ?? Recipe;

    /// <summary>Keeps the edits and saves them over the newer revision.</summary>
    public long? KeepMine() => Conflict?.Revision;

    /// <summary>Drops the edits for the newer revision.</summary>
    public void TakeTheirs()
    {
        if (Conflict is { } theirs)
        {
            Load(theirs);
        }
    }
}

/// <summary>
/// A trial of unsaved recipe text: its job, then the trial brief or why there is none. The trial is
/// not listed in Today.
/// </summary>
public sealed class RecipeTrial
{
    public long? JobId { get; private set; }
    public Brief? Result { get; private set; }
    public string? Problem { get; private set; }

    public bool IsRunning => JobId is not null && Result is null && Problem is null;

    public void Reset()
    {
        JobId = null;
        Result = null;
        Problem = null;
    }

    public void Started(long jobId)
    {
        Reset();
        JobId = jobId;
    }

    public void Failed(string problem) => Problem = problem;

    public void Written(Brief result) => Result = result;

    /// <summary>Reads the trial's job from a job list; returns the trial brief to fetch once it is done.</summary>
    public long? Finished(IReadOnlyList<WriterJob> jobs)
    {
        if (!IsRunning || jobs.FirstOrDefault(job => job.Id == JobId) is not { IsActive: false } job)
        {
            return null;
        }

        if (job.IsDone && job.ArtifactId is { } artifact)
        {
            return artifact;
        }

        Failed(job.Status switch
        {
            "done" => "The writer finished but returned nothing to show.",
            "cancelled" => "You cancelled it.",
            _ => string.IsNullOrWhiteSpace(job.Error) ? "The writer stopped." : job.Error.Trim(),
        });
        return null;
    }
}

/// <summary>The words of the recipe page, matching macOS.</summary>
public static class RecipeText
{
    public const string Fixed =
        "Fyke adds the selected articles and its citation rules after your text. They are fixed, so a recipe cannot turn citations off.";

    public const string TrialWorkingDetail =
        "Nothing is saved: the trial is not listed in Today, and the recipe keeps its text until you save it.";

    public const string ConflictDetail =
        "Your edits are still here and nothing is saved yet. Keeping yours makes it the newest revision; the other stays in History.";

    /// <summary>"Tells the writer how to write the brief · revision 3 · edited 2 hours ago".</summary>
    public static string Subtitle(Recipe recipe, string? writer, DateTimeOffset now)
    {
        var parts = new List<string>
        {
            $"Tells {writer ?? "the writer"} how to write the brief",
            string.Create(CultureInfo.CurrentCulture, $"revision {recipe.Revision}"),
        };
        if (BriefText.Time(recipe.CreatedAt) is { } edited)
        {
            parts.Add($"edited {BriefText.Relative(edited, now)}");
        }

        return string.Join(" · ", parts);
    }

    public static string ConflictTitle(Recipe theirs) =>
        string.Create(CultureInfo.CurrentCulture, $"This recipe changed elsewhere (revision {theirs.Revision}).");

    public static string TrialIntro(Brief? brief) => brief is null
        ? "Writes over your newest unread articles with the text in Edit, saved or not."
        : $"Writes over the {BriefText.Count(brief.InputCount, "article")} of this brief with the text in Edit, saved or not.";

    public static string Revision(RecipeRevision revision) =>
        string.Create(CultureInfo.CurrentCulture, $"Revision {revision.Revision}");
}

/// <summary>Reads, saves and tries recipes with the daemon's recipe operations, as macOS does.</summary>
public sealed class Recipes(IDaemonClient client)
{
    public Task<Recipe> GetAsync(long id, CancellationToken ct) =>
        ReadAsync("recipes.get", new JsonObject { ["id"] = id }, WireJson.Default.Recipe, ct);

    /// <summary>The text of an older revision.</summary>
    public async Task<string> RevisionTextAsync(long id, long revision, CancellationToken ct) =>
        (await ReadAsync("recipes.get", new JsonObject { ["id"] = id, ["revision"] = revision }, WireJson.Default.Recipe, ct)
            .ConfigureAwait(false)).Text;

    /// <summary>Every revision, newest first.</summary>
    public async Task<IReadOnlyList<RecipeRevision>> HistoryAsync(long id, CancellationToken ct) =>
        [.. ((await ReadAsync("recipes.history", new JsonObject { ["id"] = id }, WireJson.Default.RevisionList, ct)
            .ConfigureAwait(false)).Items ?? []).OrderByDescending(revision => revision.Revision)];

    /// <summary>Saves the text as a new revision over <paramref name="expectedRevision"/>.</summary>
    /// <exception cref="RecipeConflictException">Another revision was saved since.</exception>
    public Task<Recipe> SaveAsync(Recipe recipe, string text, long expectedRevision, CancellationToken ct, string note = "") =>
        WriteAsync("recipes.put", new JsonObject
        {
            ["id"] = recipe.Id,
            ["name"] = recipe.DisplayName,
            ["text"] = text,
            ["note"] = note,
            ["expected_revision"] = expectedRevision,
        }, ct);

    /// <summary>Appends the built-in text as a new revision.</summary>
    public Task<Recipe> ResetAsync(Recipe recipe, CancellationToken ct) =>
        WriteAsync("recipes.reset", new JsonObject { ["id"] = recipe.Id, ["expected_revision"] = recipe.Revision }, ct);

    /// <summary>
    /// Writes a trial with unsaved text over a brief's view, or the unread articles. The result is
    /// not listed as a brief.
    /// </summary>
    public async Task<WriterJob> TryAsync(long recipeId, string text, long? viewId, CancellationToken ct)
    {
        var job = await ReadAsync("briefs.try", new JsonObject
        {
            ["view_id"] = viewId,
            ["rule"] = viewId is null ? new JsonObject { ["state"] = "unread" } : null,
            ["recipe_id"] = recipeId,
            ["text"] = text,
        }, WireJson.Default.WriterJob, ct).ConfigureAwait(false);
        return job.Id > 0 ? job : throw new DaemonProtocolException("The daemon did not return a job for briefs.try.");
    }

    public Task<Brief> TrialAsync(long artifactId, CancellationToken ct) =>
        ReadAsync("briefs.get", new JsonObject { ["id"] = artifactId }, WireJson.Default.Brief, ct);

    private async Task<Recipe> WriteAsync(string method, JsonObject parameters, CancellationToken ct)
    {
        try
        {
            return await ReadAsync(method, parameters, WireJson.Default.Recipe, ct).ConfigureAwait(false);
        }
        catch (DaemonRpcException error) when (error.Is("RevisionConflict"))
        {
            throw new RecipeConflictException(Current(error.ErrorData));
        }
    }

    // The refusal carries the current revision, text included.
    private static Recipe? Current(JsonElement? data)
    {
        try
        {
            return data is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty("current", out var current)
                && current.ValueKind == JsonValueKind.Object
                ? current.Deserialize(WireJson.Default.Recipe)
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private async Task<T> ReadAsync<T>(string method, JsonObject parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);

    internal sealed record RevisionList(RecipeRevision[]? Items);
}
