using System.Diagnostics;

namespace Fyke.Client;

/// <summary>Starts <c>fyke daemon</c>. Tests replace it.</summary>
public interface IDaemonProcessStarter
{
    /// <summary>
    /// Starts a daemon on <paramref name="dataFolder"/> and returns without waiting for it to
    /// listen. The daemon's lock keeps a second copy from starting, so calling this twice is safe.
    /// </summary>
    Task StartAsync(string dataFolder, CancellationToken ct);
}

/// <summary>
/// Starts the real program, without a console window: <c>fyke daemon --log --home DIR</c>.
/// The program is <c>FYKE_BIN</c>, or <c>fyke</c> beside the app, or <c>fyke</c> on <c>PATH</c>.
/// </summary>
public sealed class FykeProcessStarter : IDaemonProcessStarter
{
    private readonly string? _program;
    private readonly Func<string, string?> _environment;
    private readonly string _appFolder;

    public FykeProcessStarter(string? program = null, Func<string, string?>? environment = null, string? appFolder = null)
    {
        _program = program;
        _environment = environment ?? Environment.GetEnvironmentVariable;
        _appFolder = appFolder ?? AppContext.BaseDirectory;
    }

    /// <summary>Where the program is, or null.</summary>
    public string? FindProgram()
    {
        if (_program is not null)
        {
            return File.Exists(_program) ? _program : null;
        }

        var fromEnvironment = _environment("FYKE_BIN");
        if (!string.IsNullOrEmpty(fromEnvironment))
        {
            return File.Exists(fromEnvironment) ? fromEnvironment : null;
        }

        var name = OperatingSystem.IsWindows() ? "fyke.exe" : "fyke";
        var beside = Path.Combine(_appFolder, name);
        if (File.Exists(beside))
        {
            return beside;
        }

        foreach (var folder in (_environment("PATH") ?? string.Empty).Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(folder.Trim('"'), name);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return null;
    }

    public Task StartAsync(string dataFolder, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var program = FindProgram() ?? throw new DaemonProgramNotFoundException("Cannot find the fyke program.");
        Directory.CreateDirectory(dataFolder);
        var info = new ProcessStartInfo(program)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        info.ArgumentList.Add("daemon");
        info.ArgumentList.Add("--log");
        info.ArgumentList.Add("--home");
        info.ArgumentList.Add(dataFolder);

        // The daemon outlives this process's interest in it, so the handle is dropped at once.
        using var process = Process.Start(info);
        return Task.CompletedTask;
    }
}
