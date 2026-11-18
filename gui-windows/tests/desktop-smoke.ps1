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
$testHome = Join-Path ([IO.Path]::GetTempPath()) ('fyke ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$env:FYKE_HOME = $testHome
$companion = Join-Path (Split-Path $appPath) 'fyke.exe'
if (Test-Path $companion) { throw "Use a fresh app build without a bundled daemon: $companion" }
$window = $null
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
    $start.Environment.Remove('PATH') | Out-Null
    $window = [Diagnostics.Process]::Start($start)
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

    $opml = Join-Path $testHome 'fixture.opml'
    $urlAttribute = [Security.SecurityElement]::Escape($FeedUrl)
    [IO.File]::WriteAllText($opml, @"
<opml version="2.0"><body><outline text="Fixture folder">
<outline type="rss" text="Desktop fixture" xmlUrl="$urlAttribute"/>
</outline></body></opml>
"@)
    & $daemonPath import $opml --allow-private
    if ($LASTEXITCODE -ne 0) { throw 'Could not import the reader fixture feed' }
    Select-ReaderItem $items 'Desktop fixture'
    $timelineId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ReaderTimeline')
    $timeline = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $timelineId)
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
    $imageButton = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, ("Load image " + [char]0x00b7 + " Fixture illustration"))
    Wait-For 'the image load control' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $imageButton)
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

    $discussionId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ArticleDiscussion')
    $discussion = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $discussionId)
    $showComments = Wait-For 'the on-demand comments button' { Find-ByName $discussion 'Show comments' }
    Invoke-WebRequest -Uri ([Uri]::new([Uri]$FeedUrl, '/enable-discussion')) -Method Post -UseBasicParsing | Out-Null
    $showComments.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the discussion failure state' { Find-ByName $discussion 'The comments did not load' } | Out-Null
    $retryComments = Find-ByName $discussion 'Try again'
    $retryComments.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the two comments after retry' { Find-ByName $discussion '2 comments' } | Out-Null
    Wait-For 'the nested reply' { Find-ByName $discussion 'A nested reply.' } | Out-Null
    $fold = Find-ByName $discussion 'Collapse comment by first-reader'
    $fold.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $unfold = Wait-For 'the comment to hide its reply' {
        $control = Find-ByName $discussion 'Expand comment by first-reader'
        if ($control -and !(Find-ByName $discussion 'A nested reply.')) { $control }
    }
    $unfold.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-For 'the reply to return after expanding the comment' { Find-ByName $discussion 'A nested reply.' } | Out-Null

    Select-ReaderItem $timeline 'Live reader update'
    Wait-For 'the other discussion provider to use a link' {
        $link = Find-ByName $discussion 'Open discussion'
        if ($link -and !(Find-ByName $discussion 'A nested reply.')) { $link }
    } | Out-Null

    & $daemonPath status
    if ($LASTEXITCODE -ne 0) { throw 'The companion daemon did not answer status' }
    Write-Host 'WinUI recovered the daemon and kept the article open through folder disclosure and a live feed update.'
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
    }
}
