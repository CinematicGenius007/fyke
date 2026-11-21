using System.Diagnostics;
using System.Text;

namespace Fyke.ViewModels;

/// <summary>
/// General's "Keep updating in the background": the daemon started at sign-in through
/// <c>fyke service</c>, which on Windows writes the per-user Run key and runs the daemon
/// under its supervisor (docs/windows-gui.md, "Background service"). The installer's
/// startup task writes the same entry, so the switch and the installer agree.
/// </summary>
/// <remarks>
/// Asking <c>fyke service status</c> keeps one source of truth for where the entry lives.
/// Turning it on or off restarts the daemon, and the window reconnects as after any restart.
/// </remarks>
public sealed class BackgroundUpdates(string program, BackgroundUpdates.Runner? run = null)
{
    /// <summary>Runs the program with its arguments and returns its exit code and output.</summary>
    public delegate Task<(int Code, string Output)> Runner(string program, IReadOnlyList<string> arguments, CancellationToken ct);

    private readonly Runner run = run ?? RunProcessAsync;

    /// <summary>Whether the daemon starts at sign-in. Null when <c>fyke</c> could not tell.</summary>
    public async Task<bool?> IsOnAsync(CancellationToken ct)
    {
        var (code, output) = await run(program, ["service", "status"], ct).ConfigureAwait(false);
        return code == 0 ? ParseStatus(output) : null;
    }

    /// <summary>Turns it on or off. Returns why it failed, or null.</summary>
    public async Task<string?> SetAsync(bool on, CancellationToken ct)
    {
        var (code, output) = await run(program, ["service", on ? "install" : "uninstall"], ct).ConfigureAwait(false);
        if (code == 0)
        {
            return null;
        }

        var reason = output.Trim();
        return on
            ? $"Fyke couldn’t start updating in the background.{(reason.Length > 0 ? " " + reason : string.Empty)}"
            : $"Fyke couldn’t stop updating in the background.{(reason.Length > 0 ? " " + reason : string.Empty)}";
    }

    /// <summary>Reads <c>fyke service status</c>: "installed" or "not installed".</summary>
    public static bool? ParseStatus(string output) => output.Trim() switch
    {
        "installed" => true,
        "not installed" => false,
        _ => null,
    };

    private static async Task<(int Code, string Output)> RunProcessAsync(string program, IReadOnlyList<string> arguments, CancellationToken ct)
    {
        var start = new ProcessStartInfo(program)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = start };
        try
        {
            process.Start();
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return (-1, e.Message);
        }

        var output = process.StandardOutput.ReadToEndAsync(ct);
        var error = process.StandardError.ReadToEndAsync(ct);
        await process.WaitForExitAsync(ct).ConfigureAwait(false);
        return (process.ExitCode, process.ExitCode == 0 ? await output.ConfigureAwait(false) : await error.ConfigureAwait(false));
    }
}
