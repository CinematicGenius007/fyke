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
$child = $null

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

    # Encode only the probe and scratch paths. The password stays in the process credentials.
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
exit 0
'@
    $probe = $probe.Replace('__SID__', $user.SID.Value)
    $probe = $probe.Replace('__DATABASE__', $database.Replace("'", "''"))
    $probe = $probe.Replace('__SOCKET__', $socketPath.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute = $false
    # A process started with other credentials needs valid standard handles of its own.
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.UserName = $account
    $start.Domain = $env:COMPUTERNAME
    $start.Password = $password
    $start.WorkingDirectory = $env:SystemRoot
    $start.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $child = [Diagnostics.Process]::Start($start)
    $child.StandardInput.Close()
    $stdout = $child.StandardOutput.ReadToEndAsync()
    $stderr = $child.StandardError.ReadToEndAsync()
    if (!$child.WaitForExit(15000)) { throw 'The second-account probe timed out.' }

    # Confirm the socket still answers for the owner before interpreting the negative probe.
    if (!(Test-Path $socketPath)) { throw 'The daemon socket disappeared during the probe.' }
    & $daemonPath status
    if ($LASTEXITCODE -ne 0) { throw 'The owner could no longer reach the daemon.' }
    switch ($child.ExitCode) {
        0 { Write-Host 'A separate standard account could not read or write the database or connect to the socket.' }
        12 { throw 'A separate account could read the database.' }
        13 { throw 'A separate account could open the database for writing.' }
        14 { throw 'A separate account could connect to the daemon socket.' }
        default { throw "The separate-account probe failed with exit code $($child.ExitCode). $($stdout.GetAwaiter().GetResult()) $($stderr.GetAwaiter().GetResult())" }
    }
} finally {
    try {
        if ($child) {
            if (!$child.HasExited) { $child.Kill(); $child.WaitForExit() }
            $child.Dispose()
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
