# Windows GUI

Status: W0 only. The solution, protocol client, view-model library, token generation and an empty window are the first slice; the reading screens and the feature flows in [reader-features.md](reader-features.md) come slice by slice, as the table at the end records. Windows CI compiles the app and runs the client and view-model tests. Desktop launch, rendering, and interaction remain unverified. The macOS GUI in `gui/` is the reference client.

## Goals

- A native Windows 11 reader with the same three panes, rules and features as the macOS app, following [design-rules.md](design-rules.md) and the Windows 11 board (11) on the [v2 design page](https://app.paper.design/file/01M6R7CJ81MKH0TMWJ8KNC6QGX/p-9-0).
- The same daemon, protocol and data. The GUI is a client of `fyke.exe` over the existing socket and never opens the database.
- Installs per user without administrator rights.

Not goals: a shared UI framework with macOS, an embedded web view for article bodies, Windows 10 support before it is tested, ARM64 before x64 passes.

## Stack

| Choice | Reason |
|---|---|
| C# on .NET 10 (LTS) | First-class Windows App SDK support; the protocol library also builds and tests on macOS and Linux, so CI and contributors without Windows can run its tests. |
| WinUI 3 (Windows App SDK 1.8), unpackaged | Native Fluent controls, Mica, system theme and accessibility; unpackaged keeps the per-user install and CLI on `PATH` simple. MSIX is a later option. |
| MVVM with CommunityToolkit.Mvvm | View models hold all state and logic, so they are unit-tested without a window. |
| xUnit | Tests for the protocol client, view models and token mapping. |

The toolkit choice is recorded as a decision once the reading slice passes its gate, as [implementation-plan.md](implementation-plan.md) requires.

## Projects

```
gui-windows/
  Fyke.Windows.sln
  Directory.Build.props        shared settings: nullable, warnings as errors, analyzers
  src/Fyke.Client/             net10.0: protocol, DTOs, events, daemon discovery. No UI.
  src/Fyke.ViewModels/         net10.0: view models and pure logic (indent, sentences, undo, palette)
  src/Fyke.App/                net10.0-windows10.0.22621: WinUI 3 app, XAML views, tokens
  tests/Fyke.Client.Tests/     xUnit, runs on every OS, includes a fake daemon
  tests/Fyke.ViewModels.Tests/ xUnit, runs on every OS
```

Only `Fyke.App` depends on Windows. Everything a test can reach without a window lives in the other two.

## Talking to the daemon

`Fyke.Client` speaks the same newline-delimited JSON-RPC as `gui/Sources/Reader/Daemon.swift`:

- **Discovery.** The data folder is `%LOCALAPPDATA%\Fyke`, or the folder named in its `location` pointer file, or `FYKE_HOME`; the socket is `fyked.sock` inside it, exactly as `src/main.zig` resolves it.
- **Transport.** `System.Net.Sockets.Socket` with `AddressFamily.Unix` and `UnixDomainSocketEndPoint`, which Windows 10 1803 and later support. No named pipe or TCP port is added.
- **Connections.** One for requests, one for the event stream, so a long call never delays events.
- **Lost replies.** The client reconnects and only replays operations explicitly known to read. For other operations it reports an unknown outcome so the caller can refresh before retrying.
- **Limits.** Lines over 16 MiB are refused; every call takes a `CancellationToken` and a timeout.
- **Starting the daemon.** If the socket does not answer, the app starts `fyke.exe daemon` from its own folder (or `PATH`) without a console window and retries with backoff. The daemon's lock keeps a second copy from starting.
- **Versions.** The app reads `api_version` from `stats.get` and shows an inline state if it is older than the app needs.
- **Reconnects.** Events resume from the last `seq`. The daemon sends no gap marker, so the client detects one itself (event numbers run consecutively; the daemon also prunes events older than 7 days) and yields a `DaemonEvent` of type `events.gap`, on which the app reloads its lists.
- **Folder agreement.** The app starts `fyke daemon --home <folder>`, so the app and daemon always use the same folder, including after a data move.

## Design tokens

`tools/gen_tokens.py` also writes `gui-windows/src/Fyke.App/Themes/Tokens.xaml`: colors as `Color` and `SolidColorBrush` resources in `Light` and `Dark` theme dictionaries, radii as `CornerRadius`, and font families. As with Swift, the XAML is generated and never edited. Inter, Newsreader and JetBrains Mono come from `gui/Fonts` and are bundled with the app.

## Planned layout on Windows

The structure and measurements follow the design rules; the chrome is Windows:

- The window uses Mica and an extended title bar; the sidebar sits on Mica and the list and reader on the ground color.
- Panes are 232 / 368 / flexible, and the reading column is 640.
- Sidebar rows are 32 high with 14 px Segoe Fluent Icons; indent is `10 + 22 × depth`.
- The ⌘ shortcuts become Ctrl: Ctrl+K palette, Ctrl+S save as view, Ctrl+Z undo, Ctrl+F search.
- Focus visuals use the system focus ring. High contrast themes replace the token colors with system colors.
- Popovers are `Flyout`s styled with the popover radius and shadow.

## Planned article reader

The reader will render article blocks with native controls: `RichTextBlock` paragraphs with inline links, lists, quotes, code in JetBrains Mono, tables in a `Grid`, and images that load on request. Feed HTML never reaches a web view, as [decision 0002](decisions/0002-web-viewer.md) requires. Links open in the default browser.

## Background running and notifications

Today `fyke service install` registers the daemon in the per-user Run key. The GUI keeps that: closing the window leaves the daemon running. Supervision after a crash, and notifications with every window closed, are planned slices (W4 below) with their own design.

## Testing

| Layer | How |
|---|---|
| Protocol client | xUnit against an in-process fake daemon on a temporary Unix socket, on every OS in CI |
| View models | xUnit, no window: indent, sentence editing, undo stack, palette matching, state messages |
| App | Built on `windows-latest` in CI. Planned UI Automation smoke test launches the app with `FYKE_HOME` and a real `fyke.exe`. |
| Manual | Narrator, keyboard only, 100/150/200% scaling, light/dark/high contrast, non-Latin text, data move |

## Delivery

| Slice | Contents | Gate |
|---|---|---|
| W0 | Solution, client library, fake daemon, token generation, CI build, empty window that connects | Tests pass on every OS; the app connects, reconnects after the daemon is killed, and shows the inline state when it cannot |
| W1 | Sidebar, list, reader with blocks, search, marks, themes, keyboard | Daily reading works with Narrator and at 200% |
| W2 | Add feed, folders, OPML, settings, storage and data move | Everything the macOS settings offer |
| W3 | Views, Today, recipes, routines, Ask, catch-up, Activity, palette | The flows in reader-features.md, with the same operations as macOS |
| W4 | Crash supervision, notifications with the window closed | Survives crash, sign-out and upgrade |
| W5 | Installer, update, uninstall, release CI | Clean-machine install on Windows 11 |
