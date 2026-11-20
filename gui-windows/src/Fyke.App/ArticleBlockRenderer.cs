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

namespace Fyke.App;

/// <summary>Turns the daemon's article nodes into native controls.</summary>
internal sealed class ArticleBlockRenderer(ReaderFaces faces,
    ReaderFontWeights weights, ReaderTextStyle textStyle, Func<Uri, Action?>? linkAction = null, bool trackImages = false)
{
    private readonly List<Action<bool>> imagePreferences = [];
    private bool loadImages;

    public void ResetImages() => imagePreferences.Clear();

    public void SetAutomaticImages(bool enabled)
    {
        if (loadImages == enabled)
        {
            return;
        }

        loadImages = enabled;
        foreach (var apply in imagePreferences)
        {
            apply(enabled);
        }
    }

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
                "quote" => Quote(node.Children ?? []),
                "list" => List(node),
                "table" => Table(node),
                "hr" => new Border { Style = Shared("ArticleRule") },
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

    private static Style Shared(string key) => AppResources.FromApp<Style>(key);

    private StackPanel Flow(IEnumerable<ArticleBlock> nodes)
    {
        var panel = new StackPanel { Spacing = 12 };
        Append(panel, nodes);
        return panel;
    }

    // A bar in the control colour, then the quoted blocks in the softer ink.
    private Grid Quote(IEnumerable<ArticleBlock> nodes)
    {
        var quote = new Grid { ColumnSpacing = 16 };
        quote.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        quote.ColumnDefinitions.Add(new ColumnDefinition());
        var body = new ContentPresenter { Style = Shared("ArticleQuoteBody"), Content = Flow(nodes) };
        Grid.SetColumn(body, 1);
        quote.Children.Add(new Border { Style = Shared("ArticleQuoteBar") });
        quote.Children.Add(body);
        return quote;
    }

    private TextBlock Text(IEnumerable<ArticleBlock> nodes, double? headingSize = null, bool compact = false)
    {
        var heading = headingSize.HasValue;
        // Headings are in the title face, as ReaderPane.swift sets them.
        var text = faces.Bind(new TextBlock
        {
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
        }, heading ? nameof(ReaderFaces.Title) : nameof(ReaderFaces.Reading));
        if (headingSize is double size)
        {
            text.FontSize = size;
        }
        else
        {
            textStyle.BindSize(text, compact);
            if (!compact)
            {
                textStyle.BindLineHeight(text);
            }
        }

        weights.Bind(text, TextBlock.FontWeightProperty, heading ? nameof(ReaderFontWeights.Title) : nameof(ReaderFontWeights.Reading));
        AppendInlines(text.Inlines, nodes, heading ? nameof(ReaderFontWeights.Title) : nameof(ReaderFontWeights.ReadingStrong));
        return text;
    }

    private void AppendInlines(InlineCollection target, IEnumerable<ArticleBlock> nodes,
        string emphasis, bool insideLink = false)
    {
        foreach (var node in nodes)
        {
            switch (node.Kind)
            {
                case "text":
                    target.Add(new Run { Text = node.Text ?? string.Empty });
                    break;
                case "code":
                    var run = faces.Bind(new Run { Text = node.Text ?? string.Empty }, nameof(ReaderFaces.Code));
                    weights.Bind(run, TextElement.FontWeightProperty, nameof(ReaderFontWeights.Code));
                    target.Add(run);
                    break;
                case "br":
                    target.Add(new LineBreak());
                    break;
                case "em":
                case "strong":
                    Span style = node.Kind == "em" ? new Italic() : new Span();
                    if (node.Kind == "strong")
                    {
                        weights.Bind(style, TextElement.FontWeightProperty, emphasis);
                    }
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
        var text = Text(node.Children ?? [], level <= 2 ? 27 : level == 3 ? 23 : 20);
        text.Margin = new Thickness(0, 8, 0, 0);
        return text;
    }

    // On a surface panel, scrolling sideways when a line is wider than the column.
    private Border Code(string? value)
    {
        var text = faces.Bind(new TextBlock
        {
            Text = value ?? string.Empty, FontSize = 14,
            LineHeight = 23, LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            IsTextSelectionEnabled = true, Margin = new Thickness(20, 16, 20, 16),
        }, nameof(ReaderFaces.Code));
        weights.Bind(text, TextBlock.FontWeightProperty, nameof(ReaderFontWeights.Code));
        return new Border
        {
            Style = Shared("ArticleCode"),
            Child = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                VerticalScrollMode = ScrollMode.Disabled,
                Content = text,
            },
        };
    }

    private StackPanel List(ArticleBlock node)
    {
        var list = new StackPanel { Spacing = 6 };
        var index = 0;
        foreach (var item in node.Items ?? [])
        {
            var row = new Grid { ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            // The marker shares the item text's font, size and line box, so both share a baseline.
            var marker = faces.Bind(new TextBlock
            {
                Text = node.Ordered == true ? (++index).ToString(CultureInfo.CurrentCulture) + "." : "•",
                Style = Shared("ArticleListMarker"),
            }, nameof(ReaderFaces.Reading));
            textStyle.BindSize(marker);
            textStyle.BindLineHeight(marker);
            weights.Bind(marker, TextBlock.FontWeightProperty, nameof(ReaderFontWeights.Reading));
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
                var cell = Text(rows[row][column].SelectMany(block => block.Kind == "p" ? block.Children ?? [] : [block]), compact: true);
                Grid.SetRow(cell, row);
                Grid.SetColumn(cell, column);
                table.Children.Add(cell);
            }
        }

        return table;
    }

    private HyperlinkButton? LinkBlock(string? value)
    {
        if (ArticleBlock.WebAddress(value) is not Uri address)
        {
            return null;
        }

        var link = faces.Bind(new HyperlinkButton { NavigateUri = address, Content = address.Host }, nameof(ReaderFaces.Ui));
        weights.Bind(link, Control.FontWeightProperty, nameof(ReaderFontWeights.Ui));
        return link;
    }

    private StackPanel? ImagePlaceholder(ArticleBlock node)
    {
        if (ArticleBlock.WebAddress(node.Src) is not Uri address)
        {
            return null;
        }

        var panel = new StackPanel { Spacing = 8 };
        var label = string.IsNullOrWhiteSpace(node.Alt) ? "Image" : node.Alt;
        // The description on the left and the action on the right, as on macOS.
        var description = new TextBlock { Text = label, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
        var action = new TextBlock { Style = Shared("ArticleImageAction"), Margin = new Thickness(12, 0, 0, 0) };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(action, 1);
        row.Children.Add(description);
        row.Children.Add(action);
        var button = faces.Bind(new Button { Style = Shared("ArticleImageLoad"), Content = row }, nameof(ReaderFaces.Ui));
        weights.Bind(button, Control.FontWeightProperty, nameof(ReaderFontWeights.Ui));
        Show("Load", $"Load image · {label}", isEnabled: true);
        var image = new Image { Visibility = Visibility.Collapsed, Stretch = Stretch.Uniform, MaxHeight = 720 };
        var requested = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(image, label);
        image.ImageOpened += (_, _) =>
        {
            if (image.Source is not null)
            {
                button.Visibility = Visibility.Collapsed;
            }
        };
        image.ImageFailed += (_, _) =>
        {
            if (image.Source is null)
            {
                return;
            }

            image.Source = null;
            image.Visibility = Visibility.Collapsed;
            Show("Try again", $"Image couldn’t load. Try again · {label}", isEnabled: true);
        };
        button.Click += (_, _) =>
        {
            requested = true;
            Load();
        };
        panel.Children.Add(button);
        panel.Children.Add(image);
        if (trackImages)
        {
            imagePreferences.Add(ApplyPreference);
            ApplyPreference(loadImages);
        }

        return panel;

        void Load()
        {
            Show("Loading…", $"Loading image · {label}", isEnabled: false);
            image.Visibility = Visibility.Visible;
            image.Source = new BitmapImage(address);
        }

        // The row shows the description and a short action; Narrator hears the whole state.
        void Show(string state, string spoken, bool isEnabled)
        {
            action.Text = state;
            button.IsEnabled = isEnabled;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, spoken);
        }

        void ApplyPreference(bool enabled)
        {
            if (requested)
            {
                return;
            }

            if (enabled)
            {
                Load();
            }
            else
            {
                image.Source = null;
                image.Visibility = Visibility.Collapsed;
                Show("Load", $"Load image · {label}", isEnabled: true);
                button.Visibility = Visibility.Visible;
            }
        }
    }
}
