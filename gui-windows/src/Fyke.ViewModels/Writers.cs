using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>
/// An agent on this PC that can write briefs, as <c>writers.list</c> reports it and macOS shows it
/// (gui/Sources/Reader/Models.swift, <c>Writer</c>).
/// </summary>
public sealed record Writer
{
    /// <summary><c>codex</c> or <c>claude</c>; the daemon names it <c>writer</c>.</summary>
    [JsonPropertyName("writer")]
    public string Id { get; init; } = string.Empty;

    /// <summary>On this PC, whether or not it is signed in.</summary>
    public bool Installed { get; init; }

    /// <summary>Installed and signed in: a brief can be written.</summary>
    public bool Available { get; init; }

    public string? Version { get; init; }
    public string? Path { get; init; }

    /// <summary>The Claude Code profile folder in use; null means Claude Code's default.</summary>
    public string? Profile { get; init; }

    public string? Problem { get; init; }
    public bool Selected { get; init; }

    [JsonIgnore]
    public string Name => WriterText.Name(Id);

    [JsonIgnore]
    public bool IsClaude => Id == "claude";

    /// <summary>"Cx" for Codex, otherwise the name's first letter, as the macOS badge reads.</summary>
    [JsonIgnore]
    public string Badge => Id == "codex" ? "Cx" : Name[..1].ToUpper(CultureInfo.CurrentCulture);
}

/// <summary>The words of the writer settings, matching macOS.</summary>
public static class WriterText
{
    public const string SectionDetail =
        "Fyke hands the selected articles and your recipe to an agent already on this PC. Fyke itself sends nothing anywhere else.";

    public const string Looking = "Looking for Codex and Claude Code…";

    public const string NeedsNewerService = "Writers need a newer Fyke service. Quit and open Fyke again.";

    public const string DefaultProfile = "Claude Code’s default (~/.claude)";

    public const string AgentsDetail =
        "Agents connected over MCP can search and read your articles. Article text can try to mislead an agent, so changes start off.";

    public static string Name(string? id) => id switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex",
        null or "" => "The writer",
        _ => CultureInfo.CurrentCulture.TextInfo.ToTitleCase(id.ToLowerInvariant()),
    };

    /// <summary>The writer's problem, "Not found on this PC", or "Ready · version · found at path".</summary>
    public static string Status(Writer writer, string? home = null)
    {
        // The daemon's own words for a missing writer name a Mac.
        if (!writer.Installed)
        {
            return "Not found on this PC";
        }

        if (!string.IsNullOrWhiteSpace(writer.Problem))
        {
            return writer.Problem.Trim();
        }

        if (!writer.Available)
        {
            return "Not signed in";
        }

        var status = "Ready";
        if (!string.IsNullOrWhiteSpace(writer.Version))
        {
            status += $" · {writer.Version.Trim()}";
        }

        if (!string.IsNullOrWhiteSpace(writer.Path))
        {
            status += $" · found at {Tilde(writer.Path, home)}";
        }

        return status;
    }

    public static string Profile(Writer writer, string? home = null) =>
        string.IsNullOrWhiteSpace(writer.Profile) ? DefaultProfile : Tilde(writer.Profile, home);

    /// <summary>Shortens a path under the home folder to <c>~</c>.</summary>
    public static string Tilde(string path, string? home = null)
    {
        home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return home.Length > 0 && path.StartsWith(home, StringComparison.OrdinalIgnoreCase)
            && (path.Length == home.Length || path[home.Length] is '\\' or '/')
            ? "~" + path[home.Length..]
            : path;
    }

    /// <summary>Why the daemon refused a writer setting, in words.</summary>
    public static string Problem(Exception error) => error switch
    {
        DaemonRpcException refusal when refusal.Is("InvalidProfile") => "choose a folder that exists.",
        DaemonRpcException refusal when refusal.Is("UnknownWriter") || refusal.Is("InvalidWriter") => "Fyke does not know that writer.",
        DaemonRpcException { Message.Length: > 0 } refusal => refusal.Message.TrimEnd('.') + ".",
        _ => "Fyke couldn’t reach its service.",
    };
}

/// <summary>What agents connected over MCP may change, kept in the interface settings as macOS keeps it.</summary>
public enum AgentTier { Read, Annotate, Manage }

public static class AgentAccess
{
    public static AgentTier Parse(string? value) => value switch
    {
        "annotate" => AgentTier.Annotate,
        "manage" => AgentTier.Manage,
        _ => AgentTier.Read,
    };

    public static string Name(AgentTier tier) => tier switch
    {
        AgentTier.Annotate => "annotate",
        AgentTier.Manage => "manage",
        _ => "read",
    };

    public static AgentTier FromUi(JsonElement ui) =>
        ui.ValueKind == JsonValueKind.Object && ui.TryGetProperty("agentTier", out var tier) && tier.ValueKind == JsonValueKind.String
            ? Parse(tier.GetString())
            : AgentTier.Read;

    /// <summary>The configuration that adds Fyke to another agent, with the tier's arguments.</summary>
    public static string McpConfig(string program, AgentTier tier)
    {
        JsonNode[] words = tier == AgentTier.Read ? ["mcp"] : ["mcp", "--tier", Name(tier)];
        var args = new JsonArray(words);

        var config = new JsonObject
        {
            ["mcpServers"] = new JsonObject
            {
                ["fyke"] = new JsonObject { ["command"] = program, ["args"] = args },
            },
        };
        return config.ToJsonString(Indented);
    }

    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };
}

/// <summary>Lists, checks and chooses writers with the daemon's writer operations, as macOS does.</summary>
public sealed class Writers(IDaemonClient client)
{
    public async Task<IReadOnlyList<Writer>> ListAsync(CancellationToken ct) =>
        Wire.Read(await client.CallAsync("writers.list", null, ct).ConfigureAwait(false), WireJson.Default.WriterList, "writers.list")
            .Items ?? [];

    /// <summary>The writer briefs use: the chosen one, or else the first one found.</summary>
    public static Writer? Current(IReadOnlyList<Writer> writers) =>
        writers.FirstOrDefault(writer => writer.Selected) ?? writers.FirstOrDefault(writer => writer.Available);

    /// <summary>Runs the writer's version check again. It can take a while.</summary>
    public Task CheckAsync(string id, CancellationToken ct) =>
        client.CallAsync("writers.check", new JsonObject { ["writer"] = id }, ct);

    /// <summary>Makes the writer the default; it is kept in config.json under <c>ai</c>.</summary>
    public Task ChooseAsync(string id, CancellationToken ct) =>
        client.CallAsync("config.set", new JsonObject { ["ai"] = new JsonObject { ["writer"] = id } }, ct);

    /// <summary>Points Claude Code at the profile folder that holds its sign-in; an empty path goes back to its default.</summary>
    public Task SetClaudeProfileAsync(string path, CancellationToken ct) =>
        client.CallAsync("config.set", new JsonObject { ["ai"] = new JsonObject { ["claude_profile"] = path } }, ct);

    /// <summary>Saves what agents connected over MCP may change.</summary>
    public Task SetAgentTierAsync(AgentTier tier, CancellationToken ct) =>
        client.CallAsync("config.set", new JsonObject { ["ui_patch"] = new JsonObject { ["agentTier"] = AgentAccess.Name(tier) } }, ct);

    internal sealed record WriterList(Writer[]? Items);
}
