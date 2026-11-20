using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>
/// Reads and writes the daemon's JSON with code generated at build time, so the app can be
/// trimmed and compiled ahead of time. Every type that crosses the socket is listed here.
/// </summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower)]
[JsonSerializable(typeof(ArticleBlock[]))]
[JsonSerializable(typeof(Brief))]
[JsonSerializable(typeof(Briefs.BriefList))]
[JsonSerializable(typeof(Briefs.JobList))]
[JsonSerializable(typeof(Briefs.RecipeList))]
[JsonSerializable(typeof(CatalogEdits.OpmlDocument))]
[JsonSerializable(typeof(CatalogEdits.OpmlImportCounts))]
[JsonSerializable(typeof(CatalogEdits.RefreshQueue))]
[JsonSerializable(typeof(DiscussionThread))]
[JsonSerializable(typeof(FeedRefresh))]
[JsonSerializable(typeof(FeedSubscriptions.FeedPreview))]
[JsonSerializable(typeof(ReaderData.ArticleBody))]
[JsonSerializable(typeof(ReaderData.FetchFullReply))]
[JsonSerializable(typeof(ReaderData.BulkMarkReply))]
[JsonSerializable(typeof(ReaderData.CatchUpMarkReply))]
[JsonSerializable(typeof(ReaderData.CatalogItems<ReaderData.Entry>))]
[JsonSerializable(typeof(ReaderData.CatalogItems<ReaderData.Feed>))]
[JsonSerializable(typeof(ReaderData.CatalogItems<ReaderData.Folder>))]
[JsonSerializable(typeof(ReaderData.EntryPage))]
[JsonSerializable(typeof(ReaderData.MarkReply))]
[JsonSerializable(typeof(Recipe))]
[JsonSerializable(typeof(Recipes.RevisionList))]
[JsonSerializable(typeof(Routine))]
[JsonSerializable(typeof(RoutineDryRun))]
[JsonSerializable(typeof(Routines.RoutineList))]
[JsonSerializable(typeof(SavedView))]
[JsonSerializable(typeof(SavedViews.ViewList))]
[JsonSerializable(typeof(ViewPreview))]
[JsonSerializable(typeof(ViewRemoval))]
[JsonSerializable(typeof(ViewRule))]
[JsonSerializable(typeof(WriterJob))]
[JsonSerializable(typeof(Writers.WriterList))]
internal sealed partial class WireJson : JsonSerializerContext;

internal static class Wire
{
    /// <summary>The reply as <typeparamref name="T"/>, or a protocol error naming the operation.</summary>
    public static T Read<T>(JsonElement reply, JsonTypeInfo<T> type, string method) =>
        reply.Deserialize(type) ?? throw new DaemonProtocolException($"The daemon returned no result for {method}.");

    public static JsonNode? Node<T>(T value, JsonTypeInfo<T> type) => JsonSerializer.SerializeToNode(value, type);

    public static JsonArray Ids(IEnumerable<long> ids) => new([.. ids.Select(id => (JsonNode)id)]);
}
