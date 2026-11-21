; The per-user Windows installer: Fyke.App, fyke.exe and the fonts, in
; %LOCALAPPDATA%\Programs\Fyke, with no administrator prompt.
;
; tools/windows_installer.py compiles it, defining:
;   AppVersion  MAJOR.MINOR.PATCH, from VERSION
;   AppDir      the published app (dotnet publish src/Fyke.App)
;   Daemon      fyke.exe, built with zig build -Drelease
;   OutputDir   where Fyke-<version>-setup-x64.exe is written
;
; What it does, and why (docs/windows-gui.md, "Installer"):
; - Installs for the current user only. The data stays where it always is,
;   %LOCALAPPDATA%\Fyke or wherever it was moved, apart from the program files.
; - Adds Fyke to the Start menu, and optionally fyke to PATH and the background
;   service to sign-in (`fyke service install`, which starts it now as well).
; - An upgrade closes the Fyke installed here (not a copy run from elsewhere) and stops
;   the daemon cleanly before replacing files, and starts the service again after.
;   The app replaces an older daemon by itself too.
; - Uninstalling removes the sign-in entry, PATH entry, notification registration
;   and program files, and keeps every article, feed and setting.

#ifndef AppVersion
  #error Define AppVersion, for example /DAppVersion=0.1.0
#endif
#ifndef AppDir
  #error Define AppDir, the published Fyke.App folder
#endif
#ifndef Daemon
  #error Define Daemon, the path of fyke.exe
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Never change the AppId: an upgrade finds the installed copy by it.
AppId={{B4FB2AE1-5D43-423D-BC0B-6BC185FDB49C}
AppName=Fyke
AppVersion={#AppVersion}
AppVerName=Fyke {#AppVersion}
AppPublisher=Fyke
AppPublisherURL=https://github.com/CinematicGenius007/fyke
AppSupportURL=https://github.com/CinematicGenius007/fyke/issues
VersionInfoVersion={#AppVersion}
; Per user, so no administrator prompt: {autopf} is %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\Fyke
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
UsedUserAreasWarning=no
; The app's minimum, Windows 11 22H2 (TargetPlatformMinVersion), on x64.
MinVersion=10.0.22621
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Closes whatever still holds a file being replaced, such as a daemon a client restarted.
CloseApplications=force
RestartApplications=no
ChangesEnvironment=yes
SetupIconFile=..\src\Fyke.App\Assets\Fyke.ico
UninstallDisplayIcon={app}\Fyke.App.exe
UninstallDisplayName=Fyke
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=Fyke-{#AppVersion}-setup-x64

[Tasks]
Name: "startup"; Description: "Keep feeds up to date in the background, from sign-in"
Name: "path"; Description: "Add the fyke command to PATH"
Name: "desktopicon"; Description: "Add a desktop shortcut"; Flags: unchecked

[InstallDelete]
; What an earlier version shipped and this one does not would otherwise stay. Only the
; folders the app publishes are cleared; the install folder holds nothing of the person's.
Type: filesandordirs; Name: "{app}\Fonts"
Type: filesandordirs; Name: "{app}\Assets"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.xbf"
Type: files; Name: "{app}\*.pri"

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Daemon}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Fyke"; Filename: "{app}\Fyke.App.exe"; Comment: "Read your feeds"
Name: "{autodesktop}\Fyke"; Filename: "{app}\Fyke.App.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\fyke.exe"; Parameters: "service install"; Tasks: startup; Flags: runhidden; StatusMsg: "Starting the background service..."
; A person who turns the task off on an upgrade no longer wants it.
Filename: "{app}\fyke.exe"; Parameters: "service uninstall"; Tasks: not startup; Flags: runhidden
Filename: "{app}\Fyke.App.exe"; Description: "Open Fyke"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{app}\Fyke.App.exe"; Parameters: "--unregister-notifications"; Flags: runhidden; RunOnceId: "Notifications"
Filename: "{app}\fyke.exe"; Parameters: "service uninstall"; Flags: runhidden; RunOnceId: "Service"
Filename: "{app}\fyke.exe"; Parameters: "daemon stop"; Flags: runhidden; RunOnceId: "Daemon"

[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
const
  EnvironmentKey = 'Environment';

{ Closes the Fyke windows that run from this install, as clicking close would, then ends
  any still open after two seconds. Matching the full path leaves alone a copy run from
  anywhere else, such as a build being tested, and other people's, whose installs are in
  their own profiles. }
procedure CloseApp();
var
  Code: Integer;
  App: String;
  Script: String;
begin
  App := ExpandConstant('{app}\Fyke.App.exe');
  StringChangeEx(App, '''', '''''', True);
  Script :=
    '$app = ''' + App + '''; ' +
    '$open = @(Get-Process -Name Fyke.App -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $app }); ' +
    'foreach ($p in $open) { [void]$p.CloseMainWindow() }; ' +
    'if ($open) { $open | Wait-Process -Timeout 2 -ErrorAction SilentlyContinue; ' +
    '$open | Where-Object { -not $_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue }';
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Script + '"',
    '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

{ Stops the daemon cleanly, so its database is closed before its files are replaced. A
  supervisor started at sign-in ends with it. }
procedure StopDaemon(Daemon: String);
var
  Code: Integer;
begin
  if FileExists(Daemon) then
    Exec(Daemon, 'daemon stop', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseApp();
  StopDaemon(ExpandConstant('{app}\fyke.exe'));
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseApp();
  Result := True;
end;

function PathHas(Paths, Dir: String): Boolean;
begin
  Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Paths) + ';') > 0;
end;

procedure AddToPath(Dir: String);
var
  Paths: String;
begin
  if not RegQueryStringValue(HKCU, EnvironmentKey, 'Path', Paths) then
    Paths := '';
  if PathHas(Paths, Dir) then
    exit;
  if (Paths <> '') and (Copy(Paths, Length(Paths), 1) <> ';') then
    Paths := Paths + ';';
  RegWriteExpandStringValue(HKCU, EnvironmentKey, 'Path', Paths + Dir);
end;

procedure RemoveFromPath(Dir: String);
var
  Paths: String;
  Kept: String;
  Entry: String;
  Split: Integer;
begin
  if not RegQueryStringValue(HKCU, EnvironmentKey, 'Path', Paths) then
    exit;
  Kept := '';
  Paths := Paths + ';';
  while Paths <> '' do
  begin
    Split := Pos(';', Paths);
    Entry := Copy(Paths, 1, Split - 1);
    Delete(Paths, 1, Split);
    if (Entry <> '') and (CompareText(Entry, Dir) <> 0) then
    begin
      if Kept <> '' then
        Kept := Kept + ';';
      Kept := Kept + Entry;
    end;
  end;
  RegWriteExpandStringValue(HKCU, EnvironmentKey, 'Path', Kept);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    if WizardIsTaskSelected('path') then
      AddToPath(ExpandConstant('{app}'))
    else
      RemoveFromPath(ExpandConstant('{app}'));
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  { Before the files go, so that the uninstaller has finished with PATH when it reports
    itself done. }
  if CurUninstallStep = usUninstall then
    RemoveFromPath(ExpandConstant('{app}'));
end;
