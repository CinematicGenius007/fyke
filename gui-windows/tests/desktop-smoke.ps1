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

    & $daemonPath add $FeedUrl --allow-private
    if ($LASTEXITCODE -ne 0) { throw 'Could not add the reader fixture feed' }
    Select-ReaderItem $items 'All'
    $timelineId = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::AutomationIdProperty, 'ReaderTimeline')
    $timeline = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $timelineId)
    Select-ReaderItem $timeline 'Native reader fixture'
    $paragraph = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, 'The story is rendered from stored blocks.')
    Wait-For 'the article paragraph' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $paragraph)
    } | Out-Null
    $imageButton = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty, ("Load image " + [char]0x00b7 + " Fixture illustration"))
    Wait-For 'the image load control' {
        $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $imageButton)
    } | Out-Null

    & $daemonPath status
    if ($LASTEXITCODE -ne 0) { throw 'The companion daemon did not answer status' }
    Write-Host 'WinUI recovered the daemon, switched destinations, and rendered the fixture article.'
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
