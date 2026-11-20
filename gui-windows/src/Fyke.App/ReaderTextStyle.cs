using System;
using System.ComponentModel;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;

namespace Fyke.App;

/// <summary>Applies reader layout preferences to the current article and discussion controls.</summary>
/// <remarks>The generated property accessors keep these code bindings working when the app is trimmed.</remarks>
[WinRT.GeneratedBindableCustomProperty]
public sealed partial class ReaderTextStyle : INotifyPropertyChanged
{
    internal ReaderTextLayout Layout { get; private set; } = ReaderTextLayout.Default;

    public event PropertyChangedEventHandler? PropertyChanged;

    public double Size => Layout.Size;
    public double CompactSize => Layout.Size * 0.85;
    public double LineHeight => Layout.Size * Layout.LineSpacing;

    /// <summary>A brief's paragraphs follow the reading size up to 21, as on macOS.</summary>
    public double BriefSize => Math.Min(Layout.Size, 21);
    public double BriefLineHeight => Math.Round(BriefSize * Layout.LineSpacing);

    internal void Apply(ReaderTextLayout layout)
    {
        if (layout == Layout)
        {
            return;
        }

        var textChanged = layout.Size != Layout.Size || layout.LineSpacing != Layout.LineSpacing;
        Layout = layout;
        if (textChanged)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }

    internal void BindSize(TextBlock text, bool compact = false) =>
        text.SetBinding(TextBlock.FontSizeProperty, new Binding
        {
            Source = this, Path = new PropertyPath(compact ? nameof(CompactSize) : nameof(Size)),
        });

    internal void BindBrief(RichTextBlock text)
    {
        text.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        text.SetBinding(RichTextBlock.FontSizeProperty, new Binding { Source = this, Path = new PropertyPath(nameof(BriefSize)) });
        text.SetBinding(RichTextBlock.LineHeightProperty, new Binding { Source = this, Path = new PropertyPath(nameof(BriefLineHeight)) });
    }

    /// <summary>Gives every line the same height, so inline code cannot push a line down and a list
    /// marker with the same height sits on the first line's baseline.</summary>
    internal void BindLineHeight(TextBlock text)
    {
        text.LineStackingStrategy = LineStackingStrategy.BlockLineHeight;
        text.SetBinding(TextBlock.LineHeightProperty, new Binding { Source = this, Path = new PropertyPath(nameof(LineHeight)) });
    }
}
