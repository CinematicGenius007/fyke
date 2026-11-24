; Fyke's additions to Tauri's per-user NSIS installer (bundle.windows.nsis.installerHooks).
; Tauri !includes this file near the top of its template, before any page, so the
; defines below apply to its first page (Welcome). See docs/desktop.md, "Windows installer".
;
; What they add to the template, as the WinUI installer did:
; - Program files go in %LOCALAPPDATA%\Programs\Fyke. Tauri's default for a per-user
;   install, %LOCALAPPDATA%\Fyke, is Fyke's data folder, which must hold nothing else.
; - Two choices on the Welcome page: the fyke command on PATH, and the background service
;   from sign-in (`fyke service install`, which also starts it now). Both are on at a
;   first install; an upgrade keeps what was chosen before. A silent install takes
;   /ADDTOPATH=0|1 and /BACKGROUND=0|1 (names that no option of Tauri's is a prefix of).
; - An upgrade closes the Fyke installed here, and no copy run from elsewhere, before it
;   stops the daemon, so the app cannot start the old daemon again while files change.
; - Uninstalling closes the app, removes the service, stops the daemon and takes fyke off
;   PATH. The data folder is never touched.

!define FYKE_CHOICES "Software\Fyke\Installer"
!define FYKE_DEFAULT_DIR "$LOCALAPPDATA\Programs\Fyke"

Var FykeAddToPath
Var FykeBackground
Var FykeChoicesRead
Var FykePathBox
Var FykeBackgroundBox

!define MUI_CUSTOMFUNCTION_GUIINIT FykeGuiInit
!define MUI_PAGE_CUSTOMFUNCTION_SHOW FykeWelcomeShow
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE FykeWelcomeLeave

; Moves a default install out of the data folder. Tauri restores an earlier install's
; folder, or takes /D=, before this runs, and those are kept.
!macro FykeInstallFolder
  ${If} $INSTDIR == "$LOCALAPPDATA\Fyke"
    StrCpy $INSTDIR "${FYKE_DEFAULT_DIR}"
  ${EndIf}
!macroend

; The choices: the command line's, else the last install's, else on.
!macro FykeReadChoices
  ${If} $FykeChoicesRead != 1
    StrCpy $FykeChoicesRead 1
    ReadRegDWORD $FykeAddToPath HKCU "${FYKE_CHOICES}" "AddToPath"
    ${If} ${Errors}
      StrCpy $FykeAddToPath 1
    ${EndIf}
    ClearErrors
    ReadRegDWORD $FykeBackground HKCU "${FYKE_CHOICES}" "Background"
    ${If} ${Errors}
      StrCpy $FykeBackground 1
    ${EndIf}
    ClearErrors
    ${GetOptions} $CMDLINE "/ADDTOPATH=" $0
    ${IfNot} ${Errors}
      ${IfThen} $0 == "0" ${|} StrCpy $FykeAddToPath 0 ${|}
      ${IfThen} $0 == "1" ${|} StrCpy $FykeAddToPath 1 ${|}
    ${EndIf}
    ClearErrors
    ${GetOptions} $CMDLINE "/BACKGROUND=" $0
    ${IfNot} ${Errors}
      ${IfThen} $0 == "0" ${|} StrCpy $FykeBackground 0 ${|}
      ${IfThen} $0 == "1" ${|} StrCpy $FykeBackground 1 ${|}
    ${EndIf}
    ClearErrors
  ${EndIf}
!macroend

Function FykeGuiInit
  !insertmacro FykeInstallFolder
  !insertmacro FykeReadChoices
FunctionEnd

Function FykeWelcomeShow
  ${NSD_CreateCheckbox} 120u 150u -130u 10u "Add the fyke command to PATH"
  Pop $FykePathBox
  SetCtlColors $FykePathBox "" "FFFFFF"
  ${NSD_SetState} $FykePathBox $FykeAddToPath
  ${NSD_CreateCheckbox} 120u 164u -130u 10u "Keep feeds up to date in the background, from sign-in"
  Pop $FykeBackgroundBox
  SetCtlColors $FykeBackgroundBox "" "FFFFFF"
  ${NSD_SetState} $FykeBackgroundBox $FykeBackground
FunctionEnd

Function FykeWelcomeLeave
  ${NSD_GetState} $FykePathBox $FykeAddToPath
  ${NSD_GetState} $FykeBackgroundBox $FykeBackground
FunctionEnd

; Closes the Fyke windows that run from this folder, as clicking close would, then ends
; any still open after two seconds. Matching the full path leaves alone a copy run from
; anywhere else, such as a build being tested, and other people's, whose installs are in
; their own profiles. (Tauri's own check after this finds nothing left to close.)
!macro FykeCloseApp
  ${WordReplace} "$INSTDIR\${MAINBINARYNAME}.exe" "'" "''" "+" $1
  StrCpy $2 "$$app = '$1'; \
$$open = @(Get-Process -Name '${MAINBINARYNAME}' -ErrorAction SilentlyContinue | Where-Object { $$_.Path -eq $$app }); \
foreach ($$p in $$open) { [void]$$p.CloseMainWindow() }; \
if ($$open) { $$open | Wait-Process -Timeout 2 -ErrorAction SilentlyContinue; \
$$open | Where-Object { -not $$_.HasExited } | Stop-Process -Force -ErrorAction SilentlyContinue }"
  nsExec::Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$2"'
  Pop $0
!macroend

; Runs fyke from this folder with no window, when it is there.
!macro FykeRun arguments
  ${If} ${FileExists} "$INSTDIR\fyke.exe"
    nsExec::Exec '"$INSTDIR\fyke.exe" ${arguments}'
    Pop $0
  ${EndIf}
!macroend

; Adds this folder to the user's PATH (add = 1) or takes it off (add = 0), keeping the
; value's type (REG_EXPAND_SZ) and every other entry as written.
!macro FykePath add
  ${WordReplace} "$INSTDIR" "'" "''" "+" $1
  StrCpy $2 "$$k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment'); \
$$old = [string]$$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); \
$$dir = '$1'; \
$$kept = @($$old -split ';' | Where-Object { $$_ -and ($$_.TrimEnd('\') -ne $$dir.TrimEnd('\')) }); \
if (${add}) { $$kept += $$dir }; \
$$new = $$kept -join ';'; \
if ($$new -ne $$old) { $$k.SetValue('Path', $$new, [Microsoft.Win32.RegistryValueKind]::ExpandString) }"
  nsExec::Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$2"'
  Pop $0
  ; Tells Explorer, and the terminals it starts, that the environment changed.
  SendMessage 0xFFFF 0x001A 0 "STR:Environment" /TIMEOUT=500
!macroend

!macro NSIS_HOOK_PREINSTALL
  !insertmacro FykeInstallFolder
  SetOutPath $INSTDIR
  !insertmacro FykeReadChoices
  ; The app first, or it would start the daemon again.
  !insertmacro FykeCloseApp
  ; Stops the daemon cleanly, so its database is closed before its files are replaced.
  ; A supervisor started at sign-in ends with it.
  !insertmacro FykeRun "daemon stop"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  ${If} $FykeAddToPath = 1
    !insertmacro FykePath 1
  ${Else}
    !insertmacro FykePath 0
  ${EndIf}
  ${If} $FykeBackground = 1
    DetailPrint "Starting the background service..."
    !insertmacro FykeRun "service install"
  ${Else}
    ; Someone who turns it off on an upgrade no longer wants it.
    !insertmacro FykeRun "service uninstall"
  ${EndIf}
  WriteRegDWORD HKCU "${FYKE_CHOICES}" "AddToPath" $FykeAddToPath
  WriteRegDWORD HKCU "${FYKE_CHOICES}" "Background" $FykeBackground
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro FykeCloseApp
  !insertmacro FykeRun "service uninstall"
  !insertmacro FykeRun "daemon stop"
  !insertmacro FykePath 0
  ${If} $UpdateMode <> 1
    DeleteRegKey HKCU "${FYKE_CHOICES}"
    DeleteRegKey /ifempty HKCU "Software\Fyke"
  ${EndIf}
!macroend
