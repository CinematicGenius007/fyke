using System.Globalization;

namespace Fyke.ViewModels;

/// <summary>What Catch up does with an article: Skip marks it read, Later saves it, Read now opens it.</summary>
public enum CatchUpDecision
{
    Skip,
    Later,
    Read,
}

/// <summary>An unread article as Catch up shows it, one at a time.</summary>
public sealed record CatchUpCard(long Id, string Title, string? FeedTitle, long SortAt, string? Preview);

/// <summary>An article's read and later state before Catch up marked it, so Undo can put it back.</summary>
public sealed record CatchUpMarks(bool Read, bool Later);

/// <summary>
/// The articles of one Catch up, as on macOS (gui/Sources/ReaderLogic CatchUpSession): a queue
/// decided in order, where Undo puts the last decided article back in front.
/// </summary>
public sealed class CatchUpSession(IReadOnlyList<CatchUpCard> queue)
{
    private readonly List<(long Id, CatchUpDecision Decision)> history = [];

    public IReadOnlyList<CatchUpCard> Queue { get; } = queue;

    public int Index { get; private set; }

    public CatchUpCard? Current => Index < Queue.Count ? Queue[Index] : null;

    public bool HasHistory => history.Count > 0;

    /// <summary>Whether more than one article is left, so the card draws the edges of the next ones.</summary>
    public bool HasMoreAfterCurrent => Queue.Count - Index > 1;

    public double Progress => Queue.Count == 0 ? 1 : (double)Index / Queue.Count;

    public int Count(CatchUpDecision decision) => history.Count(item => item.Decision == decision);

    /// <summary>Decides the current article and returns it, or none when every article is decided.</summary>
    public CatchUpCard? Decide(CatchUpDecision decision)
    {
        if (Current is not { } card)
        {
            return null;
        }

        history.Add((card.Id, decision));
        Index++;
        return card;
    }

    /// <summary>Takes back the last decision and shows that article again.</summary>
    public (long Id, CatchUpDecision Decision)? Undo()
    {
        if (history.Count == 0)
        {
            return null;
        }

        var last = history[^1];
        history.RemoveAt(history.Count - 1);
        Index = Math.Max(Index - 1, 0);
        return last;
    }
}

/// <summary>The words of Catch up, matching macOS.</summary>
public static class CatchUpText
{
    public static string Heading(string title) => $"Catching up on {title}";

    public static string Summary(CatchUpSession session) => string.Format(CultureInfo.CurrentCulture,
        "Skipped {0:N0} · Later {1:N0} · Read {2:N0}",
        session.Count(CatchUpDecision.Skip), session.Count(CatchUpDecision.Later), session.Count(CatchUpDecision.Read));

    /// <summary>"3 of 12", or nothing for an empty queue.</summary>
    public static string Position(CatchUpSession session) => session.Queue.Count == 0 ? string.Empty
        : string.Format(CultureInfo.CurrentCulture, "{0:N0} of {1:N0}",
            Math.Min(session.Index + 1, session.Queue.Count), session.Queue.Count);

    public static string Detail(CatchUpCard card, DateTimeOffset now) => string.Join(" · ",
        new[] { card.FeedTitle, card.SortAt > 0 && BriefText.Time(card.SortAt) is { } date ? BriefText.Relative(date, now) : null }
            .Where(part => !string.IsNullOrWhiteSpace(part)));

    public static string FinishedTitle(CatchUpSession session) =>
        session.Queue.Count == 0 ? "Nothing unread here" : "You’re caught up";

    public static string FinishedDetail(CatchUpSession session, string title) =>
        session.Queue.Count == 0 ? $"Every article in {title} is read."
        : $"{Summary(session)}. Articles saved for Later wait in their feeds.";

    /// <summary>The destination Catch up goes over: Today has no articles of its own, so it means All.</summary>
    public static string Title(ReaderDestination destination) =>
        destination.Scope == ReaderScope.Today ? "All" : destination.Title;
}
