# Windows GUI

Status: the Windows reader shell connects to the daemon and shows the subscription catalog and article timeline. The solution, protocol client, view-model library, and generated tokens support the shell. Article selection opens stored blocks in a native reading pane. The feature flows in [reader-features.md](reader-features.md) are planned. Windows CI compiles the app and runs the client and view-model tests. Windows desktop CI has verified launch, the missing-companion Retry flow, and daemon restart after a crash with the window open. The Windows smoke test exercises Starred selection and opens an article from a local feed fixture. It checks that an article image makes no network request until asked. Visual comparison of the reader remains a separate check. The macOS GUI in `gui/` is the reference client.

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
- **Connections.** A bounded pool serves requests. The event stream has a dedicated connection.
- **Lost replies.** The client reconnects and only replays operations explicitly known to read. For other operations it reports an unknown outcome so the caller can refresh before retrying.
- **Limits.** Lines over 16 MiB are refused; every call takes a `CancellationToken` and a timeout.
- **Starting the daemon.** If the socket does not answer, the app starts `fyke.exe daemon` from its own folder (or `PATH`) without a console window and retries with backoff. The daemon's lock keeps a second copy from starting.
- **Versions.** The app reads `api_version` from `stats.get`. On initial connection with its bundled executable, it requests one graceful shutdown of an older daemon and checks the replacement before using it. An incompatible daemon that remains after that attempt produces an inline update state. Automatic reconnects and custom executable configurations leave version replacement to the user.
- **Reconnects.** Events resume from the last `seq`. The daemon sends no gap marker, so the client detects one itself (event numbers run consecutively; the daemon also prunes events older than 7 days) and yields a `DaemonEvent` of type `events.gap`, on which the app reloads its lists.
- **Folder agreement.** The app starts `fyke daemon --home <folder>`, so the app and daemon always use the same folder, including after a data move.

## Design tokens

`tools/gen_tokens.py` also writes `gui-windows/src/Fyke.App/Themes/Tokens.xaml`: colors as `Color` and `SolidColorBrush` resources in `Light` and `Dark` theme dictionaries, radii as `CornerRadius`, and font families. As with Swift, the XAML is generated and never edited. Inter, Newsreader and JetBrains Mono come from `gui/Fonts` and are bundled with the app.

## Reader layout on Windows

The structure and measurements follow the design rules; the chrome is Windows:

- The window uses Mica and an extended title bar; the sidebar sits on Mica and the list and reader on the ground color.
- Panes are 232 / 368 / flexible, and the reading column is 640.
- Sidebar rows are 32 high with 14 px Segoe Fluent Icons; indent is `10 + 22 × depth`.
- Planned keyboard mappings use Ctrl: Ctrl+K palette, Ctrl+S save as view, Ctrl+Z undo, Ctrl+F search.
- Focus uses native controls. The system high contrast resource mapping and visual acceptance checks are planned.
- Planned popovers use native flyouts with the shared popover treatment.

The sidebar and timeline use native lists. The catalog groups feeds by folder and aggregates unread counts. Selecting a destination requests a 100-article page using the daemon’s feed, folder, or starred filter. Load more passes the returned keyset cursor back to the daemon. Navigation cancels stale requests. Entry events, catalog events, and replay gaps trigger a batched reload. Reconnect refreshes the catalog and timeline. The lists apply changes by row identity so unchanged rows and the open article stay in place while they are still in the result. The reader pane displays the selected article’s title, source, and stored body. Changing selection cancels the previous body request.

## Article reader

The reader requests `entries.get` in blocks format and renders the stored nodes with native controls. Paragraphs use selectable text and inline links. Lists, quotes, headings, code, tables, and separators keep their structure. Images have an explicit load control. Feed HTML never reaches a web view, as [decision 0002](decisions/0002-web-viewer.md) requires. Links open in the default browser.

## Background running and notifications

Today `fyke service install` registers the daemon in the per-user Run key. The GUI keeps that: closing the window leaves the daemon running. Supervision after a crash, and notifications with every window closed, are planned slices (W4 below) with their own design.

## Testing

| Layer | How |
|---|---|
| Protocol client | xUnit against an in-process fake daemon on a temporary Unix socket, on every OS in CI |
| View models | xUnit for connection state and retry behavior. Each new flow adds tests for its presentation state. |
| App | Built on `windows-latest` in CI. The CI smoke script launches WinUI with an isolated `FYKE_HOME`, checks the missing-companion state, then uses UI Automation to retry after placing the real `fyke.exe` beside the app. |
| Manual | Narrator, keyboard only, 100/150/200% scaling, light/dark/high contrast, non-Latin text, data move |

Run the client integration check with `FYKE_TEST_BIN` set to the absolute path of a built `fyke` or `fyke.exe` and run `dotnet test gui-windows/tests/Fyke.Client.Tests`. Windows CI runs this check against its release build. The test uses a temporary data directory and removes it after stopping the daemon.

## Delivery

| Slice | Contents | Gate |
|---|---|---|
| W0 | Solution, client library, fake daemon, token generation, CI build, empty window that connects | Tests pass on every OS; the app connects, reconnects after the daemon is killed, and shows the inline state when it cannot |
| W1 | Sidebar, list, reader with blocks, search, marks, themes, keyboard | Daily reading works with Narrator and at 200% |
| W2 | Add feed, folders, OPML, settings, storage and data move | Everything the macOS settings offer |
| W3 | Views, Today, recipes, routines, Ask, catch-up, Activity, palette | The flows in reader-features.md, with the same operations as macOS |
| W4 | Crash supervision, notifications with the window closed | Survives crash, sign-out and upgrade |
| W5 | Installer, update, uninstall, release CI | Clean-machine install on Windows 11 |

## Architecture and review standards

Dependencies flow from `Fyke.App` to `Fyke.ViewModels` and `Fyke.Client`. XAML and code-behind own control layout, focus, dispatcher work, and Windows integrations. View models own presentation state and commands and can run without WinUI. The client owns transport, discovery, process startup, wire types, and connection lifetime. The daemon owns data, scheduling, and mutations. Each user-facing capability uses the shared operation registry.

Review one module at a time with these criteria:

- Keep nullable analysis and analyzers enabled. Address handwritten warnings at their source and scope any tooling suppression to the affected code.
- Keep file, socket, process, and time dependencies at the boundary. Test view-model transitions without a window and protocol behavior against both a fake socket and a real daemon.
- Bound asynchronous work and cancel it when its owner closes. Preserve selection and scroll position across updates. Use virtualized article lists and coalesce reloads during event bursts. Measure on a large fixture before making performance claims.
- Use shared tokens and the measurements in [design-rules.md](design-rules.md), including reading weight preferences. Follow [the macOS feature flows](reader-features.md) for navigation, empty states, undo, and citations. Review native keyboard access, Narrator, text scaling and contrast with each screen.
- Comments explain invariants, ownership, and failure handling. Avoid narrating the code or recording review history. Update public interfaces and architecture docs when a contract changes.

## Remaining launch work

Each row is a reviewable unit with evidence required before its gate is complete. The Windows 11 x64 per-user installer is the proposed first launch. Store distribution and additional architectures have separate validation and distribution gates.

| Unit | Work | Evidence |
|---|---|---|
| W0a | Exercise C# startup, handshake, and event replay across the real Windows socket | CI against the built executable with an isolated home |
| W0b | Launch WinUI and recover from a missing companion through Retry | Windows CI desktop smoke test with a real daemon and isolated home |
| W0c | Use the window’s event subscription to recover from a live daemon disconnect | Windows UI Automation confirms the app starts a replacement daemon after a crash |
| W0d | Move data to a path with spaces and non-ASCII characters and reopen it through Windows profile discovery | The C# client reads a saved view written before the move, and the old folder retains only the location pointer |
| W0e | Replace an older daemon at startup with the bundled executable | Client tests verify one shutdown request, a compatible restart, and refusal of an incompatible replacement |
| W0f | Check socket and data access from another Windows account on a controlled Windows host | A separate standard Windows account cannot read or open the database for writing or connect to a daemon under another user’s local profile |
| W1a | Reader shell, feed and folder destinations, Starred, timeline paging and a resizable list divider | API parameter tests, native selection smoke test, and visual checks at narrow and wide widths |
| W1b.1 | Native block rendering with on-demand images and article selection | Shared content fixture, Windows desktop smoke test, and URL handling tests |
| W1b.2 | Live timeline updates and stable article selection | Native smoke test receives an article while the previous one stays open. Unit tests check that unchanged rows retain their identity |
| W1b.3 | Folder collapse, reading weights, and discussion | Keyboard, Narrator, DPI, and scrolling checks |
| W1c | Search, marks, undo, command palette and focus | Same task outcomes as macOS, including reconnect and missing selection |
| W2 | Subscription discovery, OPML, settings, themes, agent setup, storage and data move | Clean-profile and existing-profile tests, failed moves leave existing data usable |
| W3 | Saved views, Today, recipes, briefs, Ask, catch-up, routines, Activity, and citation navigation | One module per flow with fixture-driven API and desktop checks, including failed or partial work |
| W4 | Restart supervision, notifications and activation | Close the window, crash and restart the daemon, sign out/in, deny notification access, reopen the right result |
| W5 | Versioned GUI/core bundle, runtime dependencies, signing, installer, upgrades, uninstall and release notes | Clean Windows 11 x64 standard-user install, upgrade from a prior build, rollback and uninstall with data retention, verified published checksums |

Profile isolation is a manual release check. On a controlled Windows host, run `pwsh -File gui-windows/tests/account-isolation.ps1 -Daemon <path-to-fyke.exe>` from an elevated session that can create a local user and register an S4U task. The script checks access with the second account and removes the temporary task and account. Hosted Windows CI denied task registration before the probe ran, so cross-account isolation is still unverified. The check covers inherited permissions under the local profile. Access controls on user-selected data locations remain a separate release check.

Release evidence records the tested OS build, display scaling, app and daemon versions, launch method, and results. Review compatibility with the installed Codex and other supported writers on Windows separately from the fake-writer tests. When an embedded remote page viewer is considered, apply [decision 0002](decisions/0002-web-viewer.md) to its address-only boundary.
