using System.ComponentModel;
using Fyke.ViewModels;
using Windows.UI.Text;

namespace Fyke.App;

/// <summary>Exposes the profile's typography in the font-weight type used by WinUI.</summary>
public sealed class ReaderFontWeights : INotifyPropertyChanged
{
    private ReaderTypography typography;

    public event PropertyChangedEventHandler? PropertyChanged;

    public FontWeight Reading => Weight(ReaderTypography.Regular, typography.Reading);
    public FontWeight ReadingStrong => Weight(ReaderTypography.Semibold, typography.Reading);
    public FontWeight Title => Weight(ReaderTypography.Semibold, typography.Title);
    public FontWeight TimelineTitle => Weight(ReaderTypography.Medium, typography.Title);
    public FontWeight Ui => Weight(ReaderTypography.Regular, typography.Ui);
    public FontWeight SectionLabel => Weight(ReaderTypography.Semibold, typography.Ui);
    public FontWeight Code => Weight(ReaderTypography.Regular, typography.Code);

    internal void Apply(ReaderTypography preferences)
    {
        if (preferences == typography)
        {
            return;
        }

        typography = preferences;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }

    private static FontWeight Weight(ushort baseline, int step) =>
        new() { Weight = ReaderTypography.Shift(baseline, step) };
}
