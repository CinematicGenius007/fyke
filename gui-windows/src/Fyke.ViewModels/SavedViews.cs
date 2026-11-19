using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;
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
    public async Task<IReadOnlyList<SavedView>> ListAsync(CancellationToken ct)
    {
        try
        {
            return (await ReadAsync("views.list", null, WireJson.Default.ViewList, ct).ConfigureAwait(false)).Items;
        }
        catch (DaemonRpcException error) when (error.IsUnknownMethod)
        {
            return [];
        }
    }

    public Task<SavedView> GetAsync(long id, CancellationToken ct) =>
        ReadAsync("views.get", new JsonObject { ["id"] = id }, WireJson.Default.SavedView, ct);

    public Task<ViewPreview> PreviewAsync(ViewRule rule, CancellationToken ct) =>
        ReadAsync("views.preview", new JsonObject { ["rule"] = Wire.Node(rule, WireJson.Default.ViewRule), ["limit"] = 1 },
            WireJson.Default.ViewPreview, ct);

    public Task<SavedView> SaveAsync(string name, ViewRule rule, SavedView? previous, CancellationToken ct) =>
        ReadAsync("views.put", new JsonObject
        {
            ["name"] = name.Trim(),
            ["rule"] = Wire.Node(rule, WireJson.Default.ViewRule),
            ["id"] = previous?.Id,
            ["expected_revision"] = previous?.Revision,
        }, WireJson.Default.SavedView, ct);

    public Task MoveAsync(long id, int position, CancellationToken ct) =>
        client.CallAsync("views.move", new JsonObject { ["id"] = id, ["position"] = position }, ct);

    public Task<ViewRemoval> RemoveAsync(long id, bool detach, CancellationToken ct) =>
        ReadAsync("views.remove", new JsonObject { ["id"] = id, ["detach"] = detach }, WireJson.Default.ViewRemoval, ct);

    private async Task<T> ReadAsync<T>(string method, JsonObject? parameters, JsonTypeInfo<T> type, CancellationToken ct) =>
        Wire.Read(await client.CallAsync(method, parameters, ct).ConfigureAwait(false), type, method);

    internal sealed record ViewList(SavedView[] Items);
}
