using System.Globalization;
using System.Text.Json;
using Fyke.ViewModels;

namespace Fyke.ViewModels.Tests;

public sealed class StorageTests
{
    private static readonly ArticleUse Articles = new(Entries: 12_400, Feeds: 31, TextBytes: 30_000_000, SearchBytes: 9_000_000,
        OtherBytes: 1_000_000, Removable: 820, RemovableBytes: 4_200_000);

    [Fact]
    public async Task UseIsReadAsTheDaemonWritesIt()
    {
        var storage = new Storage(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                Assert.Equal("storage.get", method);
                Assert.Null(parameters);
                return JsonElement.Parse("""
                    {"articles":{"entries":12400,"feeds":31,"text_bytes":30000000,"search_bytes":9000000,"other_bytes":1000000,
                      "removable":820,"removable_bytes":4200000},
                     "database_bytes":41000000,"raw_bytes":2500000,"raw_files":240,"log_bytes":120000,"settings_bytes":3000}
                    """);
            },
        });

        var use = await storage.GetAsync(CancellationToken.None);

        Assert.Equal(Articles, use.Articles);
        Assert.Equal(240, use.RawFiles);
        Assert.Equal(123_000, use.LogsAndSettingsBytes);
        Assert.Equal(41_000_000 + 2_500_000 + 123_000, use.TotalBytes);
    }

    [Fact]
    public async Task FreeingAndRetentionSendWhatMacOSSends()
    {
        var calls = new List<string>();
        var storage = new Storage(new FakeClient
        {
            OnCall = (method, parameters) =>
            {
                calls.Add($"{method} {parameters?.GetRawText()}");
                return method == "storage.free"
                    ? JsonElement.Parse("""{"trimmed":820,"copies_removed":0}""")
                    : JsonElement.Parse("""{"ok":true}""");
            },
        });

        var freed = await storage.FreeArticlesAsync(CancellationToken.None);
        await storage.FreeCopiesAsync(CancellationToken.None);
        await storage.SetRetentionAsync(30, CancellationToken.None);

        Assert.Equal(new StorageFreed(820, 0), freed);
        Assert.Equal(
        [
            """storage.free {"trim_older_than_days":90}""",
            """storage.free {"feed_copies":true}""",
            """config.set {"remove_read_after_days":30}""",
        ], calls);
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => storage.SetRetentionAsync(-1, CancellationToken.None));
    }

    [Fact]
    public async Task RetentionIsReadWithTheOtherSettings()
    {
        var settings = new ReaderSettings(new FakeClient
        {
            OnCall = (_, _) => JsonElement.Parse("""{"full_text":false,"remove_read_after_days":30}"""),
        });

        Assert.Equal(30, (await settings.ReadAsync(CancellationToken.None)).RemoveReadAfterDays);
    }

    [Fact]
    public void SizesReadAsFinderWritesThem()
    {
        using var culture = new CultureScope("en-US");
        Assert.Equal("0 KB", StorageText.Size(0));
        Assert.Equal("1 byte", StorageText.Size(1));
        Assert.Equal("999 bytes", StorageText.Size(999));
        Assert.Equal("120 KB", StorageText.Size(120_400));
        Assert.Equal("41.2 MB", StorageText.Size(41_200_000));
        Assert.Equal("1.24 GB", StorageText.Size(1_240_000_000));
    }

    [Fact]
    public void TheWordsMatchMacOS()
    {
        using var culture = new CultureScope("en-US");
        var now = new DateTimeOffset(2026, 11, 20, 15, 0, 0, TimeSpan.Zero);

        Assert.Equal("12,400 articles in 31 feeds. 820 were read over 90 days ago (4.2 MB).", StorageText.ArticlesDetail(Articles));
        Assert.Equal("12,400 articles in 31 feeds.", StorageText.ArticlesDetail(Articles with { Removable = 0 }));
        Assert.Equal("Removes the text of 820 articles read over 90 days ago. Titles, links and starred articles stay.",
            StorageText.FreeArticlesPrompt(Articles));
        Assert.Equal("240 copies", StorageText.Copies(240));
        Assert.Equal("Checked just now", StorageText.Checked(now.AddSeconds(-20), now));
        Assert.Equal("Checked 5 minutes ago", StorageText.Checked(now.AddMinutes(-5), now));
        Assert.Equal(@"~\AppData\Local\Fyke", StorageText.Tilde(@"C:\Users\ana\AppData\Local\Fyke", @"C:\Users\ana"));
        Assert.Equal(@"D:\Fyke", StorageText.Tilde(@"D:\Fyke", @"C:\Users\ana"));
        Assert.Equal(@"C:\Users\anabel", StorageText.Tilde(@"C:\Users\anabel", @"C:\Users\ana"));
        Assert.Equal(["Never", "30 days", "90 days", "1 year"], StorageText.RetentionChoicesWith(90).Select(choice => choice.Label));
        Assert.Equal("60 days", StorageText.RetentionChoicesWith(60)[^1].Label);
    }

    [Fact]
    public void AFolderThatHoldsSomethingGetsAFolderOfItsOwn()
    {
        var root = Directory.CreateTempSubdirectory("fyke-move-").FullName;
        try
        {
            var empty = Directory.CreateDirectory(Path.Combine(root, "empty")).FullName;
            Assert.Equal(empty, DataMoves.Target(empty + Path.DirectorySeparatorChar, out var problem));
            Assert.Null(problem);

            var missing = Path.Combine(root, "missing");
            Assert.Equal(missing, DataMoves.Target(missing, out _));

            var busy = Directory.CreateDirectory(Path.Combine(root, "busy")).FullName;
            File.WriteAllText(Path.Combine(busy, "notes.txt"), "mine");
            Assert.Equal(Path.Combine(busy, DataMoves.SubfolderName), DataMoves.Target(busy, out problem));
            Assert.Null(problem);

            File.WriteAllText(Path.Combine(Directory.CreateDirectory(Path.Combine(busy, DataMoves.SubfolderName)).FullName, "x"), "x");
            Assert.Null(DataMoves.Target(busy, out problem));
            Assert.Equal("That folder already holds a fyke_data folder", problem);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void AMoveWarnsAboutSpaceAndDrivesThatCanBeUnplugged()
    {
        var c = new DriveFacts(@"C:\", 500_000_000, External: false);
        Assert.Equal(DataMoveWarning.None, DataMoves.Warn(c, c, 100_000_000));
        // A move copies even within one drive, so the room is checked there too.
        Assert.Equal(DataMoveWarning.NoSpace, DataMoves.Warn(c, c with { FreeBytes = 110_000_000 }, 100_000_000));
        Assert.Equal(DataMoveWarning.External, DataMoves.Warn(c, new DriveFacts(@"E:\", 9_000_000_000, External: true), 100_000_000));
        Assert.Equal(DataMoveWarning.None, DataMoves.Warn(c, new DriveFacts(@"D:\", null, External: false), 100_000_000));
        Assert.False(new DataMovePlan(@"E:\Fyke", 1, DataMoveWarning.NoSpace).CanMove);
        Assert.True(new DataMovePlan(@"E:\Fyke", 1, DataMoveWarning.External).CanMove);
    }

    [Fact]
    public void TheCommandsStagesAndFailuresReadAsWords()
    {
        Assert.Equal("Stopping…", DataMoves.Stage("stopping\r"));
        Assert.Equal("Moving…", DataMoves.Stage("copying"));
        Assert.Equal("Checking the copy…", DataMoves.Stage("verifying"));
        Assert.Equal("Restarting…", DataMoves.Stage("starting"));
        Assert.Null(DataMoves.Stage("done"));

        Assert.Equal("That folder is not empty. Your data is where it was.",
            DataMoves.Failure("stopping\n", "fyke: data: TargetNotEmpty\n"));
        Assert.Equal("Something went wrong. Your data is where it was.", DataMoves.Failure(string.Empty, "fyke: data: Unexpected"));
        Assert.Equal(DataMoves.MovedButNotRestarted, DataMoves.Failure("stopping\ncopying\nverifying\nlinking\nstarting\n", "fyke: data: Timeout"));
        Assert.Equal("Fyke didn\u2019t restart", DataMoves.FailureHeading(DataMoves.MovedButNotRestarted));
        Assert.Equal("Your data wasn\u2019t moved", DataMoves.FailureHeading("That folder is not empty. Your data is where it was."));
    }

    [Fact]
    public async Task TheMoveCommandReportsEachStageAsItPrintsIt()
    {
        if (OperatingSystem.IsWindows())
        {
            return; // The fake command is a shell script; Windows CI runs the real one in the desktop smoke test.
        }

        var folder = Directory.CreateTempSubdirectory("fyke-move-cmd-").FullName;
        try
        {
            var program = Path.Combine(folder, "fyke");
            File.WriteAllText(program, "#!/bin/sh\necho \"$1 $2 $3\" >&2\nprintf 'stopping\\ncopying\\nverifying\\n'\nexit 3\n");
            File.SetUnixFileMode(program, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var stages = new List<string>();

            var outcome = await DataMoves.RunAsync(program, "/tmp/new place", stages.Add, CancellationToken.None);

            Assert.False(outcome.Succeeded);
            Assert.Equal(3, outcome.ExitCode);
            Assert.Equal("data move /tmp/new place\n", outcome.Errors);
            Assert.Equal(["Stopping…", "Moving…", "Checking the copy…"], stages);
            var missing = await DataMoves.RunAsync(Path.Combine(folder, "absent"), "/tmp/x", stages.Add, CancellationToken.None);
            Assert.False(missing.Succeeded);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    private sealed class CultureScope : IDisposable
    {
        private readonly CultureInfo previous = CultureInfo.CurrentCulture;

        public CultureScope(string name) => CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(name);

        public void Dispose() => CultureInfo.CurrentCulture = previous;
    }
}
