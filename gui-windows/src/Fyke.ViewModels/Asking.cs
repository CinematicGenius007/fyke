using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>One question and what became of it.</summary>
public sealed record AskTurn(string Question)
{
    public long? JobId { get; init; }
    public Brief? Answer { get; init; }
    public string? Problem { get; init; }

    /// <summary>Asked and not yet answered or refused.</summary>
    public bool IsWaiting => Answer is null && Problem is null;
}

/// <summary>
/// Ask your feeds, as on macOS (gui/Sources/Reader/Ask.swift): a question over a saved view or
/// every feed, answered only from the articles, with each claim cited. A follow-up names the
/// question before it so the writer answers in context.
/// </summary>
public sealed class AskSession
{
    private readonly List<AskTurn> turns = [];

    public IReadOnlyList<AskTurn> Turns => turns;

    /// <summary>The saved view asked over, or none for every feed.</summary>
    public long? ViewId { get; private set; }

    public AskTurn? Latest => turns.Count > 0 ? turns[^1] : null;

    public bool IsAsking => Latest is { IsWaiting: true };

    public void Start(long? viewId)
    {
        turns.Clear();
        ViewId = viewId;
    }

    /// <summary>Adds a turn and returns the question to send, or null when there is nothing to ask yet.</summary>
    public string? Begin(string draft)
    {
        var text = draft.Trim();
        if (text.Length == 0 || IsAsking)
        {
            return null;
        }

        var question = Latest is { } earlier ? $"Earlier question: {earlier.Question}\nFollow-up: {text}" : text;
        turns.Add(new AskTurn(text));
        return question;
    }

    public void Queued(long jobId) => Update(turn => turn with { JobId = jobId });

    public void Refused(string problem) => Update(turn => turn with { Problem = problem });

    public void Answered(Brief answer) => Update(turn => turn with { Answer = answer });

    /// <summary>
    /// Reads the latest turn's job from a job list. Returns the answer to fetch once the job is
    /// done; a failed or cancelled job ends the turn with the reason.
    /// </summary>
    public long? Finished(IReadOnlyList<WriterJob> jobs)
    {
        if (Latest is not { IsWaiting: true, JobId: { } id } || jobs.FirstOrDefault(job => job.Id == id) is not { } job
            || job.IsActive)
        {
            return null;
        }

        if (job.IsDone && job.ArtifactId is { } answer)
        {
            return answer;
        }

        Refused(job.Status switch
        {
            "done" => "The writer finished without an answer.",
            "cancelled" => "You cancelled it.",
            _ => string.IsNullOrWhiteSpace(job.Error) ? "The writer stopped." : job.Error.Trim(),
        });
        return null;
    }

    /// <summary>Takes back an unanswered question so it can be asked again.</summary>
    public string? Retract()
    {
        if (Latest is not { Problem: not null } turn)
        {
            return null;
        }

        turns.RemoveAt(turns.Count - 1);
        return turn.Question;
    }

    private void Update(Func<AskTurn, AskTurn> change)
    {
        if (turns.Count > 0)
        {
            turns[^1] = change(turns[^1]);
        }
    }
}

/// <summary>The words of Ask, matching macOS.</summary>
public static class AskText
{
    public static string Scope(string? viewName) => viewName is null ? "in all your feeds" : $"in {viewName}";

    public static string Header(string scope, Brief? answer) =>
        answer is null ? scope
        : $"{scope} · {BriefText.Count(Math.Max(answer.InputCount, answer.Cited.Count), "article")} read";

    public static string Intro(string scope) => $"Answers come only from your articles {scope}, with every claim cited.";

    public static string Working(string scope) => $"Reading your articles {scope}";

    public const string WorkingDetail =
        "The writer answers only from your articles and cites each one it uses. Nothing is changed while it reads.";

    /// <summary>The answer as plain text, its sources numbered after it, for the clipboard.</summary>
    public static string Copy(Brief answer)
    {
        var text = new StringBuilder();
        foreach (var section in answer.Parts)
        {
            if (text.Length > 0)
            {
                text.Append("\n\n");
            }

            if (!string.IsNullOrWhiteSpace(section.Heading))
            {
                text.Append(section.Heading).Append('\n');
            }

            text.AppendJoin(' ', section.Items.Select(claim =>
                claim.Text + string.Concat(claim.Numbers.Select(number => $" [{number}]"))));
        }

        text.Append("\n\n");
        text.AppendJoin('\n', answer.Cited.Select(citation =>
            string.Create(CultureInfo.InvariantCulture, $"[{citation.Number}] {citation.DisplayTitle}")
            + (citation.Url is null ? string.Empty : $" <{citation.Url}>")));
        return text.ToString();
    }
}

/// <summary>Uses the daemon's ask and answer operations, the same ones the macOS reader uses.</summary>
public sealed class Asking(IDaemonClient client)
{
    /// <summary>Queues a cited answer over a saved view, or over every article, and returns the job.</summary>
    public async Task<WriterJob> RunAsync(string question, long? viewId, CancellationToken ct)
    {
        var reply = await client.CallAsync("ask.run", new JsonObject
        {
            ["view_id"] = viewId,
            ["rule"] = viewId is null ? new JsonObject() : null,
            ["question"] = question,
        }, ct).ConfigureAwait(false);
        var job = Wire.Read(reply, WireJson.Default.WriterJob, "ask.run");
        return job.Id > 0 ? job : throw new DaemonProtocolException("The daemon did not return a job for ask.run.");
    }

    public Task<Brief> AnswerAsync(long id, CancellationToken ct) =>
        ReadAsync("answers.get", new JsonObject { ["id"] = id }, WireJson.Default.Brief, ct);

    public async Task<IReadOnlyList<WriterJob>> JobsAsync(CancellationToken ct) =>
        (await ReadAsync("jobs.list", new JsonObject { ["limit"] = Briefs.ListLimit }, WireJson.Default.JobList, ct)
            .ConfigureAwait(false)).Items ?? [];

    public Task CancelAsync(long jobId, CancellationToken ct) =>
        client.CallAsync("jobs.cancel", new JsonObject { ["id"] = jobId }, ct);

    private async Task<T> ReadAsync<T>(string method, JsonObject? parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);
}
