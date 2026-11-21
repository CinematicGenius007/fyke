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
    // The fonts that ship in Fonts/, by family, as the Mac bundles them. Any other family is
    // looked up in the system. A font file is a collection of its own, so a family's italic
    // is reached through its own file; without one, WinUI slants the upright.
    private static readonly Dictionary<string, (string Upright, string? Italic)> BundledFiles = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Newsreader"] = ("Newsreader-Variable.ttf", "Newsreader-Italic-Variable.ttf"),
        ["Source Serif 4"] = ("SourceSerif4-Variable.ttf", "SourceSerif4-Italic-Variable.ttf"),
        ["Inter"] = ("Inter-Variable.ttf", null),
        ["JetBrains Mono"] = ("JetBrainsMono-Variable.ttf", "JetBrainsMono-Italic-Variable.ttf"),
    };

    private readonly Dictionary<(string Family, bool Italic), FontFamily> families = new();

    private ReaderFaces() => Apply(ReaderLook.Default);

    public static ReaderFaces Shared { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    internal ReaderLook Look { get; private set; } = null!;
    public FontFamily Reading { get; private set; } = null!;
    public FontFamily Title { get; private set; } = null!;
    /// <summary>The reading face's italic, for emphasis in articles and briefs.</summary>
    public FontFamily ReadingItalic { get; private set; } = null!;
    /// <summary>The title face's italic, for emphasis in headings.</summary>
    public FontFamily TitleItalic { get; private set; } = null!;
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
        ReadingItalic = Family(look.Reading, italic: true);
        TitleItalic = Family(look.Title, italic: true);
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

    // One FontFamily per family and style, so that switching back and forth reuses the
    // loaded font. A system family keeps its own italic, so it needs no second entry.
    private FontFamily Family(string name, bool italic = false)
    {
        var bundled = BundledFiles.TryGetValue(name, out var files);
        var file = italic && files.Italic is string italicFile ? italicFile : files.Upright;
        var key = (name, bundled && file == files.Italic);
        if (!families.TryGetValue(key, out var font))
        {
            font = bundled ? new FontFamily($"ms-appx:///Fonts/{file}#{name}") : new FontFamily(name);
            families[key] = font;
        }

        return font;
    }
}
