using System;
using System.Collections.Generic;
using System.ComponentModel;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace Fyke.App;

/// <summary>The typefaces and corner radii on screen, as WinUI objects.</summary>
/// <remarks>
/// XAML reaches these through the <c>Font*</c> and <c>Radius*</c> ThemeResources, which
/// <see cref="MainWindow"/> replaces when the look changes. Elements built in code bind to
/// this one instance instead, as they do to <see cref="ReaderFontWeights"/>, so text already
/// on screen changes face with the theme. The generated property accessors keep those
/// bindings working when the app is trimmed.
/// </remarks>
[WinRT.GeneratedBindableCustomProperty]
public sealed partial class ReaderFaces : INotifyPropertyChanged
{
    // The fonts that ship in Fonts/, by family. Any other family is looked up in the system.
    private static readonly Dictionary<string, string> BundledFiles = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Newsreader"] = "Newsreader-Variable.ttf",
        ["Inter"] = "Inter-Variable.ttf",
        ["JetBrains Mono"] = "JetBrainsMono-Variable.ttf",
    };

    // Families the Mac bundles and Windows does not, with what stands in for them.
    private static readonly Dictionary<string, string> StandIns = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Source Serif 4"] = "Newsreader",
    };

    private readonly Dictionary<string, FontFamily> families = new(StringComparer.OrdinalIgnoreCase);

    private ReaderFaces() => Apply(ReaderLook.Default);

    public static ReaderFaces Shared { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    internal ReaderLook Look { get; private set; } = null!;
    public FontFamily Reading { get; private set; } = null!;
    public FontFamily Title { get; private set; } = null!;
    public FontFamily Ui { get; private set; } = null!;
    public FontFamily Code { get; private set; } = null!;
    public CornerRadius RadiusControl { get; private set; }
    public CornerRadius RadiusPanel { get; private set; }
    public CornerRadius RadiusSheet { get; private set; }

    /// <summary>Takes a new look. False when it is the one on screen.</summary>
    internal bool Apply(ReaderLook look)
    {
        if (look == Look)
        {
            return false;
        }

        Look = look;
        Reading = Family(look.Reading);
        Title = Family(look.Title);
        Ui = Family(look.Ui);
        Code = Family(look.Code);
        RadiusControl = new CornerRadius(look.RadiusControl);
        RadiusPanel = new CornerRadius(look.RadiusPanel);
        RadiusSheet = new CornerRadius(look.RadiusSheet);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        return true;
    }

    /// <summary>Binds an element's font to one of these faces, named by its property.</summary>
    internal T Bind<T>(T element, string face) where T : DependencyObject
    {
        var property = element switch
        {
            TextBlock => TextBlock.FontFamilyProperty,
            RichTextBlock => RichTextBlock.FontFamilyProperty,
            Control => Control.FontFamilyProperty,
            TextElement => TextElement.FontFamilyProperty,
            _ => throw new ArgumentException($"A {element.GetType().FullName} has no font.", nameof(element)),
        };
        Bind(element, property, face);
        return element;
    }

    /// <summary>Binds any property of an element to one of these, named by its property.</summary>
    internal void Bind(DependencyObject element, DependencyProperty property, string name) =>
        BindingOperations.SetBinding(element, property, new Binding { Source = this, Path = new PropertyPath(name) });

    /// <summary>Puts these into one of the token theme dictionaries, under the keys XAML uses.</summary>
    internal void WriteTo(ResourceDictionary tokens)
    {
        tokens["FontReading"] = Reading;
        tokens["FontTitle"] = Title;
        tokens["FontUi"] = Ui;
        tokens["FontCode"] = Code;
        tokens["RadiusControl"] = RadiusControl;
        tokens["RadiusPanel"] = RadiusPanel;
        tokens["RadiusSheet"] = RadiusSheet;
    }

    // One FontFamily per family, so that switching back and forth reuses the loaded font.
    private FontFamily Family(string name)
    {
        var family = StandIns.GetValueOrDefault(name, name);
        if (!families.TryGetValue(family, out var font))
        {
            font = BundledFiles.TryGetValue(family, out var file)
                ? new FontFamily($"ms-appx:///Fonts/{file}#{family}")
                : new FontFamily(family);
            families[family] = font;
        }

        return font;
    }
}
