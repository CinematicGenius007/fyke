using System;
using Microsoft.UI.Xaml;

namespace Fyke.App;

/// <summary>Typed lookups in the app's resources.</summary>
internal static class AppResources
{
    /// <summary>The resource with this key, as <typeparamref name="T"/>.</summary>
    /// <remarks>A missing key, or a value of another type, names both in the error, which a plain
    /// cast's "Specified cast is not valid" does not, so a crash report says which lookup failed.</remarks>
    public static T Get<T>(this ResourceDictionary resources, string key) =>
        resources.TryGetValue(key, out var value) && value is T typed
            ? typed
            : throw new InvalidOperationException(
                $"The resource '{key}' is {value?.GetType().FullName ?? "missing"}, not {typeof(T).FullName}.");

    /// <summary>A resource from App.xaml or the token dictionaries it merges.</summary>
    public static T FromApp<T>(string key) => Application.Current.Resources.Get<T>(key);
}
