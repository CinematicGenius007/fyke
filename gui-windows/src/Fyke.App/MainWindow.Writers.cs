using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Fyke.Client;
using Fyke.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using Windows.ApplicationModel.DataTransfer;

namespace Fyke.App;

/// <summary>
/// The Agents settings, as on macOS (gui/Sources/Reader/SettingsView.swift, AgentsPane): which
/// agent on this PC writes briefs, Claude Code's profile folder, and what agents connected over
/// MCP may change, with the configuration that connects them.
/// </summary>
public sealed partial class MainWindow
{
    private static readonly string[] AgentTierChoices = ["Never", "Reading state only", "Everything"];

    private Writers writers = null!;
    private IReadOnlyList<Writer> writerList = [];
    private bool writersUnavailable;
    private bool writersListed;
    private string? checkingWriter;

    /// <summary>The writer briefs use, by name, once the writers have been listed.</summary>
    private string? CurrentWriterName => Writers.Current(writerList)?.Name;

    private void InitializeWriters()
    {
        writers = new Writers(client);
        SettingsPane.WritersDetail.Text = WriterText.SectionDetail;
        SettingsPane.AgentsDetail.Text = WriterText.AgentsDetail;
        SettingsPane.AgentTierPicker.ItemsSource = AgentTierChoices;
        RenderWriters();
    }

    /// <summary>Opens Settings at the Agents tab, as Today's "Choose a writer" does.</summary>
    private void OpenAgentsSettings()
    {
        OpenSettings();
        if (IsSettingsOpen && SettingsPane.SettingsTabs.SelectedItem != SettingsPane.AgentsSettingsTab)
        {
            SettingsPane.SettingsTabs.SelectedItem = SettingsPane.AgentsSettingsTab;
        }
    }

    private async Task LoadWritersAsync()
    {
        try
        {
            writerList = await writers.ListAsync(lifetime.Token);
            writersUnavailable = false;
            writersListed = true;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (DaemonRpcException error) when (error.IsUnknownMethod)
        {
            writersUnavailable = true;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException or JsonException)
        {
            // The rows stay as they were; the next visit to the tab tries again.
        }

        RenderWriters();
        if (IsRecipeShown && recipeDraft.Recipe is { } recipe)
        {
            RecipeSubtitle.Text = RecipeText.Subtitle(recipe, CurrentWriterName, DateTimeOffset.Now);
        }
    }

    /// <summary>Lists the writers once per connection, so pages that name the writer can.</summary>
    private void ListWritersOnce()
    {
        if (!writersListed && !writersUnavailable)
        {
            writersListed = true;
            _ = LoadWritersAsync();
        }
    }

    private void RenderWriters()
    {
        SettingsPane.WriterRows.Children.Clear();
        SettingsPane.WritersEmpty.Text = writersUnavailable ? WriterText.NeedsNewerService : WriterText.Looking;
        SettingsPane.WritersEmpty.Visibility = writerList.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var writer in writerList)
        {
            if (SettingsPane.WriterRows.Children.Count > 0)
            {
                SettingsPane.WriterRows.Children.Add(new Border { Height = 1, Style = AppResources.FromApp<Style>("SettingsHairline") });
            }

            SettingsPane.WriterRows.Children.Add(WriterRow(writer));
            if (writer is { IsClaude: true, Installed: true })
            {
                SettingsPane.WriterRows.Children.Add(ProfileRow(writer));
            }
        }
    }

    private Grid WriterRow(Writer writer)
    {
        var row = new Grid { ColumnSpacing = 12, MinHeight = 56, Padding = new Thickness(0, 8, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        AutomationProperties.SetName(row, writer.Name);

        var badge = new Border
        {
            Style = AppResources.FromApp<Style>(writer.Available ? writer.Selected ? "WriterBadgeSelected" : "WriterBadgeFound" : "WriterBadge"),
            Child = new TextBlock { Text = writer.Badge, Style = AppResources.FromApp<Style>("WriterBadgeText") },
        };
        AutomationProperties.SetAccessibilityView(badge, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        row.Children.Add(badge);

        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = writer.Name, Style = SettingsStyle("SettingsLabel"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        words.Children.Add(new TextBlock
        {
            Text = WriterText.Status(writer),
            Style = string.IsNullOrWhiteSpace(writer.Problem) ? SettingsStyle("SettingsDetail") : AppResources.FromApp<Style>("WriterProblem"),
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(words, 1);
        row.Children.Add(words);

        FrameworkElement check = checkingWriter == writer.Id
            ? new ProgressRing { IsActive = true, Width = 16, Height = 16, Margin = new Thickness(16, 0, 16, 0) }
            : WriterButton("Check", "BriefQuietAction", $"Check {writer.Name} again", () => _ = CheckWriterAsync(writer));
        if (check is Button checkButton)
        {
            ToolTipService.SetToolTip(checkButton, $"Run {writer.Name}’s version check again");
            AutomationProperties.SetAutomationId(checkButton, $"CheckWriter_{writer.Id}");
        }

        check.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(check, 2);
        row.Children.Add(check);

        FrameworkElement choice;
        if (writer.Selected)
        {
            choice = new Border
            {
                Style = AppResources.FromApp<Style>("WriterDefaultTag"),
                Child = new TextBlock { Text = "Default", Style = AppResources.FromApp<Style>("WriterDefaultText") },
            };
        }
        else
        {
            var make = WriterButton("Make default", "BriefSecondaryAction", $"Make {writer.Name} the default", () => _ = ChooseWriterAsync(writer));
            make.IsEnabled = writer.Available && checkingWriter is null;
            AutomationProperties.SetAutomationId(make, $"ChooseWriter_{writer.Id}");
            choice = make;
        }

        choice.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(choice, 3);
        row.Children.Add(choice);
        return row;
    }

    /// <summary>
    /// Claude Code keeps one sign-in per profile folder, so the folder decides whose account writes
    /// the brief. It is indented under the Claude Code row it belongs to.
    /// </summary>
    private Grid ProfileRow(Writer writer)
    {
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(40, 0, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        AutomationProperties.SetName(row, "Claude Code profile folder");

        var words = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        words.Children.Add(new TextBlock { Text = "Profile folder", Style = SettingsStyle("SettingsLabel"), FontSize = 13 });
        var folder = new TextBlock
        {
            Text = WriterText.Profile(writer),
            Style = SettingsStyle("SettingsDetail"),
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        AutomationProperties.SetAutomationId(folder, "ClaudeProfile");
        words.Children.Add(folder);
        row.Children.Add(words);

        var busy = checkingWriter is not null;
        if (!string.IsNullOrWhiteSpace(writer.Profile))
        {
            var reset = WriterButton("Use default", "BriefQuietAction", "Use Claude Code’s default profile folder", () => _ = SetClaudeProfileAsync(string.Empty));
            reset.IsEnabled = !busy;
            reset.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(reset, 1);
            row.Children.Add(reset);
        }

        var choose = WriterButton("Choose…", "BriefSecondaryAction", "Choose Claude Code’s profile folder", () => _ = PickClaudeProfileAsync());
        choose.IsEnabled = !busy;
        choose.VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetToolTip(choose, "Choose the folder Claude Code keeps its sign-in in, such as ~\\.claude_personal");
        Grid.SetColumn(choose, 2);
        row.Children.Add(choose);
        return row;
    }

    private static Button WriterButton(string text, string style, string name, Action run)
    {
        var button = new Button { Content = text, Style = AppResources.FromApp<Style>(style) };
        AutomationProperties.SetName(button, name);
        button.Click += (_, _) => run();
        return button;
    }

    private Style SettingsStyle(string key) => (Style)SettingsPane.Resources[key];

    private async Task CheckWriterAsync(Writer writer)
    {
        if (checkingWriter is not null)
        {
            return;
        }

        checkingWriter = writer.Id;
        ShowWritersProblem(null);
        RenderWriters();
        try
        {
            await writers.CheckAsync(writer.Id, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowWritersProblem(WriterText.Problem(error));
        }
        finally
        {
            checkingWriter = null;
        }

        await LoadWritersAsync();
    }

    private async Task ChooseWriterAsync(Writer writer)
    {
        ShowWritersProblem(null);
        try
        {
            await writers.ChooseAsync(writer.Id, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowWritersProblem($"Could not make {writer.Name} the default: {WriterText.Problem(error)}");
        }

        await LoadWritersAsync();
    }

    private async Task PickClaudeProfileAsync()
    {
        // Claude Code profiles live in the home folder (~\.claude and the like), so the picker
        // opens there each time, as on macOS. SuggestedFolder needs Windows App SDK 2.
        var picker = new FolderPicker(AppWindow.Id)
        {
            CommitButtonText = "Use this folder",
            SuggestedFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        var picked = await picker.PickSingleFolderAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path) || lifetime.IsCancellationRequested)
        {
            return;
        }

        await SetClaudeProfileAsync(Path.GetFullPath(picked.Path));
    }

    private async Task SetClaudeProfileAsync(string path)
    {
        if (checkingWriter is not null)
        {
            return;
        }

        // The daemon checks Claude Code again with the new folder, which can take a while.
        checkingWriter = "claude";
        ShowWritersProblem(null);
        RenderWriters();
        try
        {
            await writers.SetClaudeProfileAsync(path, lifetime.Token);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error) when (error is DaemonException or TimeoutException)
        {
            ShowWritersProblem($"Could not use that folder: {WriterText.Problem(error)}");
        }
        finally
        {
            checkingWriter = null;
        }

        await LoadWritersAsync();
    }

    private void ShowWritersProblem(string? problem)
    {
        SettingsPane.WritersProblem.Text = problem ?? string.Empty;
        SettingsPane.WritersProblem.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ApplyAgentControls(ReaderPreferences loaded)
    {
        SettingsPane.AgentTierPicker.SelectedIndex = (int)loaded.AgentTier;
        SettingsPane.McpConfigText.Text = AgentAccess.McpConfig(McpProgram(), loaded.AgentTier);
    }

    /// <summary>The fyke program the app runs, which an agent starts with <c>mcp</c>.</summary>
    private static string McpProgram() =>
        new FykeProcessStarter().FindProgram() ?? Path.Combine(AppContext.BaseDirectory, "fyke.exe");

    private void AgentTierChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!IsSettingsOpen || readingSettings || SettingsPane.AgentTierPicker.SelectedIndex < 0
            || preferences is not { InvalidConfig: false } saved)
        {
            return;
        }

        var tier = (AgentTier)SettingsPane.AgentTierPicker.SelectedIndex;
        if (saved.AgentTier != tier)
        {
            _ = ReadSettingsAsync(ct => writers.SetAgentTierAsync(tier, ct), current => current.AgentTier == tier);
        }
    }

    private void CopyMcpConfigClicked(object sender, RoutedEventArgs args)
    {
        var package = new DataPackage();
        package.SetText(SettingsPane.McpConfigText.Text);
        Clipboard.SetContent(package);
        SettingsPane.CopyMcpConfig.Content = "Copied";
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => SettingsPane.CopyMcpConfig.Content = "Copy MCP config";
        timer.Start();
    }
}
