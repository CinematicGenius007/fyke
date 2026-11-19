using System.Collections.Generic;
using System.Collections.ObjectModel;
using Fyke.App;
using Fyke.ViewModels;
using WinRT;

// Every collection the app hands to an ItemsSource. Native AOT has no reflection to build their
// WinRT interfaces at run time, so CsWinRT generates them here; without one, setting ItemsSource
// fails with "Value does not fall within the expected range". Add a line for each new list type.
[assembly: GeneratedWinRTExposedExternalType(typeof(ObservableCollection<TimelineArticle>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(ObservableCollection<ReaderDestination>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(ObservableCollection<PaletteResult>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(ObservableCollection<DiscussionRow>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(List<FolderChoice>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(List<ViewEditor.Source>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(FeedCandidate[]))]
[assembly: GeneratedWinRTExposedExternalType(typeof(SearchHit[]))]
[assembly: GeneratedWinRTExposedExternalType(typeof(string[]))]
