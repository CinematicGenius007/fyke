# The desktop app for Windows and Linux

`desktop/` holds Fyke's app for Windows and Linux, built with Tauri 2. It matches the macOS app in `gui/` in look and behaviour. [desktop-parity.md](desktop-parity.md) tracks every line of that match, and [ADR 0004](decisions/0004-desktop-tauri.md) says why it is built this way.

The UI is SolidJS in `desktop/src`. The native side, in `desktop/src-tauri`, holds what a web page cannot: the daemon's socket, the data folder, the window, notifications and the system. Like every other client, the app talks to the `fyke` daemon over its local socket ([api.md](api.md)), and it starts the daemon when none is running.

## Build and run

You need Bun 1.4, Rust stable and Zig 0.17.1. On Linux you also need `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `librsvg2-dev` and `patchelf`. On Windows you need the Visual Studio C++ build tools and the WebView2 runtime, which Windows 10 1803 and later include.

```sh
zig build -Drelease                       # the daemon, zig-out/bin/fyke
cd desktop
bun install --frozen-lockfile
FYKE_BIN=../zig-out/bin/fyke bun run tauri dev
```

`FYKE_BIN` names the daemon to start. Without it, the app looks for `fyke` (`fyke.exe` on Windows) in its own folder, which is where the installer and packages put it. `FYKE_HOME` points the app and daemon at another data folder. Use it for anything you try out, so your real data stays untouched.

## Tests

| Suite | Command, from `desktop/` | What it covers |
|---|---|---|
| Unit | `bun run check && bun run test` | Types, the ReaderLogic ports, palettes and settings |
| Rust | `cargo test` in `src-tauri` | Socket, paths, URL guard, notification arguments, the AppImage daemon copy |
| End to end | `bunx playwright test` | Every screen and flow in WebKit and Chromium, against a real daemon through `tools/bridge.ts` |
| Parity | `bun tools/parity.ts` | Compares each screen with the Mac app's picture and writes `zig-out/parity/report.md` |

`python3 tools/check.py` runs these suites when files under `desktop/` change. `--all` runs every suite in the repository.

The Playwright suite runs the UI in a browser against a real daemon. It never opens the app's own window, so it cannot take focus or reach your notifications. The checks that need a real Windows desktop, such as Narrator, contrast themes, snapping and native dialogs, are in [desktop-windows-checklist.md](desktop-windows-checklist.md).

## Packages

```sh
python3 tools/desktop_package.py [--fyke PATH] [--version X.Y.Z] [--out dist]
```

This builds the daemon (unless `--fyke` names one) and then the packages for the system it runs on:

- Windows: `Fyke-<version>-setup-x64.exe`.
- Linux: `fyke_<version>_amd64.deb` and `Fyke-<version>-x86_64.AppImage`.

Tauri builds them with `src-tauri/tauri.bundle.conf.json` on top of the usual configuration. That file adds the daemon as an external binary, so it lands beside the app.

### Windows installer

The installer is Tauri's per-user NSIS installer. `src-tauri/windows/hooks.nsh` adds what the earlier WinUI installer did:

- **No administrator prompt.** It installs for the current user, in `%LOCALAPPDATA%\Programs\Fyke`. Tauri's default folder, `%LOCALAPPDATA%\Fyke`, is Fyke's data folder, so the hooks move the program files out of it.
- **Start menu.** It adds a Start menu entry. A desktop shortcut is a choice on the last page. A silent install adds one too, unless `/NS` is given.
- **Choices on the Welcome page.** One adds `fyke` to PATH. The other keeps feeds up to date in the background from sign-in, which runs `fyke service install`; that also starts the service now. Both are on for a first install. An upgrade keeps the earlier choices, and turning a choice off on an upgrade undoes it.
- **Silent installs.** `/S` installs silently. Add `/ADDTOPATH=0|1` and `/BACKGROUND=0|1` to set the choices.
- **Upgrades.** An upgrade first closes the Fyke installed in that folder, matched by its full path. A copy run from anywhere else is left alone. It then stops the daemon cleanly, replaces the files and starts the service again.
- **Uninstall.** Uninstalling closes the app, removes the service and the PATH entry, stops the daemon and deletes the program files. Every article, feed and setting stays in the data folder.

`tools/e2e_installer_windows.py <older setup.exe> <newer setup.exe>` runs these installs, upgrades and uninstalls silently, with a scratch `FYKE_HOME`. CI builds a 0.0.1 installer for the older one. The test changes the real per-user install, so outside CI it refuses to run where Fyke is installed.

The installer is not signed, so SmartScreen warns the first time. Choose More info, then Run anyway.

### Linux packages

The `.deb` installs `fyke-app` and `fyke` in `/usr/bin`, with a menu entry and icons. It depends on `libwebkit2gtk-4.1-0` and `libgtk-3-0`. Removing the package leaves `~/.fyke` alone.

The AppImage runs from a mount that goes away when the app quits. The daemon outlives the app, and so does the systemd unit that `fyke service install` writes, so the AppImage keeps a copy of `fyke` in `~/.local/share/fyke/bin` and starts that copy instead (`appimage_daemon` in `src-tauri/src/paths.rs`). When the AppImage is closed, a routine's notification has no app beside that copy to start, so it is not posted. Posting it is planned. While the app is open, notifications work as usual.

`tools/e2e_packages_linux.py <deb> <AppImage>` tests both. It installs the `.deb` with apt over an older copy of itself (the same package relabelled 0.0.1), launches the installed app, removes it, and checks that the data stays. It also runs the AppImage and checks the daemon copy. CI runs it under `xvfb-run`.

## Size and speed

`tools/desktop_budget.py` measures four figures on each system:

- the package sizes;
- the program files, which are the app and the daemon;
- cold start, from launch to the first article list drawn (the median of three launches);
- idle memory, the unique memory of the app and its web view processes a few seconds later.

The app runs headless in test mode (`FYKE_MEASURE`), against the GUI checks' data in a scratch folder. Any figure over its budget in `desktop/budgets.json` fails CI. A change that needs more must raise the budget and say why in its pull request.

The measurement on CI, and the budgets set from it:

| Figure | Windows | Budget | Linux | Budget |
|---|---:|---:|---:|---:|
| Package | 4.8 MB setup | 6 | 6.2 MB `.deb`, 81.0 MB AppImage | 8, 90 |
| Program files | 10.0 MB | 12 | 11.4 MB | 14 |
| Cold start | 525–665 ms | 1000 | 408–429 ms | 1000 |
| Idle memory | 144.7–145.8 MB | 175 | 133.1–133.3 MB | 160 |

The ranges are two CI runs. Shared CI runners vary from run to run, so cold start has the most room. The AppImage is larger than the `.deb` because it carries its own WebKitGTK. The Linux packages ship the daemon without its debug information (`strip --strip-debug`), which Zig otherwise keeps in a Linux release build; that took the Linux program files from 28.0 MB to 11.4 MB.

On Linux the checks run under `dbus-run-session`. Without a session bus, as under a bare `xvfb-run`, the web view waits out D-Bus's 25 second timeout before it draws. A desktop session always has a bus.

## Continuous integration and releases

In `.github/workflows/ci.yml`:

- The `desktop` job runs the unit and Rust tests on Windows and Linux, and the Playwright suite on Linux.
- The `desktop-package` job builds the installer on `windows-latest` and the packages on `ubuntu-22.04`, the oldest supported Ubuntu, so the AppImage runs on as many systems as it can. It also runs their end-to-end tests and the budgets, and uploads the packages.

A release tag runs the same checks (`release.yml`). `tools/release.py --desktop` then copies the tested packages into `dist/` beside the command-line archives, and `SHA256SUMS` lists every file the release publishes.
