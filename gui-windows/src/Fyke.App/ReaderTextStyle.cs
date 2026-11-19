using System.ComponentModel;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;

namespace Fyke.App;

/// <summary>Applies reader layout preferences to the current article and discussion controls.</summary>
public sealed class ReaderTextStyle : INotifyPropertyChanged
{
    internal ReaderTextLayout Layout { get; private set; } = ReaderTextLayout.Default;

    public event PropertyChangedEventHandler? PropertyChanged;

    public double Size => Layout.Size;
    public double CompactSize => Layout.Size * 0.85;
    public double LineHeight => Layout.Size * Layout.LineSpacing;

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

    internal void BindLineHeight(TextBlock text) =>
        text.SetBinding(TextBlock.LineHeightProperty, new Binding { Source = this, Path = new PropertyPath(nameof(LineHeight)) });
}
