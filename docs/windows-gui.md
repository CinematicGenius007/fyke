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

## Size

The published app is self-contained and compiled ahead of time (Native AOT), so it needs no .NET or Windows App SDK install and starts without a JIT. It references only the Windows App SDK components it uses, WinUI and Foundation; the SDK's metapackage would add about 45 MB of machine learning, AI and Widgets runtimes. Nothing reads types by reflection: the daemon's JSON goes through a System.Text.Json source-generated context, and XAML binds with `x:Bind`. The libraries set `IsAotCompatible`, and the app fails the build on trimming and AOT warnings.

CI publishes the app once, runs the desktop smoke test against that copy, and fails when it outgrows its budget of 70 MB on disk or 28 MB zipped. The step summary lists the largest files. In November 2026 the app measured 63 MB on disk and 25.5 MB zipped, down from 139 MB and 52 MB.

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

`tools/gen_tokens.py` also writes `gui-windows/src/Fyke.App/Themes/Tokens.xaml`: colors as `Color` and `SolidColorBrush` resources in `Light` and `Dark` theme dictionaries, radii as `CornerRadius`, and font families. It also writes `gui-windows/src/Fyke.ViewModels/Tokens.g.cs`, the same colors as RGBA constants, from which `ReaderPalette` derives every theme. As with Swift, the generated files are never edited. Inter, Newsreader and JetBrains Mono come from `gui/Fonts` and are bundled with the app; the generator fails if a bundled copy differs from its original.

`App.xaml` loads the standard WinUI control resources before the generated tokens so native templates can resolve their theme resources and Fyke's tokens take precedence.

## Reader layout on Windows

The structure and measurements follow the design rules; the chrome is Windows:

- The window uses Mica and an extended title bar; the sidebar sits on Mica and the list and reader on the ground color.
- Panes are 232 / 368 / flexible, and the reading column is 640.
- Sidebar rows are 32 high with 14 px Segoe Fluent Icons; indent is `10 + 22 × depth`.
- Ctrl+F opens search, Ctrl+K opens the command palette, Ctrl+Shift+K marks the current scope read, and Ctrl+Z undoes the last bulk mark. In search, Ctrl+S saves the search as a view.
- Focus uses native controls. The system high contrast resource mapping and visual acceptance checks are planned.
- Planned popovers use native flyouts with the shared popover treatment.

The sidebar and timeline use native lists. The catalog groups feeds by folder and aggregates unread counts. Selecting a destination requests a 100-article page using the daemon’s feed, folder, starred, or saved-view filter. Load more passes the returned keyset cursor back to the daemon. Navigation cancels stale requests. Entry events, catalog events, and replay gaps trigger a batched reload. Reconnect refreshes the catalog and timeline. The lists apply changes by row identity so unchanged rows and the open article stay in place while they are still in the result. The reader pane displays the selected article’s title, source, and stored body. Changing selection cancels the previous body request.

The folder row opens its timeline. Its disclosure button expands or collapses descendants while preserving the active feed and article. Folder unread counts include collapsed descendants. The window restores `ui.collapsedFolders` before showing the catalog and saves changes through the daemon. Writes run in order so a rapid toggle saves the latest state. Reloading a catalog prunes IDs for folders that have been removed. The window gives an in-flight disclosure save up to one second to finish on close.

## Article reader

The reader requests `entries.get` in blocks format and renders the stored nodes with native controls. Paragraphs use selectable text and inline links. Lists, quotes, headings, code, tables, and separators keep their structure. Images have an explicit load control by default. Feed HTML never reaches a web view, as [decision 0002](decisions/0002-web-viewer.md) requires. Links open in the default browser.

The reader loads saved reading, title, interface, and code weights from `ui.weights` through `config.get` when the window first connects. Each preference shifts its baseline weight by up to two steps, using the same profile fields and steps as macOS. Missing or invalid fields use the role's default. Emphasized body text starts at semibold before applying the reading preference.

An article with a Hacker News discussion offers **Show comments** below its body. Press **C** or follow an inline link to the article's own thread to jump there. The client calls `entries.discussion` on demand, then shows returned blocks in a virtualized list inside the reader's scroll area. Readers can collapse a comment and its replies, retry a failed load, and open the full thread in their browser. Other discussion addresses open in the browser. Changing articles clears discussion state and cancels an in-flight request.

Opening an article marks it read after its body loads. The reader toolbar and the **M** and **S** shortcuts change read and star state through `entries.mark`. The daemon publishes the changes to the timeline and sidebar counts. Removing a star while viewing Starred removes the row and keeps the article open. The toolbar shows the confirmed state and reports a failed change alongside the actions.

The single-key commands match macOS and the terminal app: **J** and **K** open the next and previous article, **N** the next unread one, **U** shows unread articles only (a saved view keeps its own rule) and keeps the open article while it is read, **O** opens the article's page in the browser (Shift+O too, as Windows has no in-app page view yet), **F** fetches the full article through `entries.fetch_full` and shows it again when that found more, **A** adds a feed, **T** opens text size and spacing, and **/** opens search. Each is ignored while an overlay or Settings covers the reader. The palette lists the same commands. **/** is read from key presses rather than a `KeyboardAccelerator`, which can fail fast formatting an OEM key, as with Ctrl+,.

**Mark all read** is available for All, folders, feeds, and saved views from the timeline, the sidebar context menu, or Ctrl+Shift+K. It scans up to 20,000 articles through the scope's cursor, then writes atomic batches of unread IDs through `entries.mark_many`. The notification offers Undo for acknowledged changes, including when later batches fail. Undo restores only the articles that were unread at the time of the write and keeps its remaining batches after an interrupted restore. The window keeps the last 100 undo actions available through Ctrl+Z after the notification closes.

## Search

The timeline search button and Ctrl+F open the search panel. It uses `entries.search` for titles, body text, and feed names, shows the newest 100 matches with highlighted snippets, and offers an unread-only filter. Up and Down move between results from the search field, Enter opens the selected article, and Escape closes the panel and returns focus. Opening a match leaves the current destination selected, including when the result is outside it. Editing the query, closing search, or disconnecting cancels any pending search.

## Saved views

**Save view** in Search opens the editor with the current words and reading state. **New saved view** in All's context menu and in the command palette opens a blank rule. The editor supports reading state, words, feed and folder selection, article host and paths, and a date window. Preview asks `views.preview` for exact total and unread counts without writing a view.

Saved views appear below Starred in daemon order and also appear in the palette. Their timelines show the daemon's rule sentence and load articles through `entries.list` with `view_id`. An article stays open when a mark removes it from the timeline. The timeline edit button and the view's context menu reopen the rule. Updates use the last read revision through `views.put`. A stale revision leaves the latest rule in place and prompts the editor to reload it on close. View events refresh the sidebar and current timeline after changes from MCP or another window.

Use a view's sidebar menu to reorder or delete it. Deletion asks for confirmation and, if the daemon reports linked routines, asks separately before disabling and detaching them. Undo for view creation, editing, and deletion is planned.

## Today and briefs

Today is the first sidebar row. Its list pane shows the briefs, newest first, with a writing row while a writer runs. The reader shows the chosen brief: its claims with numbered citations, the sources, and the writer and recipe that made it. Hovering a citation shows its article in a popover; clicking pins the popover, and **Open article** opens it in the reader with a **Brief** button to return. Opening Today never runs a writer. The toolbar button and Ctrl+R in Today write a brief of the chosen brief's view, or of unread articles, with the chosen brief's recipe.

When there is no brief to show, Today says why in place: writing (with Cancel), failed in the last day (with Try again), empty, or an older service that has no `briefs.*` methods (with Restart the service). A brief written after a job started or failed is newer news and shows instead. The sidebar row shows a spinner while a brief is written and a dot for a newest brief not yet seen. `job.changed`, `artifact.new` and `recipe.changed` events reload Today wherever the reader is. J and K move through the briefs.

A recipe opens in place of the brief from **Edit recipe** under a brief, the **Recipe** button in Today, or "Edit the … recipe" in the palette, as on macOS. **Edit** saves the text as a new revision (Ctrl+S) with `recipes.put` and its `expected_revision`; opened from a brief, saving writes that brief again with the new recipe. A revision saved elsewhere meanwhile is a conflict that keeps the edits and offers **Keep mine** or **Use the newer one**. A built-in recipe can be reset to its built-in text, which adds a revision. **Try it** writes a trial with the unsaved text over the brief's articles with `briefs.try`; the trial is not listed in Today. **History** lists revisions newest first, opens each one's text, and can put an older text back in Edit. Escape leaves a recipe without unsaved edits. The model is in `Fyke.ViewModels/Recipes.cs`. The recipe names the writer that will use it.

## Routines

**Routines** at the foot of the sidebar (Ctrl+4, or the palette) shows the soonest run, as "Next 07:30". It opens a page over the list and the reader, as Settings does: the routines on the left and the chosen one on the right, as on macOS. A routine reads as three lines. **When** is every weekday, every day, every Monday, every Friday, or only when run, at a half hour. **Look in** is a saved view, for articles new since the last run. **Then** lists its actions: write a brief with a recipe (naming the writer that will write it), notify, mark read, star, or tag. **New routine** starts from the view being read, or the first view, named "Morning …", weekdays at 07:30, with a brief and a notification. **Make it a routine** under an Ask answer starts one named for the question, over the view it asked. A new routine stays in the list as "(not saved)" until saved.

Save (Ctrl+S) uses `routines.put` with the last read revision. A routine changed elsewhere keeps the edits and saves over the newer revision on the next save. The switch in each row pauses or resumes a routine at once. **Run now** queues its actions with `routines.run`. **Dry run · last week** shows what `routines.dry_run` says it would have caught each day, as a sentence and seven bars. **Remove** offers Undo, which saves a copy again. Choosing a place in the sidebar or Escape leaves the page. `routine.changed` events reload the list wherever the reader is. Routines run in the service, even with the window closed. The model and its words are in `Fyke.ViewModels/Routines.cs`. A failed run shows in Activity, which is planned.

## Ask and Catch up

Ask your feeds (Ctrl+Shift+A, the palette, or "Ask your feeds: …" for what is typed in the palette) covers the article pane, as on macOS. It asks over the saved view being read, or every feed, with `ask.run`, and follows the job through the job list Today already reloads on each `job.changed`. When the job is done it reads the answer with `answers.get` and draws it with the brief renderer, so each claim cites its articles the same way. A follow-up names the question before it. A failed or cancelled job says why, with Ask again. Copy puts the answer and its numbered sources on the clipboard. Back, Escape, choosing a place, or opening an article closes Ask. While Ask is shown, single-key commands are off, so typing a question never marks or moves anything. The ask logic and its words are in `Fyke.ViewModels/Asking.cs` and tested without the GUI.

Catch up (Ctrl+J, the sidebar button, the palette, or a folder's menu) shows the unread articles of the place being read, one card at a time, over the whole window. Today means All. Left skips (marks read), Down saves for Later, Right or Enter reads now, which closes Catch up and opens the article. Ctrl+Z undoes the last choice and puts back the article's earlier read and later state from `entries.mark_many`'s `previous`. Escape closes it, and the list reloads if anything was marked. The queue holds up to 500 unread articles. The session and its words are in `Fyke.ViewModels/CatchUp.cs`.

## Command palette and focus

Ctrl+K or the command button in the sidebar opens the palette. It matches typed letters against destinations and available reader actions, with up to four article matches through `entries.search`. Feed and folder destinations remain searchable when hidden by a collapsed parent. Search and the palette share Up, Down, Enter, Escape, and focus restoration. F6 and Shift+F6 move forward and backward between the sidebar, timeline, and article reader, or between the sidebar and the routine list while Routines is open.

## Adding a feed

The sidebar's add button, Ctrl+N, and the palette open the add-feed sheet. Pausing after typing or pasting a site or feed address starts discovery through `feeds.preview`. The sheet shows candidate feeds and their latest titles. Choose one or more feeds and an existing folder, and optionally give a single feed a display name. The daemon blocks private addresses by default. If it refuses a private address, the sheet offers an explicit local-network lookup for that address.

`feeds.add` creates each selected subscription. `feeds.update` places it in the chosen folder. If adding or placing a feed fails partway through a group, Retry resumes at the first unconfirmed step. The sheet reports any confirmed subscriptions and lets the reader choose another folder for the remaining placements. Opening the sheet from a folder's context menu preselects that folder.

## Organizing subscriptions

The sidebar context menus create top-level or nested folders and open a compact editor to rename or move a feed or folder. The palette can create a top-level folder and edit the current feed or folder. The move picker shows full folder paths and omits a moving folder and its descendants. Clearing a feed's custom name restores the feed's own title. The daemon validates names and moves, and the sidebar reloads by ID after a save so the active destination remains open.

**R**, the palette, and the sidebar context menus refresh feeds. From a feed, **R** fetches that feed and reports its result at the foot of the sidebar. From a broader destination, it queues all feeds.

Removing a subscription confirms the permanent loss of its saved articles and marks. Deleting a folder keeps its contents by default and moves them to its parent or the top level. An explicit option deletes the entire subtree, including its saved articles. The reader closes an article whose feed was removed and returns to All if its destination disappeared.

## Importing and exporting OPML

Settings, the All context menu, and the command palette offer import and export. Import is also available in the add-feed sheet. The Windows file picker accepts `.opml` and `.xml`. The app passes the chosen path to `opml.import`, then refreshes the catalog and reports how many subscriptions were added and how many already existed. The daemon imports the folder structure and fetches new feeds in the background using its default network rules.

Export requests the document through `opml.export`. The save picker suggests `feeds.opml` and confirms overwrites. The app writes UTF-8 to a temporary file beside the destination and replaces the destination only after writing succeeds. Windows App SDK 1.8 can create an empty file at a newly selected path before Fyke saves the document. Canceling either picker leaves the current screen and files intact.

## Settings

The gear at the foot of the sidebar, Ctrl+, and the command palette open Settings over the timeline and reader. The sidebar stays visible. Escape or the close button returns to the same article and timeline. Selecting a destination closes Settings and opens that destination. F6 moves between Settings and the sidebar. General, Reading and Agents share the same selector, and reopening Settings returns to its last tab.

General settings offer full-article fetching, automatic article image loading, OPML, and the shortcut list. Automatic image loading is off by default. The saved preference also applies to the current article, and images explicitly opened by the reader stay visible when automatic loading is disabled. The full-text setting uses `config.set`. Image loading updates `ui.loadImages` through a field-level `ui_patch`. Fyke reads back the stored value after a write and reports unreadable settings inline.

Reading offers Much lighter, Lighter, Normal, Bolder, and Much bolder for Reading, Titles, App, and Code. Each change patches only its named role under `ui.weights`. The open article and rendered discussion text bind to the same font-weight values as the other reader controls, so a confirmed change applies without reopening the article.

Reading also controls body text size (14–28), line spacing (1.2–2.0), and article column width (480–800). The preview updates the existing article and discussion controls. Short bursts of slider movement save together through `ui_patch`; closing Settings or switching tabs submits pending values. The daemon preserves other interface settings and the app reads back the saved values.

Show scrollbars offers While scrolling, Always, and Never under Reading. It saves `ui.scrollbars` and applies to vertical bars in the sidebar, timeline, article, search, palette, and Settings. While scrolling uses Windows' automatic indicator behavior. Never hides the bars and allows wheel, touch, and keyboard scrolling.

Appearance offers Light, Dark, Newsprint, Terminal and the user's own themes from `ui.themes` for the fixed, day, and night slots. The fixed choice turns off system following. Follow system appearance uses the day or night slot when Windows changes its app appearance. `ReaderPalette` builds each theme as `gui/Sources/Reader/Theme.swift` does: Newsprint and Terminal from their three Paper colors, mixed toward black in Oklab like SwiftUI's `Color.mix`, and a custom theme as its built-in base with its saved colors on top. The window writes the active palette into the shared token brushes of the Light or Dark dictionary, so a change repaints without rebuilding anything. A theme that no longer exists shows as Light, as on macOS. Windows handles the system high contrast override. Not yet matched: Terminal's typeface (macOS sets reading and titles in JetBrains Mono) and a custom theme's own fonts and radii. Creating and editing themes is done on macOS for now.

Agents, the third tab, matches the macOS Agents pane. **Who writes your briefs** lists Codex and Claude Code from `writers.list` with each one's status (its problem, "Not found on this PC", or its version and path). **Check** runs `writers.check` again, and **Make default** saves `ai.writer` with `config.set`. When Claude Code is installed, a profile row shows the folder that holds its sign-in; **Choose…** opens the Windows folder picker and saves `ai.claude_profile`, and **Use default** clears it. **Let agents use Fyke** saves what agents connected over MCP may change as `ui.agentTier` (Never, Reading state only, Everything), and **Copy MCP config** copies the configuration that starts `fyke.exe mcp` with that tier. A failed brief in Today offers **Choose a writer**, which opens this tab. The model is in `Fyke.ViewModels/Writers.cs`.

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
| W1b.3 | Folder disclosure and stable navigation when descendants are hidden | View-model tests check nested collapse and unread totals. The desktop smoke test checks collapse and expand with an open article |
| W1b.4 | Apply saved reading, title, interface, and code weights | Profile and weight mapping tests, plus Windows UI Automation checks for article title and paragraph weights |
| W1b.5 | On-demand discussion, reply disclosure, and the C shortcut | Windows smoke test for a failed load, retry, nested replies, and another provider's link. Manual keyboard, Narrator, and scrolling checks |
| W1c.1 | Search, unread filtering, and opening a result without leaving the current destination | API and snippet tests, Windows smoke test for filtering and opening a result, manual keyboard and focus checks |
| W1c.2 | Read and star marks, including mark-on-open | API tests for preserving the untouched flag, plus Windows smoke coverage for marking, filtering, and retaining the open article |
| W1c.3 | Bulk mark-as-read and Undo | View-model tests for scope paging and interrupted batches, and Windows smoke coverage for restoring the affected unread article |
| W1c.4 | Command palette and reader focus | Matching tests, Windows smoke coverage for navigating to a hidden feed and opening an article, manual keyboard and focus checks |
| W2a | Feed discovery, preview, and subscription with folder placement | API tests for selections and retry, and Windows smoke coverage for discovering two feeds and subscribing to one |
| W2b | Create, rename, and move feeds and folders | Folder-path and operation tests, plus Windows smoke coverage for creation and rename with an open article |
| W2c | Subscription refresh and removal | Operation and removal-scope tests, plus Windows smoke coverage for refresh, canceled removal, subscription removal, and keeping folder contents |
| W2d | OPML import and export | Operation and file-write tests, daemon round-trip with nested folders, manual Windows checks for picker cancellation and overwrite confirmation |
| W2e.1 | Settings navigation and General preferences | Profile and daemon patch tests, Windows smoke coverage for changing settings and returning to the open article |
| W2e.2a | Reading tab and saved font weights | Wire and write tests preserve other roles. The Windows smoke test changes the weight on an open article |
| W2e.2b | Article text size, line spacing, and column width | Profile and patch tests. Windows smoke changes the sliders and verifies the saved values and the open article's text size |
| W2e.2c | Scrollbar visibility | Profile and patch tests. Windows smoke changes the saved mode and checks that overflowing Settings content still scrolls |
| W2e.2d | Persistent folder disclosure | Profile tests and Windows smoke coverage for relaunch, keeping the open article, and pruning the saved folder after deletion |
| W2e.2e | Light and Dark appearance with system following | Profile and patch tests. Windows smoke changes the fixed theme and checks the open article uses its colors |
| W2e.2f | Newsprint, Terminal, and custom colors; typeface and radii planned | Reopen a profile with saved themes. Compare palettes, fonts, and narrow and wide layouts with macOS |
| W2e.3 | Planned Agents settings and MCP configuration | Detect installed Codex, exercise missing and signed-out states, and paste a working MCP configuration |
| W2e.4 | Planned storage and data move | Clean-profile and existing-profile tests, failed moves leave existing data usable |
| W2e.5 | Planned General background updating and link destination controls | Runtime and login behavior with W4, plus safe native link routing and browser fallback |
| W3a | Saved-view creation, preview, timeline, edit, reorder, and removal | Model tests for rule round-trip, revision, scope and removal. Windows smoke covers Search through creation, preview, edit and removal. Visual review and view undo are open |
| W3b | Routine list, editor, dry run, run now and Make it a routine done; failed runs wait on Activity | Model tests for the wire, editing and words. Windows smoke makes, saves, removes and restores a routine, then deletes its view. Verify combined actions and their results, including failed or partial runs |
| W3c | Today, briefs, citations, recipes and writer choice done | Run a brief from a view, edit and preview its recipe, reopen the result, and follow citations in Windows |
| W3d | Ask and Catch up done; Activity planned | Verify question and catch-up inputs, cited results, live job state, and failure or cancellation |
| W4 | Restart supervision, notifications and activation | Close the window, crash and restart the daemon, sign out/in, deny notification access, reopen the right result |
| W5 | Versioned GUI/core bundle, runtime dependencies, signing, installer, upgrades, uninstall and release notes | Clean Windows 11 x64 standard-user install, upgrade from a prior build, rollback and uninstall with data retention, verified published checksums |

Profile isolation is a manual release check. On a controlled Windows host, run `pwsh -File gui-windows/tests/account-isolation.ps1 -Daemon <path-to-fyke.exe>` from an elevated session that can create a local user and register an S4U task. The script checks access with the second account and removes the temporary task and account. Hosted Windows CI denied task registration before the probe ran, so cross-account isolation is still unverified. The check covers inherited permissions under the local profile. Access controls on user-selected data locations remain a separate release check.

Release evidence records the tested OS build, display scaling, app and daemon versions, launch method, and results. Review compatibility with the installed Codex and other supported writers on Windows separately from the fake-writer tests. When an embedded remote page viewer is considered, apply [decision 0002](decisions/0002-web-viewer.md) to its address-only boundary.
