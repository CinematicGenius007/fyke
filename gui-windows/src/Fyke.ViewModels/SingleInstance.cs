using System.Security.Cryptography;
using System.Text;

namespace Fyke.ViewModels;

/// <summary>
/// One window per data folder. A second launch hands itself to the window already open,
/// as a second open of the Mac app does. A run with its own <c>FYKE_HOME</c> (the desktop
/// smoke test, a second profile) gets its own key, so it never lands in another run's window.
/// </summary>
public static class SingleInstance
{
    public const string DefaultKey = "Fyke";

    /// <summary>The instance key for a run whose <c>FYKE_HOME</c> is <paramref name="home"/>.</summary>
    public static string Key(string? home)
    {
        if (string.IsNullOrWhiteSpace(home))
        {
            return DefaultKey;
        }

        var folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home)).ToUpperInvariant();
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(folder));
        return $"{DefaultKey}-{Convert.ToHexString(hash, 0, 8)}";
    }
}
