using System.Text.Json;
using Fyke.Client;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class WritersTests
{
    // writers.list as the daemon writes it (src/runner.zig).
    private const string ListReply = """
        {"items":[
          {"writer":"codex","installed":true,"signed_in":true,"available":true,"version":"0.9.1","path":"C:\\Users\\me\\bin\\codex.exe","problem":null,"checked_at":1,"selected":false},
          {"writer":"claude","installed":true,"signed_in":false,"available":false,"version":null,"path":"C:\\tools\\claude.exe","profile":"C:\\Users\\me\\.claude_personal","problem":"Sign in with claude /login.","checked_at":1,"selected":true}
        ]}
        """;

    [Fact]
    public async Task ListReadsEachWriter()
    {
        var writers = new Writers(new FakeClient
        {
            OnCall = (method, _) =>
            {
                Assert.Equal("writers.list", method);
                return JsonElement.Parse(ListReply);
            },
        });

        var list = await writers.ListAsync(CancellationToken.None);

        Assert.Equal(["Codex", "Claude Code"], list.Select(writer => writer.Name));
        Assert.Equal(["Cx", "C"], list.Select(writer => writer.Badge));
        Assert.True(list[0].Available);
        Assert.True(list[1].IsClaude);
        Assert.Equal(@"C:\Users\me\.claude_personal", list[1].Profile);
        Assert.Equal("claude", Writers.Current(list)!.Id);
        Assert.Equal("codex", Writers.Current([list[0], list[1] with { Selected = false }])!.Id);
    }

    [Fact]
    public async Task ChoosingAndProfilesGoToTheAiSection()
    {
        var sent = new List<(string Method, JsonElement? Parameters)>();
        var writers = new Writers(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                sent.Add((method, parameters));
                return JsonElement.Parse("{}");
            },
        });

        await writers.ChooseAsync("codex", CancellationToken.None);
        await writers.SetClaudeProfileAsync("", CancellationToken.None);
        await writers.CheckAsync("claude", CancellationToken.None);
        await writers.SetAgentTierAsync(AgentTier.Annotate, CancellationToken.None);

        Assert.Equal("codex", sent[0].Parameters!.Value.GetProperty("ai").GetProperty("writer").GetString());
        Assert.Equal("", sent[1].Parameters!.Value.GetProperty("ai").GetProperty("claude_profile").GetString());
        Assert.Equal("writers.check", sent[2].Method);
        Assert.Equal("claude", sent[2].Parameters!.Value.GetProperty("writer").GetString());
        Assert.Equal("annotate", sent[3].Parameters!.Value.GetProperty("ui_patch").GetProperty("agentTier").GetString());
    }

    [Fact]
    public void WordsMatchMacOs()
    {
        const string home = @"C:\Users\me";
        var codex = new Writer { Id = "codex", Installed = true, Available = true, Version = "0.9.1", Path = @"C:\Users\me\bin\codex.exe" };
        Assert.Equal(@"Ready · 0.9.1 · found at ~\bin\codex.exe", WriterText.Status(codex, home));
        Assert.Equal("Not found on this PC", WriterText.Status(new Writer { Id = "codex" }, home));
        Assert.Equal("Not found on this PC",
            WriterText.Status(new Writer { Id = "codex", Problem = "Not found on this PC" }, home));
        Assert.Equal("Found, but its version check failed",
            WriterText.Status(new Writer { Id = "codex", Problem = "Found, but its version check failed" }, home));
        Assert.Equal("Sign in first.", WriterText.Status(codex with { Problem = " Sign in first. " }, home));
        Assert.Equal(WriterText.DefaultProfile, WriterText.Profile(new Writer { Id = "claude" }, home));
        Assert.Equal(@"~\.claude_personal", WriterText.Profile(new Writer { Id = "claude", Profile = @"C:\Users\me\.claude_personal" }, home));
        Assert.Equal(@"C:\Users\meg\x", WriterText.Tilde(@"C:\Users\meg\x", home));
        Assert.Equal("The writer", WriterText.Name(null));
        Assert.Equal("choose a folder that exists.",
            WriterText.Problem(new DaemonRpcException("InvalidProfile", -32000, null, null)));
    }

    [Fact]
    public void McpConfigNamesTheTier()
    {
        var read = JsonElement.Parse(AgentAccess.McpConfig(@"C:\Fyke\fyke.exe", AgentTier.Read))
            .GetProperty("mcpServers").GetProperty("fyke");
        Assert.Equal(@"C:\Fyke\fyke.exe", read.GetProperty("command").GetString());
        Assert.Equal(["mcp"], read.GetProperty("args").EnumerateArray().Select(arg => arg.GetString()));

        var manage = JsonElement.Parse(AgentAccess.McpConfig("fyke", AgentTier.Manage))
            .GetProperty("mcpServers").GetProperty("fyke").GetProperty("args");
        Assert.Equal(["mcp", "--tier", "manage"], manage.EnumerateArray().Select(arg => arg.GetString()));

        Assert.Equal(AgentTier.Annotate, AgentAccess.FromUi(JsonElement.Parse("""{"agentTier":"annotate"}""")));
        Assert.Equal(AgentTier.Read, AgentAccess.FromUi(JsonElement.Parse("""{"agentTier":"x"}""")));
        Assert.Equal(AgentTier.Read, AgentAccess.FromUi(default));
    }
}
