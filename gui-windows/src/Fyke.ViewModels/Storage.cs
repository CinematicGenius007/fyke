using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Fyke.Client;

namespace Fyke.ViewModels;

/// <summary>What the database holds, from <c>storage.get</c> (<c>ArticleUse</c> in src/store.zig).</summary>
public sealed record ArticleUse(long Entries, long Feeds, long TextBytes, long SearchBytes, long OtherBytes,
    long Removable, long RemovableBytes);

/// <summary>Disk use by kind, from <c>storage.get</c>.</summary>
public sealed record StorageUse(ArticleUse Articles, long DatabaseBytes, long RawBytes, long RawFiles, long LogBytes,
    long SettingsBytes)
{
    /// <summary>The log and config.json, which Storage shows as one line.</summary>
    public long LogsAndSettingsBytes => LogBytes + SettingsBytes;

    /// <summary>Everything in the data folder that Storage counts, which is what a move copies.</summary>
    public long TotalBytes => DatabaseBytes + RawBytes + LogsAndSettingsBytes;
}

/// <summary>What <c>storage.free</c> removed.</summary>
public sealed record StorageFreed(long Trimmed, long CopiesRemoved);

/// <summary>Reads disk use and frees space through the daemon, the only process that may touch the database.</summary>
public sealed class Storage(IDaemonClient client)
{
    /// <summary>The age past which read articles lose their text, as on macOS.</summary>
    public const int TrimDays = 90;

    public async Task<StorageUse> GetAsync(CancellationToken ct) =>
        Wire.Read(await client.CallAsync("storage.get", null, ct).ConfigureAwait(false), WireJson.Default.StorageUse, "storage.get");

    /// <summary>Removes the text of articles read over <see cref="TrimDays"/> days ago. Titles, links and starred articles stay.</summary>
    public Task<StorageFreed> FreeArticlesAsync(CancellationToken ct) =>
        FreeAsync(new JsonObject { ["trim_older_than_days"] = TrimDays }, ct);

    /// <summary>Keeps the newest copy of each feed and removes the rest.</summary>
    public Task<StorageFreed> FreeCopiesAsync(CancellationToken ct) =>
        FreeAsync(new JsonObject { ["feed_copies"] = true }, ct);

    private async Task<StorageFreed> FreeAsync(JsonObject parameters, CancellationToken ct) =>
        Wire.Read(await client.CallAsync("storage.free", parameters, ct).ConfigureAwait(false), WireJson.Default.StorageFreed, "storage.free");

    /// <summary>Removes read articles after this many days. Zero keeps them.</summary>
    public Task SetRetentionAsync(long days, CancellationToken ct)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(days);
        return client.CallAsync("config.set", new JsonObject { ["remove_read_after_days"] = days }, ct);
    }
}

/// <summary>A choice in "Remove read articles after".</summary>
public sealed record RetentionChoice(long Days, string Label)
{
    public override string ToString() => Label;
}

/// <summary>The words and sizes of the Storage tab, matching macOS (gui/Sources/Reader/StoragePane.swift).</summary>
public static class StorageText
{
    public const string DataDetail = "Feeds, articles and settings stay in one folder on this PC.";
    public const string CopiesDetail = "Up to 20 per feed, kept so a parser fix can replay them.";
    public const string LogsDetail = "The log is replaced each time the service starts.";
    public const string Measuring = "Measuring…";
    public const string FreeCopiesPrompt = "Keeps the newest copy of each feed and removes the rest.";
    public const string HomeOverridden = "FYKE_HOME names the data folder for this run, so it cannot be changed here.";

    public static readonly IReadOnlyList<RetentionChoice> RetentionChoices =
        [new(0, "Never"), new(30, "30 days"), new(90, "90 days"), new(365, "1 year")];

    /// <summary>The saved choice, or one made for a number of days set elsewhere.</summary>
    public static IReadOnlyList<RetentionChoice> RetentionChoicesWith(long days) =>
        RetentionChoices.Any(choice => choice.Days == days) || days < 0
            ? RetentionChoices
            : [.. RetentionChoices, new(days, BriefText.Count(days, "day"))];

    /// <summary>A size as Finder writes it: decimal units, whole kilobytes, one decimal for megabytes, two above.</summary>
    public static string Size(long bytes)
    {
        if (bytes <= 0)
        {
            return "0 KB";
        }

        if (bytes < 1000)
        {
            return BriefText.Count(bytes, "byte");
        }

        string[] units = ["KB", "MB", "GB", "TB"];
        var value = bytes / 1000.0;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1)
        {
            value /= 1000;
            unit++;
        }

        var digits = unit switch { 0 => 0, 1 => 1, _ => 2 };
        var number = Math.Round(value, digits).ToString("N" + digits.ToString(CultureInfo.InvariantCulture), CultureInfo.CurrentCulture);
        return $"{number} {units[unit]}";
    }

    public static string ArticlesDetail(ArticleUse articles)
    {
        ArgumentNullException.ThrowIfNull(articles);
        var text = string.Create(CultureInfo.CurrentCulture, $"{articles.Entries:N0} articles in {articles.Feeds:N0} feeds.");
        return articles.Removable > 0
            ? text + string.Create(CultureInfo.CurrentCulture, $" {articles.Removable:N0} were read over {Storage.TrimDays} days ago ({Size(articles.RemovableBytes)}).")
            : text;
    }

    public static string FreeArticlesPrompt(ArticleUse articles)
    {
        ArgumentNullException.ThrowIfNull(articles);
        return string.Create(CultureInfo.CurrentCulture,
            $"Removes the text of {articles.Removable:N0} articles read over {Storage.TrimDays} days ago. Titles, links and starred articles stay.");
    }

    public static string Copies(long files) => string.Create(CultureInfo.CurrentCulture, $"{files:N0} copies");

    /// <summary>"Checked just now" for a minute, then "Checked 5 minutes ago".</summary>
    public static string Checked(DateTimeOffset at, DateTimeOffset now) =>
        now - at < TimeSpan.FromMinutes(1) ? "Checked just now" : "Checked " + ActivityText.Ago(at, now);

    /// <summary>A path under the user's folder starts with ~, as macOS shows it.</summary>
    public static string Tilde(string path, string? userFolder)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (string.IsNullOrEmpty(userFolder))
        {
            return path;
        }

        var root = userFolder.TrimEnd('\\', '/');
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }

        // Only at a name boundary, so C:\Users\anabel is not inside C:\Users\ana.
        return path.Length == root.Length ? "~" : path[root.Length] is '\\' or '/' ? "~" + path[root.Length..] : path;
    }
}

/// <summary>Why a move may not be wise.</summary>
public enum DataMoveWarning
{
    None,

    /// <summary>The folder is on a removable or network drive, which may be missing when Fyke starts.</summary>
    External,

    /// <summary>The drive has less free space than the data and a margin.</summary>
    NoSpace,
}

/// <summary>A move of the data folder that a person has not yet agreed to.</summary>
public sealed record DataMovePlan(string Target, long Bytes, DataMoveWarning Warning)
{
    public bool CanMove => Warning != DataMoveWarning.NoSpace;
}

/// <summary>The drive a folder is on, as far as a move cares.</summary>
public sealed record DriveFacts(string Root, long? FreeBytes, bool External);

/// <summary>
/// Plans a move of the data folder and runs <c>fyke data move</c>, so that stopping the daemon,
/// copying, checking and restarting stay in the one place the terminal uses too (src/data_move.zig).
/// </summary>
public static class DataMoves
{
    /// <summary>The folder made inside a chosen folder that already holds something.</summary>
    public const string SubfolderName = "fyke_data";

    public const string MovedButNotRestarted = "Your data moved, but Fyke could not restart. Opening Fyke again usually fixes this.";

    private static readonly (string Name, string Words)[] Stages =
    [
        ("stopping", "Stopping…"),
        ("copying", "Moving…"),
        ("moving", "Moving…"),
        ("verifying", "Checking the copy…"),
        ("linking", "Linking…"),
        ("starting", "Restarting…"),
    ];

    // Only these can be caused by the person choosing a folder; the rest read as "Something went wrong".
    private static readonly (string Error, string Words)[] Failures =
    [
        ("TargetNotEmpty", "That folder is not empty."),
        ("TargetNotFolder", "That is a file, not a folder."),
        ("InsideCurrentFolder", "That folder is inside the one in use."),
        ("SameFolder", "That is the folder in use."),
        ("ParentMissing", "That folder's location does not exist."),
        ("PathTooLong", $"Windows limits the background service's address to {FykeHome.MaxSocketPathBytes} characters, and that folder's path is too long."),
        ("NoSpaceLeft", "There was not enough free space."),
        ("AccessDenied", "Windows did not allow Fyke to write there."),
        ("DaemonStillRunning", "Fyke could not stop its background service."),
        ("VerifyFailed", "The copy did not match, so nothing was changed."),
    ];

    /// <summary>
    /// The folder the data goes to: the chosen one when it is empty or missing, otherwise a
    /// <see cref="SubfolderName"/> folder inside it, so the data never mixes with other files.
    /// </summary>
    /// <returns>The target, or null with <paramref name="problem"/> set.</returns>
    public static string? Target(string chosen, out string? problem)
    {
        ArgumentException.ThrowIfNullOrEmpty(chosen);
        problem = null;
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(chosen));
        if (IsEmpty(full))
        {
            return full;
        }

        var inside = Path.Combine(full, SubfolderName);
        if (File.Exists(inside) || !IsEmpty(inside))
        {
            problem = $"That folder already holds a {SubfolderName} folder";
            return null;
        }

        return inside;
    }

    private static bool IsEmpty(string folder) => !Directory.Exists(folder) || !Directory.EnumerateFileSystemEntries(folder).Any();

    /// <summary>
    /// A move copies every file, even within one drive, so the target drive needs the data's size
    /// and a fifth more. A different drive that may be unplugged gets a warning.
    /// </summary>
    public static DataMoveWarning Warn(DriveFacts current, DriveFacts target, long bytes)
    {
        ArgumentNullException.ThrowIfNull(current);
        ArgumentNullException.ThrowIfNull(target);
        if (target.FreeBytes is { } free && free < bytes * 12 / 10)
        {
            return DataMoveWarning.NoSpace;
        }

        var sameDrive = string.Equals(current.Root, target.Root, StringComparison.OrdinalIgnoreCase);
        return !sameDrive && target.External ? DataMoveWarning.External : DataMoveWarning.None;
    }

    /// <summary>The drive under a folder, or a drive with nothing known about it.</summary>
    public static DriveFacts Drive(string path)
    {
        var root = Path.GetPathRoot(Path.GetFullPath(path)) ?? string.Empty;
        try
        {
            var drive = new DriveInfo(root);
            return new DriveFacts(root, drive.AvailableFreeSpace,
                drive.DriveType is DriveType.Removable or DriveType.Network or DriveType.CDRom);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return new DriveFacts(root, null, false);
        }
    }

    public static string WarningText(DataMoveWarning warning) => warning switch
    {
        DataMoveWarning.External => "This is a removable or network drive. If it is not connected, Fyke cannot start.",
        DataMoveWarning.NoSpace => "There is not enough free space there.",
        _ => string.Empty,
    };

    /// <summary>"12.3 MB moves to " before the folder, which is shown in the code face.</summary>
    public static string Summary(DataMovePlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        return StorageText.Size(plan.Bytes) + " moves to ";
    }

    public const string SummaryEnd = ". Fyke restarts when it is done.";

    /// <summary>What a line the command prints means, or null for a line that names no stage.</summary>
    public static string? Stage(string line)
    {
        var name = line.Trim();
        foreach (var (stage, words) in Stages)
        {
            if (name == stage)
            {
                return words;
            }
        }

        return null;
    }

    /// <summary>Why a move stopped, in words, from the command's output and errors.</summary>
    public static string Failure(string output, string errors)
    {
        // Past "starting" the data and the pointer are in place, and only the restart failed.
        if (output.Split('\n').Any(line => line.Trim() == "starting"))
        {
            return MovedButNotRestarted;
        }

        var reason = Failures.FirstOrDefault(failure => errors.Contains(failure.Error, StringComparison.Ordinal)).Words
            ?? "Something went wrong.";
        return reason + " Your data is where it was.";
    }

    /// <summary>The result of running the command.</summary>
    public sealed record Outcome(int ExitCode, string Output, string Errors)
    {
        public bool Succeeded => ExitCode == 0;
    }

    /// <summary>Runs <c>fyke data move</c> and reports each stage as it prints it, since a copy can take minutes.</summary>
    public static async Task<Outcome> RunAsync(string program, string target, Action<string> stage, CancellationToken ct)
    {
        ArgumentException.ThrowIfNullOrEmpty(program);
        ArgumentException.ThrowIfNullOrEmpty(target);
        ArgumentNullException.ThrowIfNull(stage);
        var start = new ProcessStartInfo(program)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        start.ArgumentList.Add("data");
        start.ArgumentList.Add("move");
        start.ArgumentList.Add(target);

        using var process = new Process { StartInfo = start };
        try
        {
            process.Start();
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return new Outcome(-1, string.Empty, e.Message);
        }

        var output = new StringBuilder();
        var reading = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                output.Append(line).Append('\n');
                if (Stage(line) is { } words)
                {
                    stage(words);
                }
            }
        }, CancellationToken.None);
        var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
        // A move stopped halfway is worse than a slow one, so cancelling only stops the wait.
        await process.WaitForExitAsync(ct).ConfigureAwait(false);
        await reading.ConfigureAwait(false);
        return new Outcome(process.ExitCode, output.ToString(), await errors.ConfigureAwait(false));
    }
}
