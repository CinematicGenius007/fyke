# Fyke desktop checks on Windows

Use a Windows 10 1803 or later x64 machine with the Evergreen WebView2 runtime. Run these against the Tauri app on the `feat/desktop-tauri` branch. Keep test files and subscriptions in a throwaway home. Record the commit, Windows and WebView2 versions, and the observed result for each check.

## Build the phase 4 app

Use PowerShell with Zig 0.17.1, Bun, Rust stable with the MSVC target, and the Visual Studio C++ build tools installed. Start in the repository root.

```powershell
zig build -Drelease
$env:FYKE_BIN = (Resolve-Path .\zig-out\bin\fyke.exe).Path
$env:FYKE_HOME = Join-Path $env:TEMP ("fyke-win-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $env:FYKE_HOME
Remove-Item Env:FYKE_HEADLESS -ErrorAction SilentlyContinue
Set-Location desktop
bun install --frozen-lockfile
bun run tauri build --no-bundle
& .\src-tauri\target\release\Fyke.App.exe
```

If `CARGO_TARGET_DIR` is set, use its `release` directory for the executable.

## Subscriptions and native file dialogs

1. In the empty reader, enter `https://blog.rust-lang.org/feed.xml` and press Enter. The Add a feed dialog opens with the address and, after discovery, the feed name, address and recent titles. Cancel and verify the reader is still empty. Reopen with Ctrl+N, add the feed and verify it appears under Feeds.
2. Open a folder or use the Feeds plus button to create one. Right-click the folder and choose Add feed here. Enter `https://hnrss.org/frontpage` and wait for the preview. The Folder field should already show the folder you chose. Subscribe and verify the feed appears inside it. Drag the feed to the Feeds heading and check it moves to the top level. Drag it back into the folder.
3. Open Settings (Ctrl+,). Under Your subscriptions, choose Export. The native Save dialog opens in front of Fyke and starts with `feeds.opml`. Save to a scratch folder whose path contains spaces and non-ASCII characters. Open the file in a text editor and verify that it contains the two feed URLs and the folder hierarchy. Repeat the export to the same file, accept replacement, and verify the file is still valid.
4. Use the Settings Import OPML action and cancel the native Open dialog. The app regains focus and its subscriptions stay the same. Then repeat the import in a second throwaway home. Select the exported file and verify the two feeds and the folder reappear. Import it again and verify no duplicate feeds appear.
5. Turn on a Windows contrast theme. Open Add a feed, Tab through its controls and press Esc. Check that the focus ring, address border, form text and subscription button remain visible. Test the Folder field with the keyboard and verify focus returns to Fyke after canceling a native file dialog.

After closing Fyke, stop the test daemon with `& $env:FYKE_BIN daemon stop`. Repeat for the second home if you used one.

## Native web reader

1. From the same scratch home, quit Fyke and set `$env:FYKE_SCREEN = "web"` and `$env:FYKE_ADDRESS = "https://example.com/"`. Start Fyke again. The web bar shows the host and the page loads below it. Resize and maximize the window, and verify the page stays below its toolbar and inside the reader.
2. Open the command palette with the web pane showing. The palette is visible and clickable over the page. Close it and verify the page reappears. Click Back and verify the reader is visible again.
3. Repeat the launch with `$env:FYKE_ADDRESS = "http://127.0.0.1:1420/"`. The reader shows a private-address refusal and never loads content from that address. Repeat with `http://[::1]/`.
4. Remove the two variables with `Remove-Item Env:FYKE_SCREEN,Env:FYKE_ADDRESS`. Open a web-linked article and use Open page. Confirm that Article returns to the same article and Open in browser opens the address in your default browser. Ctrl-click an article link and confirm it opens in your browser while the article stays visible.

## Native Settings

Use a disposable Windows user account for the data move and sign-in tests, since they change that account's Fyke data pointer and startup registration.

1. With `FYKE_HOME` set to the scratch home above, open Settings with Ctrl+,. Click Reading, open the Reading font picker, and search for an installed Windows font such as Consolas. Select it, set Titles weight to Bolder, quit Fyke, and reopen it. Reading retains the font and the separate weight. Select a different theme. The temporary font clears and the weight stays Bolder.
2. In Agents, verify the MCP configuration names the bundled or overridden `fyke.exe`. If Claude Code is installed, click Choose next to Profile folder, cancel the dialog, and verify the profile stays the same. Choose a disposable existing profile folder, then click Use default and verify the displayed path resets.
3. With the app and scratch daemon stopped, clear the override with `Remove-Item Env:FYKE_HOME`. Reopen Fyke. In Settings · Data, verify the data folder is `%LOCALAPPDATA%\Fyke`. Add one feed, open an article, and star it. Click Change and cancel the folder dialog. The data folder and star stay in place.
4. Click Change again, pick an empty scratch directory with spaces in its name, and accept Move data. Confirm the progress dialog closes, the new path appears in Settings, and the feed and star survive both the move and a full relaunch. Open the data folder and the settings file with their respective Open buttons. Try a location you cannot write to and confirm Fyke reports the refusal and can still read the articles.
5. In Settings · General, turn on Keep updating in the background. `& $env:FYKE_BIN service status` prints `installed`. Close Fyke and check the daemon still responds to `& $env:FYKE_BIN status`. Reopen Settings, turn the switch off, and confirm `service status` now prints `not installed`. When finished, close Fyke and run `& $env:FYKE_BIN daemon stop`.

## Window chrome

Run these on Windows 11 if you can, then repeat steps 1 to 3 on Windows 10.

1. Start Fyke. The top right of the window shows minimize, maximize and close in the Windows style. Hover each: minimize and maximize get a faint grey, close turns red with a white cross. Click minimize, restore from the taskbar, click maximize: the glyph changes to restore and its tooltip reads Restore. Click it again to restore, then click close. The window closes and the daemon keeps running (`fyke status`).
2. Drag the window by empty space at the top of the sidebar and of the article list. It moves. Double-click the same space: it maximizes; double-click again: it restores. Click the sidebar's rows, the search field and the reader's buttons in the top strip: each acts as usual and the window does not move.
3. Drag the window to the left and right edges and to a corner: it snaps to half and quarter of the screen. Press Win+Left, Win+Right and Win+Up. On Windows 11, drag it to the top of the screen and drop it on a layout in the snap bar, and press Win+Z. Record whether the layout flyout appears when hovering maximize; it is expected not to (D3, planned).
4. Resize the window from each of its four edges and corners. The cursor changes at each edge, and the layout follows without flicker.
5. Set display scaling to 100 %, 150 % and 200 % (sign out if Windows asks). At each, check the buttons are sharp, the glyphs are centred, and the reader's actions stay to the left of the buttons.
6. With two monitors at different scaling, drag the window from one to the other and maximize it on each. It fills the monitor it is on, and nothing is blurred after the move.
7. Turn on a contrast theme. The three buttons and their glyphs stay visible, and hover shows the highlight colour.
8. Press Ctrl+P, Ctrl+U, F5, F7, F12 and Ctrl+Shift+I, then hold Ctrl and turn the mouse wheel. Nothing happens: no print dialog, no source, no reload, no caret, no developer tools and no zoom. Ctrl+Q does nothing on Windows; Alt+F4 closes the window.

## Linux desktop

On a GNOME (Wayland) and a KDE Plasma machine, with the AppImage or `.deb` once they exist, or `bun run tauri dev` until then:

1. The top right shows three round buttons, close last. Minimize, maximize and restore, and close work.
2. Drag the window by the top strip and double-click it, as in step 2 above. On GNOME, drag it to the top and side edges and check it tiles.
3. Resize from each edge and corner.
4. Press Ctrl+Q. Fyke quits.

## Notifications and single instance

Use the installed app once phase 8 has an installer, since the daemon only starts an app that sits beside it. Until then, set `FYKE_NOTIFIER` to the full path of `Fyke.App.exe` before starting the daemon.

1. Start Fyke. Make a routine whose action is Notify, for a view that has unread articles, and click Run now. One notification appears, titled Fyke, reading "A routine has something for you". Click it: Fyke comes forward.
2. Close Fyke, leaving the daemon running, and run the routine again with `& $env:FYKE_BIN` (or wait for its schedule). After about two seconds a notification appears and no Fyke window opens. Task Manager shows one `Fyke.App.exe` for at most a minute, then none.
3. Repeat step 2 and click the notification within the minute. Fyke opens on its usual screen.
4. With Fyke open, start it again from the Start menu or by running `Fyke.App.exe`. No second window opens, and the first comes forward, also when it was minimized.
5. With Focus assist (Do not disturb) on, run the routine. Nothing interrupts, and the notification is in the notification centre afterwards.

On Linux (GNOME), repeat steps 1 to 4 with `fyke-app`. In step 2 the process also ends when the notification is dismissed.

## Later phases

Narrator, IME and installer upgrades and uninstalls are planned. Their checks belong here when the corresponding features are available.
