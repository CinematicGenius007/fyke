using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI.Text;

namespace Fyke.App;

/// <summary>Turns the daemon's article nodes into native controls. Images load only on request.</summary>
internal sealed class ArticleBlockRenderer(FontFamily reading, FontFamily ui, FontFamily code,
    ReaderFontWeights weights, double textSize = 20, Func<Uri, Action?>? linkAction = null)
{
    public void Append(StackPanel panel, IEnumerable<ArticleBlock> nodes)
    {
        var inline = new List<ArticleBlock>();
        foreach (var node in nodes)
        {
            if (node.Kind is "text" or "em" or "strong" or "link" or "br")
            {
                inline.Add(node);
                continue;
            }

            Flush();
            var control = node.Kind switch
            {
                "p" => Text(node.Children ?? []),
                "h" => Heading(node),
                "code" => Code(node.Text),
                "quote" => Flow(node.Children ?? [], new Thickness(16, 0, 0, 0)),
                "list" => List(node),
                "table" => Table(node),
                "hr" => new Border { Style = (Style)Application.Current.Resources["ArticleRule"] },
                "img" => ImagePlaceholder(node),
                "embed" => LinkBlock(node.Href),
                _ => (UIElement?)null,
            };
            if (control is not null)
            {
                panel.Children.Add(control);
            }
        }

        Flush();

        void Flush()
        {
            if (inline.Count == 0)
            {
                return;
            }

            panel.Children.Add(Text(inline));
            inline.Clear();
        }
    }

    private StackPanel Flow(IEnumerable<ArticleBlock> nodes, Thickness margin = default)
    {
        var panel = new StackPanel { Spacing = 12, Margin = margin };
        Append(panel, nodes);
        return panel;
    }

    private TextBlock Text(IEnumerable<ArticleBlock> nodes, double? size = null, bool heading = false)
    {
        var text = new TextBlock
        {
            FontFamily = reading,
            FontSize = size ?? textSize,
            FontWeight = heading ? weights.Title : weights.Reading,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        };
        AppendInlines(text.Inlines, nodes, heading ? weights.Title : weights.ReadingStrong);
        return text;
    }

    private void AppendInlines(InlineCollection target, IEnumerable<ArticleBlock> nodes,
        FontWeight emphasis, bool insideLink = false)
    {
        foreach (var node in nodes)
        {
            switch (node.Kind)
            {
                case "text":
                    target.Add(new Run { Text = node.Text ?? string.Empty });
                    break;
                case "code":
                    target.Add(new Run { Text = node.Text ?? string.Empty, FontFamily = code, FontWeight = weights.Code });
                    break;
                case "br":
                    target.Add(new LineBreak());
                    break;
                case "em":
                case "strong":
                    Span style = node.Kind == "em" ? new Italic() : new Span { FontWeight = emphasis };
                    AppendInlines(style.Inlines, node.Children ?? [], emphasis, insideLink);
                    target.Add(style);
                    break;
                case "link":
                    if (!insideLink && ArticleBlock.WebAddress(node.Href) is Uri address)
                    {
                        var link = new Hyperlink();
                        if (linkAction?.Invoke(address) is Action open)
                        {
                            link.Click += (_, _) => open();
                        }
                        else
                        {
                            link.NavigateUri = address;
                        }
                        AppendInlines(link.Inlines, node.Children ?? [], emphasis, insideLink: true);
                        target.Add(link);
                    }
                    else
                    {
                        AppendInlines(target, node.Children ?? [], emphasis, insideLink);
                    }
                    break;
            }
        }
    }

    private TextBlock Heading(ArticleBlock node)
    {
        var level = node.Level ?? 2;
        var text = Text(node.Children ?? [], level <= 2 ? 27 : level == 3 ? 23 : 20, heading: true);
        text.Margin = new Thickness(0, 8, 0, 0);
        return text;
    }

    private ScrollViewer Code(string? value)
    {
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = new TextBlock
            {
                Text = value ?? string.Empty, FontFamily = code, FontSize = 14, FontWeight = weights.Code,
                IsTextSelectionEnabled = true, Margin = new Thickness(16, 12, 16, 12),
            },
        };
    }

    private StackPanel List(ArticleBlock node)
    {
        var list = new StackPanel { Spacing = 8 };
        var index = 0;
        foreach (var item in node.Items ?? [])
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            var marker = new TextBlock
            {
                Text = node.Ordered == true ? (++index).ToString(CultureInfo.CurrentCulture) + "." : "•",
                FontFamily = reading, FontSize = textSize, FontWeight = weights.Reading,
            };
            var content = Flow(item);
            Grid.SetColumn(content, 1);
            row.Children.Add(marker);
            row.Children.Add(content);
            list.Children.Add(row);
        }

        return list;
    }

    private Grid Table(ArticleBlock node)
    {
        var table = new Grid { RowSpacing = 8, ColumnSpacing = 16 };
        var rows = node.Rows ?? [];
        var columns = rows.Length == 0 ? 0 : rows.Max(row => row.Length);
        for (var column = 0; column < columns; column++)
        {
            table.ColumnDefinitions.Add(new ColumnDefinition());
        }

        for (var row = 0; row < rows.Length; row++)
        {
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            for (var column = 0; column < rows[row].Length; column++)
            {
                var cell = Text(rows[row][column].SelectMany(block => block.Kind == "p" ? block.Children ?? [] : [block]), 17);
                Grid.SetRow(cell, row);
                Grid.SetColumn(cell, column);
                table.Children.Add(cell);
            }
        }

        return table;
    }

    private HyperlinkButton? LinkBlock(string? value) => ArticleBlock.WebAddress(value) is Uri address
        ? new HyperlinkButton { NavigateUri = address, Content = address.Host, FontFamily = ui, FontWeight = weights.Ui }
        : null;

    private StackPanel? ImagePlaceholder(ArticleBlock node)
    {
        if (ArticleBlock.WebAddress(node.Src) is not Uri address)
        {
            return null;
        }

        var panel = new StackPanel { Spacing = 8 };
        var label = string.IsNullOrWhiteSpace(node.Alt) ? "Image" : node.Alt;
        var button = new Button { Content = $"Load image · {label}", FontFamily = ui, FontWeight = weights.Ui, Height = 32 };
        var image = new Image { Visibility = Visibility.Collapsed, Stretch = Stretch.Uniform, MaxHeight = 720 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(image, label);
        image.ImageOpened += (_, _) => button.Visibility = Visibility.Collapsed;
        image.ImageFailed += (_, _) =>
        {
            image.Source = null;
            image.Visibility = Visibility.Collapsed;
            button.Content = "Image couldn’t load. Try again";
            button.IsEnabled = true;
        };
        button.Click += (_, _) =>
        {
            button.Content = "Loading image…";
            button.IsEnabled = false;
            image.Visibility = Visibility.Visible;
            image.Source = new BitmapImage(address);
        };
        panel.Children.Add(button);
        panel.Children.Add(image);
        return panel;
    }
}
