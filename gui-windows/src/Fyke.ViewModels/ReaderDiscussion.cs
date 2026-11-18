using System.Globalization;

namespace Fyke.ViewModels;

public sealed record DiscussionLink(Uri Address, ulong? HackerNewsItem)
{
    public static DiscussionLink? FromAddress(string? value) =>
        ArticleBlock.WebAddress(value) is Uri address ? new(address, GetHackerNewsItem(address)) : null;

    public static ulong? GetHackerNewsItem(Uri address)
    {
        // The daemon recognizes the literal thread path under the Hacker News authority.
        if (!address.IsAbsoluteUri || address.Scheme is not ("http" or "https") || address.AbsolutePath != "/item")
        {
            return null;
        }

        var prefix = $"{address.Scheme}://news.ycombinator.com/item?";
        var original = address.OriginalString.AsSpan();
        if (!original.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        // Uri can decode escaped digits even though the daemon reads the address literally.
        var query = original[prefix.Length..];
        var fragment = query.IndexOf('#');
        if (fragment >= 0)
        {
            query = query[..fragment];
        }

        foreach (var range in query.Split('&'))
        {
            var pair = query[range];
            if (pair.StartsWith("id=", StringComparison.Ordinal))
            {
                return ulong.TryParse(pair[3..], NumberStyles.None, CultureInfo.InvariantCulture, out var id)
                    ? id : null;
            }
        }

        return null;
    }
}

public sealed record DiscussionThread(IReadOnlyList<DiscussionComment> Comments, bool Truncated);

public sealed record DiscussionComment(ulong Id, string? Author, long? At, int Depth, ArticleBlock[] Blocks);

public sealed record DiscussionRow(int Index, DiscussionComment Comment, int ReplyCount);

public static class DiscussionRows
{
    public static IReadOnlyList<DiscussionRow> FromComments(IReadOnlyList<DiscussionComment> comments)
    {
        var rows = new DiscussionRow[comments.Count];
        for (var index = rows.Length - 1; index >= 0; index--)
        {
            var comment = comments[index];
            var next = index + 1;
            // Work backwards so each direct reply already knows the size of its subtree.
            while (next < rows.Length && comments[next].Depth > comment.Depth)
            {
                next += rows[next].ReplyCount + 1;
            }

            rows[index] = new(index, comment, next - index - 1);
        }

        return rows;
    }

    public static IReadOnlyList<DiscussionRow> Visible(IReadOnlyList<DiscussionRow> rows, IReadOnlySet<int> collapsed)
    {
        if (collapsed.Count == 0)
        {
            return rows;
        }

        var visible = new List<DiscussionRow>(rows.Count);
        for (var index = 0; index < rows.Count;)
        {
            var row = rows[index];
            visible.Add(row);
            index += 1 + (collapsed.Contains(row.Index) ? row.ReplyCount : 0);
        }

        return visible;
    }
}
