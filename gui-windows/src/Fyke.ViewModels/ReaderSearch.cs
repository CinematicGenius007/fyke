namespace Fyke.ViewModels;

public sealed record SearchHit(TimelineArticle Article, IReadOnlyList<SearchSnippetRun> Snippet, long SortAt)
{
    public string Title => Article.Title;
    public string? FeedTitle => Article.FeedTitle;
    public string AccessibleName => Article.AccessibleName;
}

public readonly record struct SearchSnippetRun(string Text, bool Match);

public static class SearchSnippet
{
    public static IReadOnlyList<SearchSnippetRun> Split(string? preview, string query)
    {
        if (string.IsNullOrEmpty(preview))
        {
            return [];
        }

        var text = preview.Replace("...", "…", StringComparison.Ordinal);
        var matches = new bool[text.Length];
        var terms = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        foreach (var term in terms.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            for (var match = text.IndexOf(term, StringComparison.OrdinalIgnoreCase); match >= 0;
                match = text.IndexOf(term, match + 1, StringComparison.OrdinalIgnoreCase))
            {
                matches.AsSpan(match, term.Length).Fill(true);
            }
        }

        var runs = new List<SearchSnippetRun>();
        var first = 0;
        for (var index = 1; index <= text.Length; index++)
        {
            if (index == text.Length || matches[first] != matches[index])
            {
                runs.Add(new SearchSnippetRun(text[first..index], matches[first]));
                first = index;
            }
        }

        return runs;
    }
}
