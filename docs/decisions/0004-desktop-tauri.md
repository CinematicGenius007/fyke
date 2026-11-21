# 0004: One Tauri 2 app for Windows and Linux

Status: accepted, 2026-11-22. Replaces the C# and WinUI 3 plan in [the implementation plan](../implementation-plan.md#windows-first).

## Context

A WinUI 3 app was built in `gui-windows/` and reached most of the macOS app's features (PR #19). It cost more than it gave back:

- Only Windows can compile it, so every change waited on a CI runner. Nothing could be built or run on the Mac where the rest of Fyke is developed.
- The published app was about 76 MB on disk, and each Windows App SDK upgrade raised the size budget.
- Typography fought the toolkit. A font file is one family in WinUI, so italics needed a second family per face.
- Linux would still have needed a second, separate GUI.

## Decision

Windows and Linux get one desktop app built with **Tauri 2**: a Rust shell over the system web view (WebView2 on Windows, WebKitGTK on Linux), with a TypeScript UI. Bun is the package manager, bundler and test runner; it is not shipped. The macOS SwiftUI app stays and is the reference the new app matches.

The WinUI app was removed. Its last full state is commit `bd837fa` on `main` ("Windows GUI in WinUI 3, with installer (#19)"), and the branch `feat/windows-gui` keeps its history. To bring it back: `git checkout bd837fa -- gui-windows tools/windows_installer.py tools/e2e_installer_windows.py tools/gen_windows_icon.py docs/windows-gui.md`.

## What stays true

- The daemon is unchanged and owns all data. The app is a client of its socket, like every other surface.
- **Feed content never becomes HTML in a web view.** The UI builds DOM nodes from the daemon's [blocks](../architecture.md#content-model) and sets text, never `innerHTML` from feed data. Remote pages follow [0002](0002-web-viewer.md): `http` and `https` only, private addresses refused, no bridge from page script to the app, downloads refused, nothing kept after the pane closes.
- The UI has no network access of its own beyond the web viewer; the daemon fetches feeds and images.

## Consequences

- The plan for building it is [the desktop brief](../desktop-tauri-brief.md).

- The UI runs and is tested in a browser on any machine, so most checks need no Windows PC.
- WebView2 uses more memory than a native toolkit. The app keeps size and memory budgets, measured in CI.
- `src/notify.zig` still looks for `Fyke.App.exe --notify` beside `fyke.exe` on Windows. The Tauri app takes over that name or the daemon is changed to match it.
