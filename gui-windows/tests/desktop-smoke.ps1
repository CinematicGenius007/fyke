param(
    [Parameter(Mandatory)][string]$App,
    [Parameter(Mandatory)][string]$Daemon,
    [Parameter(Mandatory)][string]$FeedUrl
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$appPath = (Resolve-Path $App).Path
$daemonPath = (Resolve-Path $Daemon).Path
$previousHome = $env:FYKE_HOME
$previousBin = $env:FYKE_BIN
$previousHeadless = $env:FYKE_HEADLESS
$testHome = Join-Path ([IO.Path]::GetTempPath()) ('fyke ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$env:FYKE_HOME = $testHome
# Routine notifications must not reach the notification centre of whoever runs this.
$env:FYKE_HEADLESS = '1'
$companion = Join-Path (Split-Path $appPath) 'fyke.exe'
if (Test-Path $companion) { throw "Use a fresh app build without a bundled daemon: $companion" }
$window = $null
$appErrors = $null
$copied = $false

function Wait-For([string]$Description, [scriptblock]$Probe) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $window.Refresh()
        if ($window.HasExited) { throw "Fyke exited with code $($window.ExitCode) while waiting for $Description" }
        $result = & $Probe
        if ($result) { return $result }
        Start-Sleep -Milliseconds 200
    } while ($timer.Elapsed.TotalSeconds -lt 30)
    throw "Timed out waiting for $Description"
}

try {
    [IO.Directory]::CreateDirectory($testHome) | Out-Null
    [IO.File]::WriteAllText((Join-Path $testHome 'config.json'),
        '{"ui":{"weights":{"reading":1,"title":2,"ui":-1,"code":-2}}}')

    # Start the GUI with its normal companion lookup. Its first attempt fails because the
    # companion is absent. PATH is removed only for the child so a host install cannot mask it.
    $env:FYKE_BIN = $null
    $start = [Diagnostics.ProcessStartInfo]::new($appPath)
    $start.UseShellExecute = $false
    $start.RedirectStandardError = $true
    $start.Environment.Remove('PATH') | Out-Null
    $launchTime = Get-Date
    $window = [Diagnostics.Process]::Start($start)
    $appErrors = $window.StandardError.ReadToEndAsync()
    $handle = Wait-For 'the main window' { if ($window.MainWindowHandle -ne [IntPtr]::Zero) { $window.MainWindowHandle } }
    $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
    $retryCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ConnectionRetry')
    $retry = Wait-For 'the missing-daemon Retry button' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $retryCondition)
        if ($element -and $element.Current.IsEnabled -and !$element.Current.IsOffscreen) { $element }
    }

    Copy-Item $daemonPath $companion
    $copied = $true
    $retry.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $messageCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ConnectionMessage')
    Wait-For 'the daemon socket and a completed handshake' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $messageCondition)
        if ((Test-Path (Join-Path $testHome 'fyked.sock')) -and (!$element -or $element.Current.IsOffscreen)) { $true }
    } | Out-Null

    function Get-CompanionProcess {
        Get-CimInstance Win32_Process -Filter "Name = 'fyke.exe' AND ParentProcessId = $($window.Id)" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($testHome) }
    }

    $original = Wait-For 'the companion process' { Get-CompanionProcess | Select-Object -First 1 }
    Stop-Process -Id $original.ProcessId -Force
    Wait-For 'a replacement companion started by the window' {
        Get-CompanionProcess | Where-Object { $_.ProcessId -ne $original.ProcessId } | Select-Object -First 1
    } | Out-Null
    Wait-For 'a reconnected window' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $messageCondition)
        if (!$element -or $element.Current.IsOffscreen) { $true }
    } | Out-Null

    $destinationsId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ReaderDestinations')
    $items = Wait-For 'the reader destinations' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $destinationsId)
    }

    function Find-ByName($parent, [string]$name) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty, $name)
        $parent.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    }

    function Select-ReaderItem($list, [string]$name) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty, $name)
        $unreadName = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty, "$name, unread")
        $rowName = [Windows.Automation.OrCondition]::new($condition, $unreadName)
        $item = Wait-For "the $name row" {
            $list.FindFirst([Windows.Automation.TreeScope]::Descendants, $rowName)
        }
        $selection = $null
        while ($item -and !$item.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selection)) {
            $item = [Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($item)
        }
        if (!$selection) { throw "The $name row does not expose selection." }
        $selection.Select()
    }

    Select-ReaderItem $items 'Starred'
    $headingId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'TimelineHeading')
    Wait-For 'the Starred timeline heading' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Starred') { $true }
    } | Out-Null

    # Today lists briefs in place of articles. A new profile has none, so it says so and runs no writer.
    # The state is a panel, which UI Automation does not list, so the probe finds its title.
    Select-ReaderItem $items 'Today'
    Wait-For 'the empty Today state' {
        $title = Find-ByName $root 'No brief yet'
        if ($title -and !$title.Current.IsOffscreen) { $true }
    } | Out-Null
    # The Recipe button opens the built-in recipe in place of the brief, and Back closes it.
    $recipeButton = Wait-For 'the Today recipe button' {
        $button = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'TodayRecipeButton'))
        if ($button -and $button.Current.IsEnabled) { $button }
    }
    $recipeButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $recipeEditor = Wait-For 'the recipe editor' {
        $editor = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'RecipeEditor'))
        if ($editor -and !$editor.Current.IsOffscreen) { $editor }
    }
    $recipeText = $recipeEditor.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ([string]::IsNullOrWhiteSpace($recipeText)) { throw 'The recipe editor opened without the recipe text' }
    $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'RecipeBack')
    ).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the recipe to close' {
        $title = Find-ByName $root 'No brief yet'
        if ($title -and !$title.Current.IsOffscreen) { $true }
    } | Out-Null
    Select-ReaderItem $items 'Starred'
    Wait-For 'the Starred timeline after Today' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        $title = Find-ByName $root 'No brief yet'
        if ($heading -and $heading.Current.Name -eq 'Starred' -and (!$title -or $title.Current.IsOffscreen)) { $true }
    } | Out-Null

    # Catch up over an empty Starred says there is nothing unread, and Done closes it.
    $catchUpButton = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'CatchUpButton'))
    if (!$catchUpButton) { throw 'The Catch up button was not found' }
    $catchUpButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the empty Catch up state' {
        $title = Find-ByName $root 'Nothing unread here'
        if ($title -and !$title.Current.IsOffscreen) { $true }
    } | Out-Null
    $catchUpDone = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'CatchUpDone'))
    $catchUpDone.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'Catch up to close' {
        $title = Find-ByName $root 'Nothing unread here'
        if (!$title -or $title.Current.IsOffscreen) { $true }
    } | Out-Null

    $opml = Join-Path $testHome 'fixture.opml'
    $urlAttribute = [Security.SecurityElement]::Escape($FeedUrl)
    # A feed whose address answers 404, so Activity and the sidebar have a failing feed to show.
    $brokenAttribute = [Security.SecurityElement]::Escape([Uri]::new([Uri]$FeedUrl, '/broken-feed').AbsoluteUri)
    [IO.File]::WriteAllText($opml, @"
<opml version="2.0"><body><outline text="Fixture folder">
<outline type="rss" text="Desktop fixture" xmlUrl="$urlAttribute"/>
</outline>
<outline type="rss" text="Broken fixture" xmlUrl="$brokenAttribute"/>
</body></opml>
"@)
    & $daemonPath import $opml --allow-private
    if ($LASTEXITCODE -ne 0) { throw 'Could not import the reader fixture feed' }
    Select-ReaderItem $items 'Desktop fixture'
    $timelineId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ReaderTimeline')
    $timeline = Wait-For 'the reader timeline' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $timelineId)
    }
    Select-ReaderItem $timeline 'Native reader fixture'
    $paragraph = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, 'The story is rendered from stored blocks.')
    $bodyText = Wait-For 'the article paragraph' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)
    }
    $articleHeadingId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ArticleHeading')
    $articleHeading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $articleHeadingId)

    function Assert-TextWeight($element, [int]$expected, [string]$description) {
        $pattern = $element.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $weight = $pattern.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontWeightAttribute)
        if ($weight -ne $expected) {
            throw "Expected weight $expected for ${description}. UI Automation reported $weight."
        }
    }

    Assert-TextWeight $bodyText 500 'the article body'
    Assert-TextWeight $articleHeading 800 'the article heading'
    $bodyRange = $bodyText.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange
    $originalBodySize = $bodyRange.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
    $imageButton = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, ("Load image " + [char]0x00b7 + " Fixture illustration"))
    Wait-For 'the image load control' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $imageButton)
    } | Out-Null

    function Find-ById([string]$id) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    }

    function Invoke-Button([string]$id) {
        $button = Wait-For "$id to be available" {
            $control = Find-ById $id
            if ($control -and $control.Current.IsEnabled -and !$control.Current.IsOffscreen) { $control }
        }
        $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }

    function Toggle-Setting([string]$id) {
        $toggle = Wait-For "$id to be ready" {
            $control = Find-ById $id
            if ($control -and $control.Current.IsEnabled -and !$control.Current.IsOffscreen) { $control }
        }
        $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    }

    function Read-ReaderConfig([string]$path) {
        # The daemon saves by rename, which must remain possible while the test reads the file.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $reader = [IO.StreamReader]::new($stream)
            try { $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    }

    $configPath = Join-Path $testHome 'config.json'
    Invoke-Button 'SettingsButton'
    Wait-For 'Settings to cover the article' {
        $close = Find-ById 'CloseSettingsButton'
        $coveredHeading = Find-ById 'ArticleHeading'
        if ($close -and !$close.Current.IsOffscreen -and (!$coveredHeading -or $coveredHeading.Current.IsOffscreen)) { $true }
    } | Out-Null
    Toggle-Setting 'FullTextToggle'
    Wait-For 'the changed full-text setting' {
        $config = Read-ReaderConfig $configPath
        if ($config.full_text -eq $false -and $config.ui.weights.title -eq 2) { $true }
    } | Out-Null
    Toggle-Setting 'FullTextToggle'
    Wait-For 'the restored full-text setting' {
        if ((Read-ReaderConfig $configPath).full_text -eq $true) { $true }
    } | Out-Null

    Invoke-WebRequest -Uri ([Uri]::new([Uri]$FeedUrl, '/enable-automatic-images')) -Method Post -UseBasicParsing | Out-Null
    Toggle-Setting 'LoadImagesToggle'
    Wait-For 'automatic images to be saved with existing preferences' {
        $config = Read-ReaderConfig $configPath
        if ($config.ui.loadImages -eq $true -and $config.ui.weights.title -eq 2) { $true }
    } | Out-Null

    $readingTab = Wait-For 'the Reading settings tab' { Find-ById 'ReadingSettingsTab' }
    $readingTab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    function Select-SettingsOption([string]$id, [string]$name) {
        $picker = Wait-For "$id to be enabled and visible" {
            $control = Find-ById $id
            if ($control -and $control.Current.IsEnabled -and !$control.Current.IsOffscreen) { $control }
        }
        $picker.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $selection = Wait-For "the enabled $name option in $id" {
            $option = Find-ByName $picker $name
            $pattern = $null
            if ($option -and $option.Current.IsEnabled -and !$option.Current.IsOffscreen -and
                $option.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern }
        }
        $selection.Select()
    }
    Select-SettingsOption 'ThemePicker' 'Dark'
    Wait-For 'Dark to persist as the fixed theme' {
        $ui = (Read-ReaderConfig $configPath).ui
        if ($ui.theme -eq 'dark' -and $ui.followSystem -eq $false -and $ui.weights.title -eq 2) { $true }
    } | Out-Null
    Select-SettingsOption 'ReadingWeightPicker' 'Much lighter'
    Wait-For 'the changed Reading weight to preserve the other font roles' {
        $weights = (Read-ReaderConfig $configPath).ui.weights
        if ($weights.reading -eq -2 -and $weights.title -eq 2 -and $weights.ui -eq -1 -and $weights.code -eq -2) { $true }
    } | Out-Null

    function Set-ReadingSlider([string]$id, [double]$value) {
        $slider = Wait-For "$id to be enabled" {
            $control = Find-ById $id
            if ($control -and $control.Current.IsEnabled) { $control }
        }
        $slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue($value)
    }

    Set-ReadingSlider 'TextSizeSlider' 24
    Set-ReadingSlider 'LineSpacingSlider' 1.8
    Set-ReadingSlider 'ColumnWidthSlider' 720

    $settingsScroller = Find-ById 'SettingsScroll'
    $scroll = $null
    $settingsHasOverflow = $settingsScroller.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern, [ref]$scroll) -and
        $scroll.Current.VerticallyScrollable
    if ($settingsHasOverflow) { $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 100) }
    Select-SettingsOption 'ScrollbarsPicker' 'Never'
    Wait-For 'the saved scrollbar mode to apply' {
        $picker = Find-ById 'ScrollbarsPicker'
        if ($picker -and $picker.Current.IsEnabled -and (Read-ReaderConfig $configPath).ui.scrollbars -eq 'never') { $true }
    } | Out-Null
    if ($settingsHasOverflow) {
        $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0)
        Wait-For 'Settings to scroll with its bar hidden' {
            if ($scroll.Current.VerticallyScrollable -and $scroll.Current.VerticalScrollPercent -lt 0.5) { $true }
        } | Out-Null
    }

    $agentsTab = Wait-For 'the Agents settings tab' { Find-ById 'AgentsSettingsTab' }
    $agentsTab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-For 'the writers to be listed with a Check button each' {
        if ((Find-ById 'CheckWriter_codex') -and (Find-ById 'CheckWriter_claude')) { $true }
    } | Out-Null
    Select-SettingsOption 'AgentTierPicker' 'Reading state only'
    Wait-For 'the agent tier to persist beside the other interface settings' {
        $ui = (Read-ReaderConfig $configPath).ui
        if ($ui.agentTier -eq 'annotate' -and $ui.scrollbars -eq 'never') { $true }
    } | Out-Null

    # Storage: what the data folder holds, the retention setting, and freeing feed copies. FYKE_HOME
    # names the folder for this run, so the move is offered but disabled; the client tests and
    # fyke data move's own tests cover the move.
    $storageTab = Wait-For 'the Storage settings tab' { Find-ById 'StorageSettingsTab' }
    $storageTab.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-For 'the disk use to be measured' {
        # Panels have no automation peer, so the measured rows are found from the window.
        $checked = Find-ById 'StorageChecked'
        $folder = Find-ById 'DataFolderPath'
        if ($checked -and $checked.Current.Name -like 'Checked*' -and (Find-ByName $root 'Feed copies') -and $folder -and
            $folder.Current.Name -like "*$(Split-Path $testHome -Leaf)") { $true }
    } | Out-Null
    $change = Find-ById 'ChangeDataFolder'
    if ($change.Current.IsEnabled) { throw 'Change… should be disabled while FYKE_HOME names the data folder.' }
    Select-SettingsOption 'RetentionPicker' '30 days'
    Wait-For 'the retention to persist' {
        if ((Read-ReaderConfig $configPath).remove_read_after_days -eq 30) { $true }
    } | Out-Null
    Invoke-Button 'StorageDetails_copies'
    Invoke-Button 'FreeCopies'
    Invoke-Button 'StorageConfirm'
    Wait-For 'the space to be measured again after freeing it' {
        $checked = Find-ById 'StorageChecked'
        if ($checked -and $checked.Current.Name -eq 'Checked just now' -and (Find-ById 'FreeCopies') -and
            !(Find-ById 'StorageConfirm')) { $true }
    } | Out-Null

    # A daemon that goes away and comes back (as after a data move) keeps Settings open.
    $beforeRestart = Get-CompanionProcess | Select-Object -First 1
    Stop-Process -Id $beforeRestart.ProcessId -Force
    Wait-For 'a replacement companion while Settings is open' {
        Get-CompanionProcess | Where-Object { $_.ProcessId -ne $beforeRestart.ProcessId } | Select-Object -First 1
    } | Out-Null
    Wait-For 'Settings to stay open and measure again after the reconnect' {
        $checked = Find-ById 'StorageChecked'
        $close = Find-ById 'CloseSettingsButton'
        $banner = Find-ById 'ReconnectingBanner'
        if ($checked -and $checked.Current.Name -eq 'Checked just now' -and $close -and !$close.Current.IsOffscreen -and
            (Find-ById 'FreeCopies') -and (!$banner -or $banner.Current.IsOffscreen)) { $true }
    } | Out-Null

    Invoke-Button 'CloseSettingsButton'
    Wait-For 'article layout to persist alongside the updated font weight' {
        $ui = (Read-ReaderConfig $configPath).ui
        if ($ui.textSize -eq 24 -and [Math]::Abs($ui.lineSpacing - 1.8) -lt 0.001 -and
            $ui.columnWidth -eq 720 -and $ui.weights.reading -eq -2) { $true }
    } | Out-Null
    Wait-For 'Settings to return to the open article and its feed' {
        $heading = Find-ById 'ArticleHeading'
        $scope = Find-ById 'TimelineHeading'
        if ($heading -and !$heading.Current.IsOffscreen -and $heading.Current.Name -eq 'Native reader fixture' -and
            $scope.Current.Name -eq 'Desktop fixture') { $true }
    } | Out-Null
    $timeline = Find-ById 'ReaderTimeline'
    Wait-For 'the open article to use the changed Reading weight' {
        $body = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)
        if ($body -and !$body.Current.IsOffscreen) {
            $text = $body.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
            if ($text.DocumentRange.GetAttributeValue([Windows.Automation.TextPattern]::FontWeightAttribute) -eq 200) { $true }
        }
    } | Out-Null
    Wait-For 'the open article to use the changed text size' {
        $body = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)
        if ($body -and !$body.Current.IsOffscreen) {
            $range = $body.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange
            $size = $range.GetAttributeValue([Windows.Automation.TextPattern]::FontSizeAttribute)
            if ($size -is [double] -and [Math]::Abs($size - ($originalBodySize * 24 / 19)) -lt 0.1) { $true }
        }
    } | Out-Null
    Assert-TextWeight (Find-ById 'ArticleHeading') 800 'the unchanged article title weight'
    Wait-For 'the open article heading to use the Dark theme ink' {
        $heading = Find-ById 'ArticleHeading'
        if ($heading -and !$heading.Current.IsOffscreen) {
            $range = $heading.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange
            $color = $range.GetAttributeValue([Windows.Automation.TextPattern]::ForegroundColorAttribute)
            if (($color -is [int] -or $color -is [uint32]) -and ($color -band 0xffffff) -eq 0xf2f2f2) { $true }
        }
    } | Out-Null
    Wait-For 'an automatic image request from the open article' {
        $probe = Invoke-WebRequest -Uri ([Uri]::new([Uri]$FeedUrl, '/image-status')) -UseBasicParsing
        if ($probe.Content -eq 'requested') { $true }
    } | Out-Null

    $collapse = Wait-For 'the folder collapse control' { Find-ByName $items 'Collapse Fixture folder' }
    $collapse.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the folder to hide its feed' {
        $control = Find-ByName $items 'Expand Fixture folder'
        if ($control -and !(Find-ByName $items 'Desktop fixture')) { $true }
    } | Out-Null
    $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
    if ($heading.Current.Name -ne 'Desktop fixture' -or !$root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)) {
        throw 'Collapsing a folder changed the active feed or article.'
    }
    $advance = [Uri]::new([Uri]$FeedUrl, '/advance')
    Invoke-WebRequest -Uri $advance -Method Post -UseBasicParsing | Out-Null
    & $daemonPath refresh
    if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the reader fixture feed' }
    $newArticle = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, 'Live reader update')
    Wait-For 'the live arrival in the timeline' {
        $timeline.FindFirst([Windows.Automation.TreeScope]::Descendants, $newArticle)
    } | Out-Null
    if (!$root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)) {
        throw 'The live update displaced the article being read.'
    }
    $expand = Find-ByName $items 'Expand Fixture folder'
    if (!$expand -or (Find-ByName $items 'Desktop fixture')) {
        throw 'The live update expanded a collapsed folder.'
    }
    $expand.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the feed to return after expanding the folder' { Find-ByName $items 'Desktop fixture' } | Out-Null

    $discussionActionId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'DiscussionAction')
    function Find-DiscussionAction([string]$name) {
        $action = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $discussionActionId)
        if ($action -and $action.Current.Name -eq $name -and $action.Current.IsEnabled) { $action }
    }

    $showComments = Wait-For 'the on-demand comments button' { Find-DiscussionAction 'Show comments' }
    Invoke-WebRequest -Uri ([Uri]::new([Uri]$FeedUrl, '/enable-discussion')) -Method Post -UseBasicParsing | Out-Null
    $showComments.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the discussion failure state' { Find-ByName $root 'The comments did not load' } | Out-Null
    $retryComments = Wait-For 'the discussion retry button' { Find-DiscussionAction 'Try again' }
    $retryComments.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the two comments after retry' { Find-ByName $root '2 comments' } | Out-Null
    Wait-For 'the nested reply' { Find-ByName $root 'A nested reply.' } | Out-Null
    $fold = Wait-For 'the comment collapse button' { Find-ByName $root 'Collapse comment by first-reader' }
    $fold.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $unfold = Wait-For 'the comment to hide its reply' {
        $control = Find-ByName $root 'Expand comment by first-reader'
        if ($control -and !(Find-ByName $root 'A nested reply.')) { $control }
    }
    $unfold.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the reply to return after expanding the comment' { Find-ByName $root 'A nested reply.' } | Out-Null

    Select-ReaderItem $timeline 'Live reader update'
    Wait-For 'the other discussion provider to use a link' {
        $link = Find-ByName $root 'Open discussion'
        if ($link -and !(Find-ByName $root 'A nested reply.')) { $link }
    } | Out-Null

    $fixtureEntries = (& $daemonPath list --json | Out-String | ConvertFrom-Json).items
    $readEntry = $fixtureEntries | Where-Object { $_.title -eq 'Native reader fixture' }
    if (!$readEntry.read) { throw 'Opening the article did not mark it read in the daemon.' }

    function Wait-ForArticleAction([string]$id, [string]$name) {
        $condition = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, $id)
        Wait-For $name {
            $control = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
            if ($control -and $control.Current.IsEnabled -and $control.Current.Name -eq $name) { $control }
        }
    }

    $markUnread = Wait-ForArticleAction 'ReadArticle' 'Mark as unread'
    $markUnread.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-ForArticleAction 'ReadArticle' 'Mark as read' | Out-Null
    Select-ReaderItem $items 'Starred'
    Wait-For 'the Starred destination before searching' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Starred') { $true }
    } | Out-Null

    $searchButtonId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchButton')
    $searchButton = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $searchButtonId)
    $searchButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $searchQueryId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchQuery')
    $searchQuery = Wait-For 'the search field' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $searchQueryId)
        if ($element -and !$element.Current.IsOffscreen) { $element }
    }
    $queryValue = $searchQuery.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $queryValue.SetValue('Native reader')
    $searchResultsId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchResults')
    Wait-For 'the read article in search results' {
        $results = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $searchResultsId)
        if ($results) { Find-ByName $results 'Native reader fixture' }
    } | Out-Null

    $unreadId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'SearchUnread')
    $unread = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $unreadId)
    $unread.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    $emptyMessage = 'Nothing matches ' + [char]0x201c + 'Native reader' + [char]0x201d + '. Try fewer or related words.'
    Wait-For 'the unread filter to exclude the read article' { Find-ByName $root $emptyMessage } | Out-Null

    $queryValue.SetValue('Live reader')
    $liveHitName = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, 'Live reader update, unread')
    $buttonType = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    $liveHit = [Windows.Automation.AndCondition]::new($liveHitName, $buttonType)
    $searchHit = Wait-For 'the unread article in search results' {
        $results = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $searchResultsId)
        if ($results) { $results.FindFirst([Windows.Automation.TreeScope]::Descendants, $liveHit) }
    }
    $searchHit.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the search result to open outside its destination' {
        Find-ByName $root 'Arrives while the first article is open.'
    } | Out-Null
    $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
    if ($heading.Current.Name -ne 'Starred') { throw 'Opening the search result changed the current destination.' }

    Wait-ForArticleAction 'ReadArticle' 'Mark as unread' | Out-Null
    $star = Wait-ForArticleAction 'StarArticle' 'Star article'
    $star.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the newly starred article in the timeline' { Find-ByName $timeline 'Live reader update' } | Out-Null
    $unstar = Wait-ForArticleAction 'StarArticle' 'Remove star'
    $unstar.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the unstarred article to leave the timeline' {
        if (!(Find-ByName $timeline 'Live reader update')) { $true }
    } | Out-Null
    if (!(Find-ByName $root 'Arrives while the first article is open.')) {
        throw 'Unstarring the article closed the reader.'
    }

    $markUnread = Wait-ForArticleAction 'ReadArticle' 'Mark as unread'
    $markUnread.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-ForArticleAction 'ReadArticle' 'Mark as read' | Out-Null
    Select-ReaderItem $items 'Fixture folder'
    Wait-For 'the folder timeline before marking all read' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Fixture folder') { $true }
    } | Out-Null
    $markAll = Wait-ForArticleAction 'BulkReadButton' 'Mark all read'
    $markAll.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the result of marking the folder read' {
        Find-ByName $root 'Marked 1 article in Fixture folder as read.'
    } | Out-Null
    $undo = Wait-ForArticleAction 'BulkNoticeUndo' 'Undo'
    $undo.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the result of undoing the bulk mark' {
        Find-ByName $root 'Restored 1 article in Fixture folder to unread.'
    } | Out-Null
    $entriesAfterUndo = (& $daemonPath list --json | Out-String | ConvertFrom-Json).items
    $previouslyRead = $entriesAfterUndo | Where-Object { $_.title -eq 'Native reader fixture' }
    $restoredUnread = $entriesAfterUndo | Where-Object { $_.title -eq 'Live reader update' }
    if (!$previouslyRead.read -or !$restoredUnread -or $restoredUnread.read) {
        throw 'Undo changed an article outside the bulk read action or failed to restore the affected article.'
    }

    $collapse = Wait-For 'the folder collapse control before palette navigation' { Find-ByName $items 'Collapse Fixture folder' }
    $collapse.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the palette destination to be hidden in the sidebar' {
        if (!(Find-ByName $items 'Desktop fixture') -and (Find-ByName $items 'Expand Fixture folder')) { $true }
    } | Out-Null

    function Invoke-PaletteResult([string]$query, [string]$title) {
        $openPalette = Wait-ForArticleAction 'PaletteButton' 'Command palette'
        $openPalette.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        $paletteQueryId = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, 'PaletteQuery')
        $field = Wait-For 'the command palette field' {
            $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paletteQueryId)
            if ($element -and !$element.Current.IsOffscreen) { $element }
        }
        $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($query)
        $paletteResultsId = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, 'PaletteResults')
        $name = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::NameProperty, $title)
        $resultButton = [Windows.Automation.AndCondition]::new($name, $buttonType)
        $result = Wait-For "the $title palette result" {
            $results = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paletteResultsId)
            if ($results) { $results.FindFirst([Windows.Automation.TreeScope]::Descendants, $resultButton) }
        }
        $result.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }

    Invoke-PaletteResult 'dsf' 'Desktop fixture'
    Wait-For 'the hidden feed destination to open from the palette' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Desktop fixture') { $true }
    } | Out-Null
    # The sidebar reloads as the feed opens, so wait for the folder row to be back before
    # reading which way it points.
    $folderState = Wait-For 'the folder row after palette navigation' {
        if (Find-ByName $items 'Collapse Fixture folder') { 'expanded' }
        elseif (Find-ByName $items 'Expand Fixture folder') { 'collapsed' }
    }
    if ($folderState -ne 'collapsed') { throw 'The palette expanded the folder.' }

    Invoke-PaletteResult 'Live reader' 'Live reader update'
    Wait-For 'the article opened directly from the palette' {
        Find-ByName $root 'Arrives while the first article is open.'
    } | Out-Null

    $openAddFeed = Wait-ForArticleAction 'AddFeedButton' 'Add feed'
    $openAddFeed.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $addAddressId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'AddFeedAddress')
    $addAddress = Wait-For 'the add-feed address field' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $addAddressId)
        if ($element -and !$element.Current.IsOffscreen) { $element }
    }
    $addAddress.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue(
        [Uri]::new([Uri]$FeedUrl, '/subscribe').AbsoluteUri)
    $findLocal = Wait-ForArticleAction 'AddFeedLocalRetry' 'Find feeds on the local network'
    $findLocal.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the second discovered feed' { Find-ByName $root 'Other discovered feed' } | Out-Null
    Wait-For 'the discovered article preview' { Find-ByName $root 'First discovered article' } | Out-Null
    $addNameId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'AddFeedName')
    $addName = Wait-For 'the feed name field' {
        $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $addNameId)
        if ($element -and !$element.Current.IsOffscreen) { $element }
    }
    $addName.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('Renamed discovery feed')
    $subscribe = Wait-ForArticleAction 'AddFeedPrimary' 'Subscribe'
    $subscribe.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the new subscription in the sidebar' { Find-ByName $items 'Renamed discovery feed' } | Out-Null
    if (Find-ByName $items 'Other discovered feed') { throw 'The unselected candidate was subscribed.' }

    function Save-CatalogName([string]$name, [string]$action) {
        $catalogNameId = [Windows.Automation.PropertyCondition]::new(
            [Windows.Automation.AutomationElement]::AutomationIdProperty, 'CatalogEditName')
        $field = Wait-For 'the catalog name field' {
            $element = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $catalogNameId)
            if ($element -and !$element.Current.IsOffscreen) { $element }
        }
        $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($name)
        $save = Wait-ForArticleAction 'CatalogEditConfirm' $action
        $save.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }

    Invoke-PaletteResult 'New folder' 'New folder'
    Save-CatalogName 'Reading list' 'Create folder'
    Wait-For 'the new folder in the sidebar' { Find-ByName $items 'Reading list' } | Out-Null

    Select-ReaderItem $items 'Renamed discovery feed'
    Select-ReaderItem $timeline 'First discovered article'
    Wait-ForArticleAction 'ReadArticle' 'Mark as unread' | Out-Null
    Invoke-PaletteResult 'Rename' 'Rename Renamed discovery feed'
    Save-CatalogName 'Reviewed discovery feed' 'Save name'
    Wait-For 'the renamed feed in the timeline' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Reviewed discovery feed') { $true }
    } | Out-Null
    $articleSourceId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ArticleSource')
    Wait-For 'the renamed source of the open article' {
        $source = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $articleSourceId)
        if ($source -and $source.Current.Name -eq 'Reviewed discovery feed') { $true }
    } | Out-Null
    $openHeading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $articleHeadingId)
    if ($openHeading.Current.Name -ne 'First discovered article') { throw 'Renaming the feed closed the article.' }

    $advanceDiscovery = [Uri]::new([Uri]$FeedUrl, '/advance-discovery')
    Invoke-WebRequest -Uri $advanceDiscovery -Method Post -UseBasicParsing | Out-Null
    Invoke-PaletteResult 'Refresh Reviewed' 'Refresh Reviewed discovery feed'
    Wait-For 'the refreshed article in the current feed' {
        Find-ByName $timeline 'Updated discovery article'
    } | Out-Null

    Invoke-PaletteResult 'Remove Reviewed' 'Remove Reviewed discovery feed'
    $cancelRemove = Wait-ForArticleAction 'CatalogEditCancel' 'Cancel'
    $cancelRemove.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the canceled removal to leave the feed in the sidebar' {
        Find-ByName $items 'Reviewed discovery feed'
    } | Out-Null
    Invoke-PaletteResult 'Remove Reviewed' 'Remove Reviewed discovery feed'
    $removeFeed = Wait-ForArticleAction 'CatalogEditConfirm' 'Remove feed'
    $removeFeed.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'All to replace the removed active feed' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        $open = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $articleHeadingId)
        if ($heading -and $heading.Current.Name -eq 'All' -and $open.Current.Name -eq 'Select an article') { $true }
    } | Out-Null
    if (Find-ByName $items 'Reviewed discovery feed') { throw 'The removed feed is still in the sidebar.' }

    Wait-For 'the collapsed folder to be saved with other reading settings' {
        $ui = (Read-ReaderConfig $configPath).ui
        if ($ui.collapsedFolders.Count -eq 1 -and $ui.collapsedFolders[0] -gt 0 -and $ui.scrollbars -eq 'never') { $true }
    } | Out-Null
    if (!$window.CloseMainWindow() -or !$window.WaitForExit(5000)) { throw 'The reader did not close before relaunch.' }
    $window.Dispose()
    $window = $null
    $launchTime = Get-Date
    $window = [Diagnostics.Process]::Start($start)
    $appErrors = $window.StandardError.ReadToEndAsync()
    $handle = Wait-For 'the relaunched main window' { if ($window.MainWindowHandle -ne [IntPtr]::Zero) { $window.MainWindowHandle } }
    $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
    $items = Wait-For 'the relaunched sidebar' { Find-ById 'ReaderDestinations' }
    # One window per data folder: a second launch hands itself to this one and exits.
    $second = [Diagnostics.Process]::Start($start)
    $secondErrors = $second.StandardError.ReadToEndAsync()
    if (!$second.WaitForExit(15000)) { $second.Kill(); throw 'A second launch opened a second window.' }
    if ($second.ExitCode -ne 0) { throw "A second launch failed: $($secondErrors.Result)" }
    $second.Dispose()
    if ($window.HasExited) { throw 'The open window closed when Fyke was launched again.' }
    Wait-For 'the saved collapsed folder to return without its feed' {
        if ((Find-ByName $items 'Expand Fixture folder') -and !(Find-ByName $items 'Desktop fixture')) { $true }
    } | Out-Null

    Select-ReaderItem $items 'Fixture folder'
    Wait-For 'the folder destination before removal' {
        $heading = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $headingId)
        if ($heading -and $heading.Current.Name -eq 'Fixture folder') { $true }
    } | Out-Null
    Invoke-PaletteResult 'Delete Fixture folder' 'Delete Fixture folder'
    $keepContentsId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'CatalogDeleteContents')
    $contents = Wait-For 'the delete contents choice' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $keepContentsId)
    }
    $contentsChoice = $contents.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    if ($contentsChoice.Current.ToggleState -ne [Windows.Automation.ToggleState]::Off) {
        throw 'Deleting a folder must keep its contents by default.'
    }
    $deleteFolder = Wait-ForArticleAction 'CatalogEditConfirm' 'Delete folder'
    $deleteFolder.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the folder feed to move to the top level' { Find-ByName $items 'Desktop fixture' } | Out-Null
    if (Find-ByName $items 'Fixture folder') { throw 'The removed folder is still in the sidebar.' }
    Wait-For 'the deleted folder to be removed from the saved disclosure state' {
        $ids = (Read-ReaderConfig $configPath).ui.collapsedFolders
        if ($null -ne $ids -and $ids.Count -eq 0) { $true }
    } | Out-Null
    $remaining = (& $daemonPath list --json | Out-String | ConvertFrom-Json).items
    if (!($remaining | Where-Object { $_.title -eq 'Native reader fixture' })) {
        throw 'Deleting the folder also deleted its articles.'
    }

    function Set-ViewField([string]$id, [string]$value) {
        $field = Wait-For "the $id field" {
            $control = Find-ById $id
            if ($control -and !$control.Current.IsOffscreen) { $control }
        }
        $field.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($value)
    }
    function Invoke-ViewDialogButton([string]$name) {
        $button = Wait-For "the $name dialog button" {
            $control = Find-ByName $root $name
            if ($control -and $control.Current.IsEnabled -and !$control.Current.IsOffscreen) { $control }
        }
        $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }

    $timeline = Find-ById 'ReaderTimeline'
    Select-ReaderItem $timeline 'Live reader update'
    $markUnread = Wait-ForArticleAction 'ReadArticle' 'Mark as unread'
    $markUnread.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-ForArticleAction 'ReadArticle' 'Mark as read' | Out-Null

    Invoke-Button 'SearchButton'
    Set-ViewField 'SearchQuery' 'Arrives while'
    Toggle-Setting 'SearchUnread'
    Invoke-Button 'SaveSearchViewButton'
    Set-ViewField 'ViewName' 'Fixture saved view'
    Invoke-ViewDialogButton 'Preview'
    Wait-For 'one matching article in the unsaved view' {
        Find-ByName $root ('1 matching article ' + [char]0x00b7 + ' 1 unread')
    } | Out-Null
    Invoke-ViewDialogButton 'Save view'
    Wait-For 'the saved view in the sidebar' { Find-ByName $items 'Fixture saved view' } | Out-Null
    Wait-For 'the saved search timeline' {
        $heading = Find-ById 'TimelineHeading'
        if ($heading.Current.Name -eq 'Fixture saved view' -and (Find-ByName $timeline 'Live reader update') -and
            !(Find-ByName $timeline 'Native reader fixture')) { $true }
    } | Out-Null
    Select-ReaderItem $timeline 'Live reader update'
    Wait-For 'the reader to stay open after marking the article read in the unread view' {
        if ((Find-ByName $root 'Arrives while the first article is open.') -and
            !(Find-ByName $timeline 'Live reader update')) { $true }
    } | Out-Null

    Invoke-PaletteResult 'Edit Fixture saved view' 'Edit Fixture saved view'
    Set-ViewField 'ViewName' 'Renamed fixture view'
    Set-ViewField 'ViewWords' 'stored blocks'
    Select-SettingsOption 'ViewReadingState' 'All articles'
    Invoke-ViewDialogButton 'Save view'
    Wait-For 'the edited rule and name to appear in the timeline' {
        $heading = Find-ById 'TimelineHeading'
        if ($heading.Current.Name -eq 'Renamed fixture view' -and (Find-ByName $timeline 'Native reader fixture') -and
            !(Find-ByName $timeline 'Live reader update')) { $true }
    } | Out-Null

    # Activity: the status line opens the panel. The broken feed failed when it was imported and
    # again on every refresh since; Show opens what happened beside its row.
    Wait-For 'the broken feed warning in the sidebar' {
        Find-ByName $items 'Broken fixture is not loading. Show why'
    } | Out-Null
    Wait-For 'the status line to ask for attention' {
        $words = Find-ById 'ActivityWords'
        if ($words -and $words.Current.Name -eq '1 thing needs you') { $true }
    } | Out-Null
    Invoke-Button 'ActivityButton'
    Wait-For 'the Activity panel' {
        $panel = Find-ById 'ActivityPanel'
        if ($panel -and (Find-ByName $panel 'Now') -and (Find-ByName $panel 'Needs you') -and
            (Find-ByName $panel 'Broken fixture is not loading') -and
            (Find-ByName $panel 'Their articles so far are kept. Fyke keeps trying on its own.')) { $true }
    } | Out-Null
    Invoke-Button 'ActivityShowFeed'
    Wait-For 'the broken feed health panel' {
        $health = Find-ById 'FeedHealth'
        $healthError = Find-ById 'FeedHealthError'
        if ($health -and $health.Current.Name -eq 'Broken fixture is not loading' -and $healthError -and $healthError.Current.Name) { $true }
    } | Out-Null
    Invoke-Button 'FeedHealthRefresh'
    Wait-For 'the health panel to close' {
        $health = Find-ById 'FeedHealth'
        if (!$health -or $health.Current.IsOffscreen) { $true }
    } | Out-Null

    # Routines: start one from the view, save it, see its dry run, then remove it and undo.
    $dot = [char]0x00b7
    $routineName = 'Morning renamed fixture view'
    Invoke-Button 'RoutinesButton'
    Invoke-Button 'NewRoutine'
    Wait-For 'the new routine draft' {
        $title = Find-ById 'RoutineTitle'
        $draft = Find-ByName $root "$routineName (not saved). Weekdays 07:30 $dot brief $dot notify. Not run yet"
        if ($title -and $title.Current.Name -eq "$routineName, rename" -and $draft) { $true }
    } | Out-Null
    Invoke-Button 'SaveRoutine'
    Wait-For 'the saved routine and its dry run' {
        $remove = Find-ById 'RemoveRoutine'
        $dryRun = Find-ById 'RoutineDryRun'
        $row = Find-ByName $root "$routineName. Weekdays 07:30 $dot brief $dot notify. Not run yet"
        if ($remove -and !$remove.Current.IsOffscreen -and $row -and $dryRun -and
            $dryRun.Current.Name -match '^(Would have caught|Nothing would have matched)') { $true }
    } | Out-Null
    Wait-For 'the next run in the sidebar' {
        $next = Find-ById 'RoutinesNext'
        if ($next -and $next.Current.Name -like 'Next *') { $true }
    } | Out-Null
    Invoke-Button 'RemoveRoutine'
    Invoke-Button 'BulkNoticeUndo'
    Wait-For 'the removed routine to come back' {
        $row = Find-ByName $root "$routineName. Weekdays 07:30 $dot brief $dot notify. Not run yet"
        $remove = Find-ById 'RemoveRoutine'
        if ($row -and $remove -and !$remove.Current.IsOffscreen) { $true }
    } | Out-Null

    Invoke-PaletteResult 'Delete Renamed fixture view' 'Delete Renamed fixture view'
    # Deleting happens at once, with no dialog. The routine that uses the view is turned off,
    # and Undo makes the view again and points the routine back at it.
    Wait-For 'All to reopen after deleting the active view' {
        $heading = Find-ById 'TimelineHeading'
        $notice = Find-ById 'BulkNoticeText'
        if ($heading.Current.Name -eq 'All' -and !(Find-ByName $items 'Renamed fixture view') -and
            $notice -and $notice.Current.Name -eq "Deleted $([char]0x201C)Renamed fixture view$([char]0x201D) and turned off the routine that used it.") { $true }
    } | Out-Null
    Invoke-Button 'BulkNoticeUndo'
    Wait-For 'the deleted view to come back and open' {
        $heading = Find-ById 'TimelineHeading'
        if ($heading.Current.Name -eq 'Renamed fixture view' -and (Find-ByName $items 'Renamed fixture view')) { $true }
    } | Out-Null

    & $daemonPath status
    if ($LASTEXITCODE -ne 0) { throw 'The companion daemon did not answer status' }
    Write-Host 'WinUI verified daemon recovery, reading, search, the palette, bulk undo, subscription management, folder disclosure across relaunch, saved views, and routines.'
} catch {
    Write-Host $_.ScriptStackTrace
    if ($window -and $window.HasExited) {
        if ($appErrors -and $appErrors.Status -eq 'RanToCompletion') { Write-Host $appErrors.Result }
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1026; StartTime = $launchTime } `
            -ErrorAction SilentlyContinue -MaxEvents 20 |
            Where-Object { $_.Message -like '*Fyke.App.exe*' } |
            ForEach-Object { Write-Host $_.Message }
    }
    throw
} finally {
    try {
        if ($window) {
            if (!$window.HasExited) {
                $window.CloseMainWindow() | Out-Null
                if (!$window.WaitForExit(5000)) { $window.Kill(); $window.WaitForExit() }
            }
            $window.Dispose()
        }
        if (Test-Path (Join-Path $testHome 'fyked.sock')) {
            & $daemonPath daemon stop
            if ($LASTEXITCODE -ne 0) { throw 'Could not stop the smoke-test daemon' }
        }
        for ($attempt = 0; $attempt -lt 50 -and (Test-Path $testHome); $attempt++) {
            try { Remove-Item -Recurse -Force $testHome -ErrorAction Stop }
            catch { if ($attempt -eq 49) { throw }; Start-Sleep -Milliseconds 100 }
        }
        if ($copied) { Remove-Item $companion }
    } finally {
        $env:FYKE_HOME = $previousHome
        $env:FYKE_BIN = $previousBin
        $env:FYKE_HEADLESS = $previousHeadless
    }
}
