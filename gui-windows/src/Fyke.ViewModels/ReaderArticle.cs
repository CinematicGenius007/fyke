using System.Text.Json.Serialization;

namespace Fyke.ViewModels;

/// <summary>The article and its stored, structured body. Text in both comes from the feed.</summary>
/// <param name="Page">The article's own web page, when the feed gave a safe web address.</param>
public sealed record ReaderArticle(string? Title, string? FeedTitle, string? Author, IReadOnlyList<ArticleBlock> Blocks,
    DiscussionLink? Discussion, bool Read, bool Starred, Uri? Page = null);

/// <summary>What <c>entries.fetch_full</c> did with the article's page.</summary>
public enum FullTextOutcome { Done, Skipped, Failed, Later }

public readonly record struct ArticleMarks(bool Read, bool Starred);

/// <summary>The stored node shape from src/blocks.zig. Unknown kinds are ignored by the renderer.</summary>
public sealed record ArticleBlock(
    [property: JsonPropertyName("t")] string Kind,
    [property: JsonPropertyName("v")] string? Text,
    string? Lang,
    string? Src,
    string? Alt,
    string? Href,
    int? Level,
    bool? Ordered,
    [property: JsonPropertyName("c")] ArticleBlock[]? Children,
    ArticleBlock[][]? Items,
    ArticleBlock[][][]? Rows)
{
    public static Uri? WebAddress(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var address)
        && (address.Scheme == Uri.UriSchemeHttps || address.Scheme == Uri.UriSchemeHttp)
        && address.Host.Length != 0
        && address.UserInfo.Length == 0
            ? address : null;
}
