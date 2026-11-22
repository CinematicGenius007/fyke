# Desktop parity: Windows and Linux against the Mac

This document is the checklist for the Tauri 2 desktop app in `desktop/`, which runs Fyke on Windows and Linux. The SwiftUI app in `gui/` is the reference for look and behaviour, and [design rules](design-rules.md) win over both. The full brief is [desktop-tauri-brief.md](desktop-tauri-brief.md).

## How a line is ticked

Each line has a status:

- **planned**: not built yet.
- **built**: the code exists, but no test or picture proves it yet.
- **done**: proven. The Evidence column names a test (`bun test` case, Playwright scenario, `cargo test` name) or a snapshot pair under `zig-out/parity/`.

A line becomes done only with evidence. "Looks right" is not evidence.

Line ids (F, S, K, U, C, D, X) are stable, so commits and tests can name them.

## Decisions and disagreements

These are choices the brief left open, and the places where the Mac app and the design rules disagree. Where they disagree, the rules win, and the Mac is listed as the bug.

| Id | Topic | Choice | Why |
|---|---|---|---|
| D1 | List pane width | The default is **368** (design rules). The Mac's default is 375 (`RootView.swift`, `ListDefaults.width`). The Mac is the bug: phase 3 changes its default to 368 too, so both apps photograph alike. The minimum (280), the maximum (min(640, window − 400)), double-click to reset, and `ui.list_width` stay as they are. | The rules set 232 / 368 / flexible. |
| D2 | All and Starred | Both use the Mac's single-column timeline (760 wide), not three panes. | The rule "the three panes, always" is about never leaving the reader to *manage* something (its stated reason). The timeline keeps the sidebar and is a reading place. The brief lists All and Starred as screens of their own. If the owner reads the rule more strictly, both apps change together. |
| D3 | Window chrome on Windows | Tauri's `decorations: false`. Fyke draws its own minimize, maximize and close buttons at the top right of the content pane (46 × 32 each, as Windows draws them), plus a drag region over the top 48 px where the Mac has its title-bar area. Snap layouts work because the window answers `WM_NCHITTEST` with `HTMAXBUTTON` over the maximize button, through a small subclass in Rust (`windows-sys`), not a plugin. Resizing from the borders is handled the same way. | The brief asks for system caption buttons and working snap layouts. A plain undecorated window loses both. Doing it in Rust adds no dependency. |
| D4 | Window chrome on Linux | Client-side decorations: the same three buttons as Windows, in the Adwaita order and look (close on the right), the same 48 px drag region through `startDragging`, and edge resizing through `startResizeDragging`. | The brief asks for client-side decorations that follow the same layout. |
| D5 | Sidebar top inset | It stays 48, as on the Mac, on both systems, so pictures compare and the Windows caption buttons have room. | Parity. |
| D6 | Menu bar | There is no native menu bar on Windows or Linux. Every Mac menu item is a palette command (Ctrl+K), and the frequent ones keep their shortcuts (K-lines). | The rules say every action has a menu item and that ⌘K opens a palette of all of them. A Windows or GTK menu bar inside a hidden-title-bar layout would be the only native-looking strip in the window. |
| D7 | Name of the `--notify` binary | On Windows the app binary is `Fyke.App.exe` (Tauri's `mainBinaryName`), so `src/notify.zig` needs no change there. On Linux the binary is `fyke-app` beside `fyke`, and `notify.zig` gains a `.linux` case that looks for it. | It keeps the daemon's contract. Only an app installed with the daemon is started. |
| D8 | Socket on Windows | AF_UNIX at `<data folder>\fyked.sock` through `windows-sys` (Windows 10 1803 and later), the same path the daemon serves. | The brief asks for this, and the daemon already listens there. |
| D9 | Data folder | `FYKE_HOME` first. Otherwise Windows uses `%LOCALAPPDATA%\Fyke`, following the `location` pointer file when present, and Linux uses `$HOME/.fyke`. This is the same order as `src/main.zig`'s `homeDirectory`. The app never migrates legacy folders; the daemon does that. | One source of truth. |
| D10 | Single instance | `tauri-plugin-single-instance`. A second launch focuses the first window and passes on `--notify` or a screen request. | It is the documented Tauri 2 way, and it is small. |
| D11 | Text rendering | Fonts are bundled as variable TTFs with their `opsz` and `wght` axes, loaded through `@font-face`, and used with `font-optical-sizing: auto`. The weight ladder (−2..2 steps) maps to the CSS weights 100…900, the same ladder as `Font.Weight.shifted`. | It matches `Theme.swift`. |
| D12 | Scrollbars | Drawn by Fyke as an overlay (4 px wide at rest, 8 px on hover, a 14 px track), following `ui.scrollbars` (`scrolling`, `always` or `never`). Native scrollbars are hidden in Fyke's panes. Web pages keep their own. | It matches `ThemedScrollbar`. |
| D13 | Confirmation dialogs | "Delete folder…" with its contents, and "Remove feed…", stay modal confirmations. | Both delete articles from disk, which cannot be undone. The rule "undo instead of confirm" allows asking first in exactly that case. |
| D14 | Modifier click in the reader | Ctrl+click on Windows and Linux opens a link in the browser, where the Mac uses ⌘-click. The setting's detail text changes with it (C6). | Platform convention. |
| D15 | Notifications | Windows uses toast notifications through the `tauri-plugin-notification` plugin. Linux uses the freedesktop notification service through the same plugin. Title and body are the Mac's ("Fyke", "A routine has something for you"). | Same words on every system. |
| D16 | Background updating | "Keep updating in the background" runs `fyke service status`, `fyke service install` and `fyke service uninstall`. That is a Startup entry on Windows and a systemd user unit on Linux, both already in the daemon. | The brief asks for this. The Mac uses a login agent instead. |

## F: Swift files and the TS or Rust module that takes each job

UI modules live in `desktop/src`, Rust in `desktop/src-tauri/src`. Logic ported from `ReaderLogic` keeps its type names, and its tests are ported case for case.

| Id | Swift file | Job | Desktop module | Status | Evidence |
|---|---|---|---|---|---|
| F1 | ReaderLogic/Logic.swift `SidebarIndent` | Row indent from depth | `src/logic/SidebarIndent.ts` | planned | |
| F2 | ReaderLogic/Logic.swift `UndoStack` | Bounded undo, limit 100 | `src/logic/UndoStack.ts` | planned | |
| F3 | ReaderLogic/Logic.swift `Fuzzy` | Palette matching and ranking | `src/logic/Fuzzy.ts` | planned | |
| F4 | ReaderLogic/Logic.swift `CatchUpSession` | Catch-up queue, history, undo | `src/logic/CatchUpSession.ts` | planned | |
| F5 | ReaderLogic/Logic.swift `Schedule` | Routine schedule words | `src/logic/Schedule.ts` | planned | |
| F6 | ReaderLogic/Logic.swift `DryRunWords`, `Plural`, `SourcesNote` | Sentences about counts | `src/logic/DryRunWords.ts`, `Plural.ts`, `SourcesNote.ts` | planned | |
| F7 | ReaderLogic/Rule.swift `Rule`, `Clause` | View rule editing | `src/logic/Rule.ts` | planned | |
| F8 | ReaderLogic/Rule.swift `RuleSentence`, `SentencePart`, `ViewName` | A rule as a sentence; view names | `src/logic/RuleSentence.ts`, `ViewName.ts` | planned | |
| F9 | Tests/ReaderLogicTests/LogicTests.swift | 7 suites, 29 tests | `desktop/tests/unit/*.test.ts` (`bun test`) | planned | |
| F10 | Tokens.swift (generated) | Token values | `gui/tokens.css`, imported as-is by `src/styles/tokens.css` | planned | |
| F11 | Theme.swift | Palettes (Newsprint and Terminal derived by mixing), hex, contrast, font resolving, weight ladder | `src/theme/palette.ts`, `src/theme/fonts.ts` | planned | |
| F12 | Prefs.swift | `ui` settings in config.json, themes, temporary fonts, a debounced save of 300 ms, reload on change | `src/model/prefs.ts`; Rust `config_watch.rs` (file watch that emits an event) | planned | |
| F13 | Daemon.swift | Socket client, starting the daemon, timeouts, the event thread | Rust `daemon.rs`, `socket.rs`, `events.rs`, `paths.rs`; UI `src/transport/{index,tauri,bridge}.ts` | planned | |
| F14 | Models.swift | Wire types and their tolerant decoding | `src/model/types.ts`, `src/model/decode.ts` | planned | |
| F15 | AppModel.swift | Places, selection, entries, marks, reload, events, data move | `src/model/app.ts` | planned | |
| F16 | Library.swift | Views, recipes, briefs, routines, jobs, writers | `src/model/library.ts` | planned | |
| F17 | Features.swift | View save and undo, briefs, catch-up start, test screens, notifier | `src/model/features.ts`, `src/testmode/screens.ts` | planned | |
| F18 | Undo.swift | Undo center and toast | `src/model/undo.ts`, `src/ui/Toast.tsx` | planned | |
| F19 | TestMode.swift | FYKE_SCREEN / KEYS / SNAPSHOT / HEADLESS | `src/testmode/index.ts`; Rust `testmode.rs` (env, snapshot, headless window) | planned | |
| F20 | ReaderApp.swift | Window, menu commands, undo routing | Rust `main.rs` (window 1440 × 900, minimum 960 × 600); `src/commands.ts` | planned | |
| F21 | RootView.swift | Layout, keys, problem banner, panes and divider, list, timeline, first run | `src/ui/Root.tsx`, `Panes.tsx`, `EntryList.tsx`, `Timeline.tsx`, `FirstRun.tsx`, `src/keys.ts` | planned | |
| F22 | Kit.swift | Metrics, motion, buttons, chips, tabs, inline state, spinner, key hints, fields | `src/ui/kit/*.tsx`, `src/styles/kit.css` | planned | |
| F23 | Controls.swift | Glyphs, icon buttons, float layer, menus, select, checkbox, themed scrollbar, right-click menus, window buttons | `src/ui/controls/*.tsx`; window buttons in `src/ui/Chrome.tsx` (D3, D4) | planned | |
| F24 | Sidebar.swift | Sidebar rows, tree, drag and drop, rename, menus, status line, confirmations, shortcuts sheet, move dialog | `src/ui/Sidebar.tsx`, `SidebarTree.tsx`, `ConfirmDialog.tsx`, `Shortcuts.tsx`, `MoveDialog.tsx` | planned | |
| F25 | ReaderPane.swift | Article column, actions, blocks, images, text-and-theme menu | `src/ui/Reader.tsx`, `Blocks.tsx` (DOM nodes with `textContent` only), `TypeMenu.tsx` | planned | |
| F26 | WebPane.swift | Web viewer and its address guard | Rust `web.rs` (a second webview with no IPC, an incognito profile, and the guard after DNS); `src/ui/WebPane.tsx` (the bar) | planned | |
| F27 | Discussion.swift | Hacker News thread under the article | `src/ui/Discussion.tsx` | planned | |
| F28 | Ask.swift | Ask your feeds | `src/model/ask.ts`, `src/ui/Ask.tsx` | planned | |
| F29 | Activity.swift | Status line, Activity popover, feed health | `src/model/activity.ts`, `src/ui/Activity.tsx`, `FeedHealth.tsx` | planned | |
| F30 | StoragePane.swift | Settings · Data | `src/ui/settings/Data.tsx` | planned | |
| F31 | CatchUp.swift | Catch-up card | `src/model/catchup.ts`, `src/ui/CatchUp.tsx` | planned | |
| F32 | Today.swift | Brief list, Today reader, back bar | `src/ui/Today.tsx` | planned | |
| F33 | Views.swift | View sentence, its editors, view menu | `src/ui/ViewSentence.tsx`, `ViewMenu.tsx` | planned | |
| F34 | Search.swift | Search popup | `src/model/search.ts`, `src/ui/Search.tsx` | planned | |
| F35 | CommandPalette.swift | ⌘K palette | `src/model/palette.ts`, `src/ui/Palette.tsx` | planned | |
| F36 | AddFeed.swift | Add feed sheet, OPML | `src/ui/AddFeed.tsx`, `src/model/opml.ts` (Rust dialog for files) | planned | |
| F37 | Brief.swift | Citations, source list, "made with", artifact column | `src/ui/Brief.tsx` | planned | |
| F38 | RecipeView.swift | Recipe edit, try, history, reset | `src/ui/Recipe.tsx` | planned | |
| F39 | Routines.swift | Routine list, editor, dry run | `src/ui/Routines.tsx` | planned | |
| F40 | SettingsView.swift | Settings shell; General, Reading, Agents | `src/ui/settings/{Settings,General,Reading,Agents}.tsx` | planned | |
| F41 | TokensPane.swift | Theme gallery, new theme, token editor, color and font pickers | `src/ui/settings/Tokens.tsx`, `ColorPanel.tsx`, `FontPicker.tsx` | planned | |
| F42 | (none) | Notification on `--notify`, single instance, service toggle | Rust `notify.rs`, `instance.rs`, `service.rs` | planned | |

## S: Screens and states

Each screen is checked in light and dark. A screen with an `e2e_gui.py` picture name keeps that name, so the Playwright picture and the Mac picture pair up in `zig-out/parity/`. A screen without a Mac picture yet gets a new name, and a matching `shot:` is added to `e2e_gui.py`.

| Id | Screen or state | Picture name | Status | Evidence |
|---|---|---|---|---|
| S1 | Today with a brief and citations | `today` | planned | |
| S2 | Today with source 1 pinned open | `citation` | planned | |
| S3 | Today: no brief yet / writing / not written / needs a newer service | `today-empty`, `today-writing`, `today-failed` (new) | planned | |
| S4 | All (timeline, first article selected) | `all` | planned | |
| S5 | Starred, with items and empty | `starred`, `starred-empty` (new) | planned | |
| S6 | A folder | `folder` (new) | planned | |
| S7 | A feed with an article open | `feed` (new) | planned | |
| S8 | A saved view: sentence rule, chips, editing in place | `view` | planned | |
| S9 | A view with nothing matching ("Nothing matches yet", "Include read articles") | `view-empty` (new) | planned | |
| S10 | Search with results, and with none | `search`, `search-none` (new) | planned | |
| S11 | Command palette | `palette` | planned | |
| S12 | Shortcuts sheet | `shortcuts` (new) | planned | |
| S13 | Catch-up: a card / finished / could not start | `catchup`, `catchup-done` (new) | planned | |
| S14 | Ask with a cited answer; answering; not answered | `ask` | planned | |
| S15 | Recipe open in place, edit, try (working, failed), reset with undo, history | `recipe` | planned | |
| S16 | Routines: list, editor, dry run, run now; "Routines start from a view" | `routines` | planned | |
| S17 | Activity popover and the status line (working, needs you, quiet) | `activity` | planned | |
| S18 | Feed health panel | `health` | planned | |
| S19 | Toast with Undo | `toast` | planned | |
| S20 | Discussion (comments) under an article | `comments` | planned | |
| S21 | Web viewer: page, failure, blocked private address | `web` (new) | planned | |
| S22 | Add feed: discovery, preview, choosing a folder, failure | `add` (new) | planned | |
| S23 | Folder rename, feed rename | `rename-folder`, `rename-feed` (new) | planned | |
| S24 | Move a feed (the Move to › submenu, drag and drop) | (scenario) | planned | |
| S25 | Delete folder and remove feed confirmations | `delete-folder` (new) | planned | |
| S26 | OPML import and export | (scenario) | planned | |
| S27 | Pane divider: drag, double-click reset, saved | (scenario `divider`) | planned | |
| S28 | Folder disclosure that survives relaunch | (scenario) | planned | |
| S29 | First run (no feeds) | `first-run` (new) | planned | |
| S30 | Daemon unavailable ("The background service did not start"), outdated daemon replaced, config.json mistake banner | `unavailable` (new) | planned | |
| S31 | Empty, failed and in-progress states for every list (feed, folder, view, All, Starred, Today, routines, search) | (per list, above) | planned | |
| S32 | Settings · General | `settings-general` | planned | |
| S33 | Settings · Reading (font family and weight for each kind of text) | `settings-reading`, `settings-reading-weights` | planned | |
| S34 | Settings · Tokens (gallery, new theme, token editor, color panel, font picker) | `settings-tokens` | planned | |
| S35 | Settings · Agents (writers, profiles, agent tier) | `settings-agents` | planned | |
| S36 | Settings · Data (storage, trimming, data move with its stages and failures) | `settings-data` | planned | |
| S37 | Built-in themes Newsprint and Terminal on the reading screens (S4, S7) | `all-newsprint`, `all-terminal` (new) | planned | |
| S38 | Every control in every state: rest, hover, pressed, focus ring, selected, disabled; cursors; motion of 120–200 ms that stops under `prefers-reduced-motion`; `forced-colors` | `controls` (a test page in the desktop app only) | planned | |
| S39 | Window chrome: caption buttons, drag region, snap layouts (D3, D4) | Windows checklist | planned | |

## K: Keyboard shortcuts

⌘ becomes Ctrl and ⌥ becomes Alt. "Clash" names what the system or the webview already does with the key, and what Fyke does about it.

| Id | Mac | Windows and Linux | Action | Clash and choice | Status | Evidence |
|---|---|---|---|---|---|---|
| K1 | ⌘, | Ctrl+, | Settings | | planned | |
| K2 | ⌘N | Ctrl+N | Add feed | WebView2 opens a new window. Fyke prevents the default. | planned | |
| K3 | ⌘S | Ctrl+S | Save search as view (and Save in the routine editor) | WebView2 offers to save the page. Fyke prevents the default. | planned | |
| K4 | ⌘Z | Ctrl+Z | Undo (text field first, then catch-up, then the undo stack) | | planned | |
| K5 | ⇧⌘Z | Ctrl+Shift+Z, and Ctrl+Y on Windows | Redo | Windows apps use Ctrl+Y, so it is added. | planned | |
| K6 | ⌘K | Ctrl+K | Everything (palette) | WebView2 and Chromium focus the address or search bar. There is none, and Fyke prevents the default. | planned | |
| K7 | ⌘F | Ctrl+F | Search | WebView2 and WebKitGTK open find-in-page. Fyke prevents the default. | planned | |
| K8 | ⌘1 ⌘2 ⌘3 ⌘4 | Ctrl+1 … Ctrl+4 | Today, All, Starred, Routines | | planned | |
| K9 | ⌘J | Ctrl+J | Catch up | WebView2 opens downloads. Fyke prevents the default. | planned | |
| K10 | ⌘0 | Ctrl+0 | Activity | WebView2 resets the zoom. Fyke prevents the default and turns off zoom hotkeys. | planned | |
| K11 | ⌘R | Ctrl+R | Write a brief | The webview reloads (and F5 does too). Fyke prevents both in release builds. | planned | |
| K12 | ⇧⌘A | Ctrl+Shift+A | Ask your feeds | Chromium's tab search; not bound in WebView2. Fyke prevents the default. | planned | |
| K13 | ⇧⌘K | Ctrl+Shift+K | Mark all read (only where `canMarkAllHere`) | | planned | |
| K14 | ⌘Q | Ctrl+Q on Linux; Alt+F4 on Windows (system) | Quit | Neither system has ⌘Q. Ctrl+Q is the GNOME convention. | planned | |
| K15 | ⌘-click | Ctrl+click | Open link in browser | D14 | planned | |
| K16 | Return, Esc | same | Open; close the float layer or go back | | planned | |
| K17 | ↑ ↓ j k | same | Move selection | | planned | |
| K18 | n s m u | same | Next unread, star, read or unread, unread only | | planned | |
| K19 | o, ⇧O | o, Shift+O | Open page here, open in browser | | planned | |
| K20 | c f r a t | same | Comments, fetch full, refresh, add feed, text and theme | | planned | |
| K21 | / ? | same | Search, shortcuts sheet | | planned | |
| K22 | ← ↓ → (catch-up) | same | Skip, later, read now | | planned | |
| K23 | — | Ctrl+P, Ctrl+U, Ctrl+Shift+I, F12, Ctrl+wheel and Ctrl+± zoom, the context menu | Webview defaults | Fyke prevents them in release builds (print, view source, devtools, zoom, and the browser's own menu). Fyke's right-click menus replace the context menu. | planned | |
| K24 | Key hints shown in the UI ("⌘K", "⌘J", "⌘Z" in the toast, the shortcuts sheet, palette shortcuts) | "Ctrl+K", "Ctrl+J", "Ctrl+Z", … | Text | It is drawn from one table (`src/keys.ts`), so the hints and the bindings never differ. | planned | |
| K25 | Keys while a dialog shows, while renaming, in the palette, in search and in catch-up | same rules | Blocking | Only Esc in Settings. | planned | |

## U: Undoable actions

| Id | Action | Undo message | Status | Evidence |
|---|---|---|---|---|
| U1 | Mark all read in a place | "Marked N article(s) in <name> as read" | planned | |
| U2 | Save a search as a view | "Saved “X” as a view" | planned | |
| U3 | Change a view's rule | "Changed “X”" | planned | |
| U4 | Remove a view (routines detach, then re-point on undo) | "Removed “X”" | planned | |
| U5 | Reset a recipe to the built-in text | "Reset “X” to the built-in text" | planned | |
| U6 | Remove a routine | "Removed “X”" | planned | |
| U7 | Catch-up decisions (skip, later, read now), with Ctrl+Z while catch-up is open | (no toast; the card comes back) | planned | |
| U8 | Redo of all of the above | | planned | |

Folder delete and feed removal are confirmations (D13), as on the Mac.

## C: Copy that depends on the platform

| Id | Mac | Windows | Linux | Status | Evidence |
|---|---|---|---|---|---|
| C1 | "Add a site you like. Everything stays on this Mac." | "… on this PC." | "… on this computer." | planned | |
| C2 | "Feeds, articles and settings stay in one folder on this Mac." | "… on this PC." | "… on this computer." | planned | |
| C3 | "Fyke hands the selected articles and your recipe to an agent already on this Mac. …" | "… on this PC. …" | "… on this computer. …" | planned | |
| C4 | "Not found on this Mac" (writer status) | "Not found on this PC" | "Not found on this computer" | planned | |
| C5 | "Starts when you log in, even with this window closed" | "Starts when you sign in, …" | "Starts when you log in, …" | planned | |
| C6 | "⌘-click always uses your browser" | "Ctrl+click always uses your browser" | same as Windows | planned | |
| C7 | Paths shown with `~` (data folder, settings file) | Full path with `%LOCALAPPDATA%` written out | `~` | planned | |
| C8 | The default browser's own name (`DefaultBrowser`) | Read from the registry's `http` association | Read from `xdg-settings get default-web-browser` | planned | |
| C9 | Writer and daemon copy ("on this Mac") that comes from the daemon | Already says "this PC" or "this computer" | same | planned | |

All of these come from one module, `src/platform.ts`, which reads the system from Tauri once at start.

## X: Systems, packaging and checks

| Id | Item | Status | Evidence |
|---|---|---|---|
| X1 | Rust: one `call(method, params)` command; a 1 MiB request limit; 35 s timeout (120 s for slow calls); a lost reply to a changing call is reported as "outcome unknown" and is never retried | planned | |
| X2 | Rust: the event channel on a second connection, resuming from `since_seq`, reconnecting after 1 s | planned | |
| X3 | Rust: start the bundled `fyke daemon --log` when the daemon is absent (`FYKE_BIN` overrides it), and retry 300 × 10 ms | planned | |
| X4 | Rust: outdated daemon (`api_version` ≠ 2) stopped and replaced | planned | |
| X5 | Web viewer: http and https only on every navigation; private and local addresses refused after DNS; incognito; no IPC; new windows open in the pane; downloads, camera and microphone refused | planned | |
| X6 | Strict CSP; feed content never becomes HTML | planned | |
| X7 | `cargo test`: socket, paths, URL guard, single instance, notify arguments | planned | |
| X8 | `bun test`: the ReaderLogic ports and the models | planned | |
| X9 | Shared fixtures moved out of `tools/e2e_gui.py`, which keeps passing | planned | |
| X10 | Playwright scenarios: keys, themes, divider, move, settings-route, mark-all, rename, font-weight, view-save, catchup-keys, palette-keys, brief, answer, routine-save, discussion, every `shot:` | planned | |
| X11 | Comparison tool writing to `zig-out/parity/`; 99.99 % of pixels and every box within 1 px | planned | |
| X12 | `tauri-driver` smoke test on Windows and Linux CI | planned | |
| X13 | New suites in `tools/check.py` with rules | planned | |
| X14 | Windows NSIS installer, per user, keeping the WinUI installer's behaviour; its end-to-end test | planned | |
| X15 | Linux AppImage and `.deb`, with `fyke` bundled | planned | |
| X16 | Icons from `tools/gen_icon.swift` through `tauri icon` | planned | |
| X17 | Size and speed measured in CI, with budgets | planned | |
| X18 | `release.yml` and `tools/release.py` publish the installers with checksums | planned | |
| X19 | `docs/desktop.md`, README, CHANGELOG | planned | |
| X20 | `docs/desktop-windows-checklist.md` handed to the owner | planned | |
