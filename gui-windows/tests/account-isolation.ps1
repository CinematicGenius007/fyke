param([Parameter(Mandatory)][string]$Daemon)

$ErrorActionPreference = 'Stop'
$daemonPath = (Resolve-Path $Daemon).Path
$tag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$account = "fyke-$tag"
$testHome = Join-Path $env:LOCALAPPDATA "fyke-$tag"
$database = Join-Path $testHome 'fyke.db'
$socketPath = Join-Path $testHome 'fyked.sock'
$previousHome = $env:FYKE_HOME
$password = ConvertTo-SecureString ("Fyke!9" + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
$created = $false
$taskName = "Fyke isolation $tag"
$registered = $false

try {
    $env:FYKE_HOME = $testHome
    & $daemonPath status
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $database) -or !(Test-Path $socketPath)) {
        throw 'Could not start the daemon in the scratch profile.'
    }

    $user = New-LocalUser -Name $account -Password $password -Description 'Disposable Fyke CI account'
    $created = $true
    $usersGroup = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    if (!(Get-LocalGroupMember -SID $usersGroup | Where-Object { $_.SID -eq $user.SID })) {
        Add-LocalGroupMember -SID $usersGroup -Member $user
    }

    # Verify the task identity before probing the owner’s files and socket.
    $probe = @'
$ErrorActionPreference = 'Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne '__SID__') { exit 10 }
foreach ($mode in @('Read', 'Write')) {
    try {
        $stream = [IO.File]::Open('__DATABASE__', 'Open', $mode, 'ReadWrite')
    } catch [UnauthorizedAccessException] {
        continue
    } catch {
        exit 11
    }
    $stream.Dispose()
    if ($mode -eq 'Read') { exit 12 }
    exit 13
}
$address = [Net.Sockets.UnixDomainSocketEndPoint]::new('__SOCKET__')
$socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::Unix, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Unspecified)
try {
    $socket.Connect($address)
    exit 14
} catch [Net.Sockets.SocketException] {
    # Windows may hide socket paths that the caller cannot traverse.
    if ($_.Exception.SocketErrorCode -notin @('AccessDenied', 'AddressNotAvailable', 'ConnectionRefused')) { exit 15 }
} finally {
    $socket.Dispose()
}
exit 42
'@
    $probe = $probe.Replace('__SID__', $user.SID.Value)
    $probe = $probe.Replace('__DATABASE__', $database.Replace("'", "''"))
    $probe = $probe.Replace('__SOCKET__', $socketPath.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    # Task Scheduler launches the probe outside the runner's process tree under the test account.
    $action = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path `
        -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded" -WorkingDirectory $env:SystemRoot
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$account" -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
    $registered = $true
    $previousRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 200
        $run = Get-ScheduledTaskInfo -TaskName $taskName
        $state = (Get-ScheduledTask -TaskName $taskName).State
        if ($run.LastRunTime -ne $previousRun -and $state -eq 'Ready') { break }
    } while ($timer.Elapsed.TotalSeconds -lt 30)
    if ($run.LastRunTime -eq $previousRun -or $state -ne 'Ready') {
        throw "The second-account task did not complete. State: $state. Result: $($run.LastTaskResult)."
    }

    # Confirm the socket still answers for the owner before interpreting the negative probe.
    if (!(Test-Path $socketPath)) { throw 'The daemon socket disappeared during the probe.' }
    & $daemonPath status
    if ($LASTEXITCODE -ne 0) { throw 'The owner could no longer reach the daemon.' }
    switch ($run.LastTaskResult) {
        42 { Write-Host 'A separate standard account could not read or write the database or connect to the socket.' }
        12 { throw 'A separate account could read the database.' }
        13 { throw 'A separate account could open the database for writing.' }
        14 { throw 'A separate account could connect to the daemon socket.' }
        default { throw "The separate-account probe failed with task result $($run.LastTaskResult)." }
    }
} finally {
    try {
        if ($registered) {
            if ((Get-ScheduledTask -TaskName $taskName).State -in @('Running', 'Queued')) {
                Stop-ScheduledTask -TaskName $taskName
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        if (Test-Path $socketPath) {
            & $daemonPath daemon stop
            if ($LASTEXITCODE -ne 0) { throw 'Could not stop the isolation-test daemon.' }
        }
        for ($attempt = 0; $attempt -lt 50 -and (Test-Path $testHome); $attempt++) {
            try { Remove-Item $testHome -Recurse -Force -ErrorAction Stop }
            catch { if ($attempt -eq 49) { throw }; Start-Sleep -Milliseconds 100 }
        }
    } finally {
        try {
            if ($created) { Remove-LocalUser -Name $account }
        } finally {
            $env:FYKE_HOME = $previousHome
            $password.Dispose()
        }
    }
}
