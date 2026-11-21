using System;
using System.Collections.Generic;
using System.Globalization;
using Fyke.ViewModels;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Fyke.App;

public sealed partial class MainWindow
{
    private readonly Dictionary<Slider, (ReaderTextSetting Field, TextBlock Label)> textSliders = [];
    private Dictionary<ReaderTextSetting, double> pendingTextChanges = [];
    private DispatcherQueueTimer textSaveTimer = null!;

    private void InitializeTextLayoutSettings()
    {
        textSliders.Add(SettingsPane.TextSizeSlider, (ReaderTextSetting.Size, SettingsPane.TextSizeValue));
        textSliders.Add(SettingsPane.LineSpacingSlider, (ReaderTextSetting.LineSpacing, SettingsPane.LineSpacingValue));
        textSliders.Add(SettingsPane.ColumnWidthSlider, (ReaderTextSetting.ColumnWidth, SettingsPane.ColumnWidthValue));
        textSaveTimer = DispatcherQueue.CreateTimer();
        textSaveTimer.Interval = TimeSpan.FromMilliseconds(300);
        textSaveTimer.IsRepeating = false;
        textSaveTimer.Tick += (_, _) => FlushTextLayoutChanges();

        foreach (var (slider, spec) in textSliders)
        {
            var range = ReaderTextLayout.Range(spec.Field);
            slider.Maximum = range.Max;
            slider.Minimum = range.Min;
            slider.StepFrequency = slider.SmallChange = slider.LargeChange = range.Step;
        }

        ApplyTextLayoutControls(ReaderTextLayout.Default);
    }

    private void TextLayoutChanged(object sender, RangeBaseValueChangedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || preferences is not { InvalidConfig: false } saved
            || sender is not Slider slider || !textSliders.TryGetValue(slider, out var spec))
        {
            return;
        }

        var preview = readerTextStyle.Layout.With(spec.Field, args.NewValue);
        var value = preview.Get(spec.Field);
        ApplyReaderTextLayout(preview);
        spec.Label.Text = FormatTextSetting(spec.Field, value);
        if (value == saved.TextLayout.Get(spec.Field))
        {
            pendingTextChanges.Remove(spec.Field);
        }
        else
        {
            pendingTextChanges[spec.Field] = value;
        }

        textSaveTimer.Stop();
        if (pendingTextChanges.Count != 0)
        {
            textSaveTimer.Start();
        }
    }

    private void ApplyReaderTextLayout(ReaderTextLayout layout)
    {
        if (layout.ColumnWidth != readerTextStyle.Layout.ColumnWidth)
        {
            ArticleColumn.MaxWidth = layout.ColumnWidth;
        }

        readerTextStyle.Apply(layout);
    }

    private void ApplyTextLayoutControls(ReaderTextLayout layout)
    {
        foreach (var (slider, spec) in textSliders)
        {
            var value = layout.Get(spec.Field);
            slider.Value = value;
            spec.Label.Text = FormatTextSetting(spec.Field, value);
        }
    }

    private static string FormatTextSetting(ReaderTextSetting field, double value) =>
        value.ToString(field == ReaderTextSetting.LineSpacing ? "0.0" : "0", CultureInfo.CurrentCulture);

    private void FlushTextLayoutChanges()
    {
        if (pendingTextChanges.Count != 0)
        {
            _ = ReadSettingsAsync();
        }
    }
}
