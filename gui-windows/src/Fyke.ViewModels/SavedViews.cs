using System.Text.Json;
using Fyke.Client;

namespace Fyke.ViewModels;

public sealed record ViewRule
{
    public long[] Feeds { get; init; } = [];
    public long[] Folders { get; init; } = [];
    public string State { get; init; } = "any";
    public string? Words { get; init; }
    public bool AnyWords { get; init; }
    public string? Host { get; init; }
    public bool Subdomains { get; init; }
    public string? PathPrefix { get; init; }
    public string[] ExcludePathPrefix { get; init; } = [];
    public long? WithinDays { get; init; }

    public static ViewRule FromSearch(string query, bool unreadOnly) => new()
    {
        Words = query.Trim() is { Length: > 0 } words ? words : null,
        State = unreadOnly ? "unread" : "any",
    };
}

public sealed record SavedView(long Id, string Name, ViewRule Rule, long Revision, string Sentence, long Unread, long Total);

public sealed record ViewPreview(long Total, long Unread);
public sealed record ViewRemoval(bool Ok, string? Kind, long[]? RoutineIds);

/// <summary>Uses the same view operations as the macOS GUI and MCP.</summary>
public sealed class SavedViews(IDaemonClient client)
{
    private static readonly JsonSerializerOptions Wire = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public async Task<IReadOnlyList<SavedView>> ListAsync(CancellationToken ct)
    {
        try
        {
            return (await ReadAsync<ViewList>("views.list", null, ct).ConfigureAwait(false)).Items;
        }
        catch (DaemonRpcException error) when (error.IsUnknownMethod)
        {
            return [];
        }
    }

    public Task<SavedView> GetAsync(long id, CancellationToken ct) => ReadAsync<SavedView>("views.get", new { Id = id }, ct);

    public Task<ViewPreview> PreviewAsync(ViewRule rule, CancellationToken ct) =>
        ReadAsync<ViewPreview>("views.preview", new { Rule = rule, Limit = 1 }, ct);

    public Task<SavedView> SaveAsync(string name, ViewRule rule, SavedView? previous, CancellationToken ct) =>
        ReadAsync<SavedView>("views.put", new { Name = name.Trim(), Rule = rule, Id = previous?.Id, ExpectedRevision = previous?.Revision }, ct);

    public Task MoveAsync(long id, int position, CancellationToken ct) =>
        client.CallAsync("views.move", new { Id = id, Position = position }, ct);

    public Task<ViewRemoval> RemoveAsync(long id, bool detach, CancellationToken ct) =>
        ReadAsync<ViewRemoval>("views.remove", new { Id = id, Detach = detach }, ct);

    private async Task<T> ReadAsync<T>(string method, object? parameters, CancellationToken ct)
    {
        var reply = await client.CallAsync(method, parameters, ct).ConfigureAwait(false);
        return reply.Deserialize<T>(Wire) ?? throw new DaemonProtocolException($"The daemon returned no result for {method}.");
    }

    private sealed record ViewList(SavedView[] Items);
}
