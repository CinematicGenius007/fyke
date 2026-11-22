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
| D1 | List pane width | The default is **368** (design rules). The Mac's default was 375. The Mac was the bug: phase 3 changed its default to 368 too (`Prefs.swift`, `RootView.swift`), so both apps photograph alike. The minimum (280), the maximum (min(640, window − 400)), double-click to reset, and `ui.list_width` stay as they are. | The rules set 232 / 368 / flexible. |
| D2 | All and Starred | Both use the Mac's single-column timeline (760 wide), not three panes. | The rule "the three panes, always" is about never leaving the reader to *manage* something (its stated reason). The timeline keeps the sidebar and is a reading place. The brief lists All and Starred as screens of their own. If the owner reads the rule more strictly, both apps change together. |
| D3 | Window chrome on Windows | Tauri's `decorations: false`. Fyke draws its own minimize, maximize and close buttons at the top right of the content pane (46 × 32 each, as Windows draws them), plus a drag region over the top 48 px where the Mac has its title-bar area. Snap layouts work because the window answers `WM_NCHITTEST` with `HTMAXBUTTON` over the maximize button, through a small subclass in Rust (`windows-sys`), not a plugin. Resizing from the borders is handled the same way. | The brief asks for system caption buttons and working snap layouts. A plain undecorated window loses both. Doing it in Rust adds no dependency. |
| D4 | Window chrome on Linux | Client-side decorations: the same three buttons as Windows, in the Adwaita order and look (close on the right), the same 48 px drag region through `startDragging`, and edge resizing through `startResizeDragging`. | The brief asks for client-side decorations that follow the same layout. |
| D5 | Sidebar top inset | It stays 48, as on the Mac, on both systems, so pictures compare and the Windows caption buttons have room. | Parity. |
| D6 | Menu bar | There is no native menu bar on Windows or Linux. Every Mac menu item is a palette command (Ctrl+K), and the frequent ones keep their shortcuts (K-lines). | The rules say every action has a menu item and that ⌘K opens a palette of all of them. A Windows or GTK menu bar inside a hidden-title-bar layout would be the only native-looking strip in the window. |
| D7 | Name of the `--notify` binary | On Windows the app binary is `Fyke.App.exe` (`mainBinaryName` in `src-tauri/tauri.windows.conf.json`), so `src/notify.zig` needs no change there. On Linux the binary is `fyke-app` beside `fyke`, and `notify.zig` gains a `.linux` case that looks for it. | It keeps the daemon's contract. Only an app installed with the daemon is started. |
| D8 | Socket on Windows | AF_UNIX at `<data folder>\fyked.sock` through the `uds_windows` crate (Windows 10 1803 and later), the same path the daemon serves. | The brief asks for this, and the daemon already listens there. |
| D9 | Data folder | `FYKE_HOME` first. Otherwise Windows uses `%LOCALAPPDATA%\Fyke`, following the `location` pointer file when present, and Linux uses `$HOME/.fyke`. This is the same order as `src/main.zig`'s `homeDirectory`. The app never migrates legacy folders; the daemon does that. | One source of truth. |
| D10 | Single instance | `tauri-plugin-single-instance`. A second launch focuses the first window and passes on `--notify` or a screen request. | It is the documented Tauri 2 way, and it is small. |
| D11 | Text rendering | Fonts are bundled as variable TTFs with their `opsz` and `wght` axes, loaded through `@font-face`, and used with `font-optical-sizing: auto`. The weight ladder (−2..2 steps) maps to the CSS weights 100…900, the same ladder as `Font.Weight.shifted`. | It matches `Theme.swift`. |
| D12 | Scrollbars | Drawn by Fyke as an overlay (4 px wide at rest, 8 px on hover, a 14 px track), following `ui.scrollbars` (`scrolling`, `always` or `never`). Native scrollbars are hidden in Fyke's panes. Web pages keep their own. | It matches `ThemedScrollbar`. |
| D13 | Confirmation dialogs | "Delete folder…" with its contents, and "Remove feed…", stay modal confirmations. | Both delete articles from disk, which cannot be undone. The rule "undo instead of confirm" allows asking first in exactly that case. |
| D14 | Modifier click in the reader | Ctrl+click on Windows and Linux opens a link in the browser, where the Mac uses ⌘-click. The setting's detail text changes with it (C6). | Platform convention. |
| D15 | Notifications | Windows uses toast notifications through the `tauri-plugin-notification` plugin. Linux uses the freedesktop notification service through the same plugin. Title and body are the Mac's ("Fyke", "A routine has something for you"). | Same words on every system. |
| D16 | Background updating | "Keep updating in the background" runs `fyke service status`, `fyke service install` and `fyke service uninstall`. That is a Startup entry on Windows and a systemd user unit on Linux, both already in the daemon. | The brief asks for this. The Mac uses a login agent instead. |
| D17 | Color profile of the Mac's pictures | The Mac saves each picture in the color space of the display it ran on, as an embedded ICC profile, so its raw values differ from the tokens (`#111111` is stored as `#121212` on an LG UltraFine). `desktop/tools/parity.ts` converts each Mac picture to sRGB with `sips` before comparing; after that the tokens match exactly. The desktop pictures are sRGB already. | Comparing raw values would measure the monitor, not the app. |
| D18 | Theme in test mode | The desktop app takes `FYKE_THEME` (`light` or `dark`) where the Mac takes the launch arguments `-theme light -followSystem NO`. In the test browser, screen and theme variables can be passed in the page address. Permission to preview the loopback fixture requires headless fixture mode set in the process environment. | A Tauri app has no `UserDefaults` argument domain. One variable per setting keeps test mode in one place. |
| D19 | Where the Playwright suite runs | On macOS (WebKit, compared with the Mac's pictures) and on Linux CI (WebKit and Chromium). Windows CI runs the unit tests, the Rust tests and a build. | The bridge reaches the daemon's AF_UNIX socket through Node's `net` module, which on Windows connects to named pipes only. The app itself uses Rust on Windows, so this limits the test bridge, not the app. |
| D20 | Icons | The Mac's own glyphs (`Controls.swift` `Glyph`) are ported point for point. The SF Symbols it uses (magnifyingglass, calendar, tray, rectangle.stack, line.3.horizontal.decrease, clock.arrow.circlepath, gearshape, ellipsis) are drawn equivalents in `src/ui/kit/Icon.tsx`, so their pixels differ a little from the Mac's. | Apple licenses SF Symbols for its own platforms only; the app may not ship them. |
| D21 | Text pixels | Text is set in the same fonts, sizes, weights and boxes, and macOS stem darkening stays on (`-webkit-font-smoothing: auto`, as AppKit draws). Glyphs still differ at their edges, and some lines sit one device pixel (0.5 pt) apart: CoreText in AppKit and WebKit snap a baseline to the pixel grid differently inside the same box, and the offset changes with font size (13 px text sits 0.5 pt higher, 11 px matches, 20 px sits 0.5 pt lower). So the 99.99 % pixel target cannot be reached on a screen with text; the reading screens reach 99.69–99.83 % after the anti-aliasing allowance. Pane dividers, rules and rows land on the same device pixel as the Mac's; chips end within a device pixel, from the width of the text inside them. Enlarged, Mac above and desktop below: [sidebar](desktop-parity/text-mac-over-desktop.png), [its difference](desktop-parity/text-diff.png), [reader](desktop-parity/reader-mac-over-desktop.png). | Rounding each line box to the pixel grid, as SwiftUI does, was tried and changed nothing: the boxes were on the grid already. Moving text by hand per size would fit one Mac and one font, and break on Windows and Linux, which rasterize differently again. |
| D22 | Selected text in test pictures | The Mac takes its pictures in a window that is never key, so selected words in the search and rename fields show AppKit's inactive gray, and the focused Cancel button of a confirmation draws no focus ring. The desktop's page has focus in Playwright and shows the active selection color and the keyboard ring (design rules: every control has a visible focus ring). Both apps draw the system's colors; only the test windows differ. The Mac's picture also has the Today dot, from a brief its suite writes first; briefs come in phase 5. | Making the desktop draw an inactive selection while it has focus would be wrong in use. |
| D23 | Shadows and scrims in test pictures | The Mac's shortcuts popup draws its shadow's y of 18 upward, so the shadow falls above and beside the sheet and barely below it; the desktop draws it the same way (`0 -18px`) at 14 %, which gives the Mac's measured depth of 20 levels at the edge. The Mac's pictures also show every scrim about 12 % lighter than its token (20 % black over white is 210 on the Mac, 204 here) after the conversion from its display profile to sRGB; the desktop keeps the token. | The scrim token is the design's; lightening it to fit one display profile's conversion would make it wrong on Windows and Linux. |
| D24 | Add a feed sheet | The desktop uses a 32 px primary button and the system folder picker. The Mac sheet uses its compact primary button and a custom folder menu. The Mac Folder field is 428 pt, which fits the same 504 pt content width as the Name field. | The button follows the design rules. The system picker supplies keyboard navigation and platform accessibility. |

## F: Swift files and the TS or Rust module that takes each job

UI modules live in `desktop/src`, Rust in `desktop/src-tauri/src`. Logic ported from `ReaderLogic` keeps its type names, and its tests are ported case for case.

| Id | Swift file | Job | Desktop module | Status | Evidence |
|---|---|---|---|---|---|
| F1 | ReaderLogic/Logic.swift `SidebarIndent` | Row indent from depth | `src/logic/SidebarIndent.ts` | done | `tests/unit/logic.test.ts` |
| F2 | ReaderLogic/Logic.swift `UndoStack` | Bounded undo, limit 100 | `src/logic/UndoStack.ts` | done | `tests/unit/logic.test.ts` |
| F3 | ReaderLogic/Logic.swift `Fuzzy` | Palette matching and ranking | `src/logic/Fuzzy.ts` | done | `tests/unit/logic.test.ts` |
| F4 | ReaderLogic/Logic.swift `CatchUpSession` | Catch-up queue, history, undo | `src/logic/CatchUpSession.ts` | done | `tests/unit/logic.test.ts` |
| F5 | ReaderLogic/Logic.swift `Schedule` | Routine schedule words | `src/logic/Schedule.ts` | done | `tests/unit/logic.test.ts` |
| F6 | ReaderLogic/Logic.swift `DryRunWords`, `Plural`, `SourcesNote` | Sentences about counts | `src/logic/DryRunWords.ts`, `Plural.ts`, `SourcesNote.ts` | done | `tests/unit/logic.test.ts` |
| F7 | ReaderLogic/Rule.swift `Rule`, `Clause` | View rule editing | `src/logic/Rule.ts` | done | `tests/unit/logic.test.ts` |
| F8 | ReaderLogic/Rule.swift `RuleSentence`, `SentencePart`, `ViewName` | A rule as a sentence; view names | `src/logic/RuleSentence.ts`, `ViewName.ts` | done | `tests/unit/logic.test.ts` |
| F9 | Tests/ReaderLogicTests/LogicTests.swift | 7 suites, 22 tests | `desktop/tests/unit/logic.test.ts` (`bun test`) | done | every Swift case ported, case for case, plus one more |
| F10 | Tokens.swift (generated) | Token values | `src/theme/palette.ts` (`tokens`), checked value for value against `gui/tokens.css` | done | `theme.test.ts` › the light and dark tokens are gui/tokens.css |
| F11 | Theme.swift | Palettes (Newsprint and Terminal derived by mixing), hex, contrast, font resolving, weight ladder | `src/theme/color.ts`, `src/theme/palette.ts`, `src/theme/fonts.ts` | built | palettes and mixing: `theme.test.ts` (OKLab mix equals SwiftUI's printed values). Font resolving and the weight ladder are planned. |
| F12 | Prefs.swift | `ui` settings in config.json, themes, temporary fonts, a debounced save of 300 ms, reload on change | `src/model/prefs.ts`; Rust `config_watch.rs` (file watch that emits an event) | planned | |
| F13 | Daemon.swift | Socket client, starting the daemon, timeouts, the event thread | Rust `rpc.rs`, `socket.rs`, `events.rs`, `paths.rs`; UI `src/transport/{index,tauri,bridge}.ts` | done | `cargo test` (rpc, events, paths); Playwright `harness.spec.ts` |
| F14 | Models.swift | Wire types and their tolerant decoding | `src/model/types.ts`, `src/model/decode.ts` | built | `tsc`; decoded by every Playwright scenario in `reading.spec.ts` |
| F15 | AppModel.swift | Places, selection, entries, marks, reload, events, data move | `src/model/app.ts` | built | Playwright `reading.spec.ts`: places, open and mark read, Esc and Return, j and k, star and unread, divider. Search, data move and the palette are planned (phase 4) |
| F16 | Library.swift | Views, recipes, briefs, routines, jobs, writers | `src/model/library.ts` | built | Views load and their counts follow marks (`reading.spec.ts`). Recipes, briefs, routines, jobs and writers are planned (phases 4–5) |
| F17 | Features.swift | View save and undo, briefs, catch-up start, test screens, notifier | `src/model/features.ts`, `src/testmode/screens.ts` | planned | |
| F18 | Undo.swift | Undo center and toast | `src/model/undo.ts`, `src/ui/Toast.tsx` | built | `src/model/undo.ts` and the toast; Ctrl+Z after "mark all read". Its scenario is planned (phase 4) |
| F19 | TestMode.swift | FYKE_SCREEN / KEYS / SNAPSHOT / HEADLESS | `src/testmode/index.ts`; Rust `testmode.rs` (env, snapshot, headless window) | built | `testmode.rs` passes every `FYKE_` variable to the UI and keeps a headless window hidden. Screens, keys and snapshots are planned. |
| F20 | ReaderApp.swift | Window, menu commands, undo routing | Rust `main.rs` (window 1440 × 900, minimum 960 × 600); `src/commands.ts` | planned | |
| F21 | RootView.swift | Layout, keys, problem banner, panes and divider, list, timeline, first run | `src/ui/Root.tsx`, `Panes.tsx`, `EntryList.tsx`, `Timeline.tsx`, `FirstRun.tsx`, `src/keys.ts` | built | Panes, divider (`reading.spec.ts`), list with paging, timeline, keys (`src/ui/keys.ts`). First run is planned |
| F22 | Kit.swift | Metrics, motion, buttons, chips, tabs, inline state, spinner, key hints, fields | `src/ui/kit/*.tsx`, `src/styles/kit.css` | built | Count, section label, rule, spinner, symbol and icon buttons, chips, dot (`src/ui/kit/Controls.tsx`). Tabs, fields and key hints are planned |
| F23 | Controls.swift | Glyphs, icon buttons, float layer, menus, select, checkbox, themed scrollbar, right-click menus, window buttons | `src/ui/controls/*.tsx`; window buttons in `src/ui/Chrome.tsx` (D3, D4) | built | Glyphs and drawn SF equivalents (`src/ui/kit/Icon.tsx`, D20). Float layer, menus with submenus and checks, the checkbox and right-click menus (`src/ui/Float.tsx`; the webview's own menu shows only over text fields and selected text). Select and window buttons are planned |
| F24 | Sidebar.swift | Sidebar rows, tree, drag and drop, rename, menus, status line, confirmations, shortcuts sheet, move dialog | `src/ui/Sidebar.tsx`, `SidebarTree.tsx`, `ConfirmDialog.tsx`, `ShortcutsSheet.tsx`, `MoveDialog.tsx` | built | Rows, tree, status line, Routines row (`src/ui/Sidebar.tsx`), shortcuts sheet (`src/ui/ShortcutsSheet.tsx`), rename in place, the view, folder and feed menus with Move to, and the delete-folder and remove-feed confirmations (`src/ui/ConfirmDialog.tsx`), checked in `manage.spec.ts`. The menus' brief, catch-up and routine items join with those features in phase 5; restoring a removed view also points its routines back at it then. Feed and folder drag-and-drop is checked in `manage.spec.ts`. The data move dialog is planned |
| F25 | ReaderPane.swift | Article column, actions, blocks, images, text-and-theme menu | `src/ui/Reader.tsx`, `Blocks.tsx` (DOM nodes with `textContent` only), `TypeMenu.tsx` | built | Article column, actions, blocks as text nodes ("feed content is text, never markup" in `reading.spec.ts`), images on request. The text-and-theme menu is planned |
| F26 | WebPane.swift | Web viewer and its address guard | Rust `web.rs` (a second webview with no IPC, an incognito profile, and the guard after DNS); `src/ui/WebPane.tsx` (the bar) | planned | |
| F27 | Discussion.swift | Hacker News thread under the article | `src/ui/Discussion.tsx` | planned | |
| F28 | Ask.swift | Ask your feeds | `src/model/ask.ts`, `src/ui/Ask.tsx` | planned | |
| F29 | Activity.swift | Status line, Activity popover, feed health | `src/model/activity.ts`, `src/ui/Activity.tsx`, `FeedHealth.tsx` | planned | |
| F30 | StoragePane.swift | Settings · Data | `src/ui/settings/Data.tsx` | planned | |
| F31 | CatchUp.swift | Catch-up card | `src/model/catchup.ts`, `src/ui/CatchUp.tsx` | planned | |
| F32 | Today.swift | Brief list, Today reader, back bar | `src/ui/Today.tsx` | planned | |
| F33 | Views.swift | View sentence, its editors, view menu | `src/ui/ViewSentence.tsx`, `ViewMenu.tsx` | planned | |
| F34 | Search.swift | Search popup | `src/model/search.ts`, `src/ui/Search.tsx` | planned | |
| F35 | CommandPalette.swift | ⌘K palette | `src/model/commands.ts`, `src/ui/CommandPalette.tsx` | built | `palette.spec.ts`. New folder is built. The brief, catch-up, ask, new routine, activity, add feed, Settings · Agents, run-routine and edit-recipe commands, and the Ask row with Tab, are planned: each joins with its feature |
| F36 | AddFeed.swift | Add feed sheet, OPML | `src/ui/AddFeed.tsx`, `src/model/subscriptions.ts`, `src-tauri/src/opml.rs` | built | `add-feed.spec.ts` covers discovery, subscription and OPML over the bridge. The native file dialogs are in the [Windows checklist](desktop-windows-checklist.md). |
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
| S4 | All (timeline, first article selected) | `all` | built | `all-light` 99.811 %, `all-dark` 99.833 % equal after the allowance; layout on the same pixels; the rest is text (D21) and icons (D20) |
| S5 | Starred, with items and empty | `starred`, `starred-empty` (new) | planned | |
| S6 | A folder | `folder` (new) | planned | |
| S7 | A feed with an article open | `feed` (new) | planned | |
| S8 | A saved view: sentence rule, chips, editing in place | `view` | built | `view-light` 99.688 %, `view-dark` 99.740 % equal after the allowance; the sentence rule shows; editing in place is planned |
| S9 | A view with nothing matching ("Nothing matches yet", "Include read articles") | `view-empty` (new) | planned | |
| S10 | Search with results, and with none | `search`, `search-none` (new) | built | `search-light` 99.468 %, `search-dark` 99.361 % equal after the allowance (D21, D22, K24); nothing found: `search.spec.ts` "nothing found opens nothing"; the `search-none` picture is planned |
| S11 | Command palette | `palette` | built | `palette-light` 93.558 %, `palette-dark` 93.939 %: the field, Go to and Articles sections line up; the Mac's "Run Morning needle now" row and its Ask row are missing until routines and Ask exist (F35) |
| S12 | Shortcuts sheet | `shortcuts` (new) | built | `shortcuts-light` 99.408 %, `shortcuts-dark` 99.345 % equal after the allowance: the rest is the keys spelled Ctrl and Shift for ⌘ and ⇧ (K24), text edges (D21) and the scrim (D23) |
| S13 | Catch-up: a card / finished / could not start | `catchup`, `catchup-done` (new) | planned | |
| S14 | Ask with a cited answer; answering; not answered | `ask` | planned | |
| S15 | Recipe open in place, edit, try (working, failed), reset with undo, history | `recipe` | planned | |
| S16 | Routines: list, editor, dry run, run now; "Routines start from a view" | `routines` | planned | |
| S17 | Activity popover and the status line (working, needs you, quiet) | `activity` | planned | |
| S18 | Feed health panel | `health` | planned | |
| S19 | Toast with Undo | `toast` | planned | |
| S20 | Discussion (comments) under an article | `comments` | planned | |
| S21 | Web viewer: page, failure, blocked private address | `web` (new) | planned | |
| S22 | Add feed: discovery, preview, choosing a folder, failure | `add`, `add-found`, `add-multiple`, `add-none` | built | `add-feed.spec.ts` exercises the dialog and writes eight picture pairs. Light and dark are 93.127–94.766% equal after the allowance. The differences include text edges and selection (D21–D22), sheet corners and button height (D24), and the fixture server ports. |
| S23 | Folder rename, feed rename | `rename-folder`, `rename-feed` (new) | built | `rename-folder-light` 99.669 %, `rename-folder-dark` 99.705 %, `rename-feed-light` 99.684 %, `rename-feed-dark` 99.715 % equal after the allowance: the rest is the selection color (D22), Ctrl for ⌘ (K24) and text edges (D21) |
| S24 | Move a feed or folder | (scenario) | done | `manage.spec.ts` covers Move to, Move to › New folder, and dragging a feed or folder into a folder and back to the Feeds heading. |
| S25 | Delete folder and remove feed confirmations | `delete-folder` (new) | built | `delete-folder-light` 99.615 %, `delete-folder-dark` 99.438 % equal after the allowance: the rest is Cancel's focus ring (D22), the scrim (D23), Ctrl for ⌘ (K24) and text edges (D21); Esc, Cancel, the checkbox and Remove feed: `manage.spec.ts` |
| S26 | OPML import and export | (scenario) | built | `add-feed.spec.ts` checks that the folder and feed round-trip through the real daemon. Native file dialogs, overwrite and cancellation are in the [Windows checklist](desktop-windows-checklist.md). |
| S27 | Pane divider: drag, double-click reset, saved | (scenario `divider`) | done | `reading.spec.ts` "a feed shows its list beside the reader, and the divider resizes it" |
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
| K2 | ⌘N | Ctrl+N | Add feed | WebView2 opens a new window. Fyke prevents the default. | done | `add-feed.spec.ts` opens, previews and subscribes via Ctrl+N. |
| K3 | ⌘S | Ctrl+S | Save search as view (and Save in the routine editor) | WebView2 offers to save the page. Fyke prevents the default. | built | search: `search.spec.ts` "Ctrl+S keeps a search as a view, named for its words"; the routine editor is planned |
| K4 | ⌘Z | Ctrl+Z | Undo (text field first, then catch-up, then the undo stack) | | planned | |
| K5 | ⇧⌘Z | Ctrl+Shift+Z, and Ctrl+Y on Windows | Redo | Windows apps use Ctrl+Y, so it is added. | planned | |
| K6 | ⌘K | Ctrl+K | Everything (palette) | WebView2 and Chromium focus the address or search bar. There is none, and Fyke prevents the default. | done | `palette.spec.ts` "the palette finds a command by its letters"; the sidebar's Search row: "the sidebar's Search row opens the palette, and Esc closes it" |
| K7 | ⌘F | Ctrl+F | Search | WebView2 and WebKitGTK open find-in-page. Fyke prevents the default. | done | `search.spec.ts` "Ctrl+F, type and Return opens the first result" and the arrow, Esc and nothing-found scenarios |
| K8 | ⌘1 ⌘2 ⌘3 ⌘4 | Ctrl+1 … Ctrl+4 | Today, All, Starred, Routines | | planned | |
| K9 | ⌘J | Ctrl+J | Catch up | WebView2 opens downloads. Fyke prevents the default. | planned | |
| K10 | ⌘0 | Ctrl+0 | Activity | WebView2 resets the zoom. Fyke prevents the default and turns off zoom hotkeys. | planned | |
| K11 | ⌘R | Ctrl+R | Write a brief | The webview reloads (and F5 does too). Fyke prevents both in release builds. | planned | |
| K12 | ⇧⌘A | Ctrl+Shift+A | Ask your feeds | Chromium's tab search; not bound in WebView2. Fyke prevents the default. | planned | |
| K13 | ⇧⌘K | Ctrl+Shift+K | Mark all read (only where `canMarkAllHere`) | | built | bound; through the palette: `palette.spec.ts` "Mark all read in All marks every article" and "… is not offered in Starred" |
| K14 | ⌘Q | Ctrl+Q on Linux; Alt+F4 on Windows (system) | Quit | Neither system has ⌘Q. Ctrl+Q is the GNOME convention. | planned | |
| K15 | ⌘-click | Ctrl+click | Open link in browser | D14 | planned | |
| K16 | Return, Esc | same | Open; close the float layer or go back | | done | `reading.spec.ts` "Escape goes back to the timeline, and Return opens the selected row again" |
| K17 | ↑ ↓ j k | same | Move selection | | done | `reading.spec.ts` "j and k move through a view's list and open each article" |
| K18 | n s m u | same | Next unread, star, read or unread, unread only | | built | s and m: `reading.spec.ts` "s stars the open article …"; n and u are bound, their scenario is planned |
| K19 | o, ⇧O | o, Shift+O | Open page here, open in browser | | planned | |
| K20 | c f r a t | same | Comments, fetch full, refresh, add feed, text and theme | | planned | |
| K21 | / ? | same | Search, shortcuts sheet | | built | /: `search.spec.ts` "/ opens search too"; ?: `search.spec.ts` "? shows shortcuts and swallows keys until closed", "Esc closes shortcuts" |
| K22 | ← ↓ → (catch-up) | same | Skip, later, read now | | planned | |
| K23 | — | Ctrl+P, Ctrl+U, Ctrl+Shift+I, F12, Ctrl+wheel and Ctrl+± zoom, the context menu | Webview defaults | Fyke prevents them in release builds (print, view source, devtools, zoom, and the browser's own menu). Fyke's right-click menus replace the context menu. | planned | |
| K24 | Key hints shown in the UI ("⌘K", "⌘J", "⌘Z" in the toast, the shortcuts sheet, palette shortcuts) | "Ctrl+K", "Ctrl+J", "Ctrl+Z", … | Text | It is drawn from one table (`src/keys.ts`), so the hints and the bindings never differ. | planned | |
| K25 | Keys while a dialog shows, while renaming, in the palette, in search and in catch-up | same rules | Blocking | Only Esc in Settings. | in progress | Dialogs, menus and renaming: `manage.spec.ts`; the palette: `palette.spec.ts`; search: `search.spec.ts`. Catch-up and Settings are planned |

## U: Undoable actions

| Id | Action | Undo message | Status | Evidence |
|---|---|---|---|---|
| U1 | Mark all read in a place | "Marked N article(s) in <name> as read" | done | `palette.spec.ts` "Ctrl+Z takes back mark all read" |
| U2 | Save a search as a view | "Saved “X” as a view" | done | `search.spec.ts` "Ctrl+Z takes the new view back" |
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
| C1 | "Add a site you like. Everything stays on this Mac." | "… on this PC." | "… on this computer." | built | FirstRun in `src/ui/AddFeed.tsx`. |
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
| X1 | Rust: one `call(method, params)` command; a 1 MiB request limit; 35 s timeout (120 s for slow calls); a lost reply to a changing call is reported as "outcome unknown" and is never retried | done | `cargo test`: `rpc::tests::a_lost_reply_to_a_change_is_outcome_unknown_and_not_sent_again`, `a_lost_reply_to_a_read_is_sent_once_more`, `a_closed_connection_is_reopened_before_a_change_is_sent`, `a_request_over_one_mebibyte_is_refused_before_sending`, `a_slow_call_has_its_own_connection` |
| X2 | Rust: the event channel on a second connection, resuming from `since_seq`, reconnecting after 1 s | done | `cargo test`: `events::tests::events_flow_and_resume_from_the_last_seq_after_a_drop` |
| X3 | Rust: start the bundled `fyke daemon --log` when the daemon is absent (`FYKE_BIN` overrides it), and retry 300 × 10 ms | built | the refusals are tested (`no_daemon_and_no_program_says_where_it_looked`, `a_paused_client_does_not_start_the_daemon`); starting a real daemon is covered once the app's own e2e runs |
| X4 | Rust: outdated daemon (`api_version` ≠ 2) stopped and replaced | planned | |
| X5 | Web viewer: http and https only on every navigation; private and local addresses refused after DNS; incognito; no IPC; new windows open in the pane; downloads, camera and microphone refused | planned | |
| X6 | Strict CSP; feed content never becomes HTML | built | the CSP is in `tauri.conf.json`; no feed content is drawn yet |
| X7 | `cargo test`: socket, paths, URL guard, single instance, notify arguments | built | socket and paths tested; URL guard, single instance and notify are planned |
| X8 | `bun test`: the ReaderLogic ports and the models | built | ReaderLogic ports and palettes: `bun test` (29 tests); models are planned |
| X9 | Shared fixtures moved out of `tools/e2e_gui.py`, which keeps passing | done | `tools/gui_fixtures.py`; `e2e_gui.py --only discussion,shot:all,themes` passes, and Playwright uses the same module |
| X10 | Playwright scenarios: keys, themes, divider, move, settings-route, mark-all, rename, font-weight, view-save, catchup-keys, palette-keys, brief, answer, routine-save, discussion, every `shot:` | planned | |
| X11 | Comparison tool writing to `zig-out/parity/`; 99.99 % of pixels and every box within 1 px | built | `desktop/tools/parity.ts` writes `zig-out/parity/report.md`, a side-by-side comparison and a diff picture per screen. A pixel counts as equal within 8 per channel, or, as anti-aliasing, when each picture has its color within one pixel of the other's; the report also gives the exact share. The 1 px box check is planned and needs the Mac to export its layout |
| X12 | `tauri-driver` smoke test on Windows and Linux CI | planned | |
| X13 | New suites in `tools/check.py` with rules | done | `desktop-unit`, `desktop-rust`, `desktop-e2e` and the parity report in `tools/check.py`, with rules for `desktop/**` and `tools/gui_fixtures.py` |
| X14 | Windows NSIS installer, per user, keeping the WinUI installer's behaviour; its end-to-end test | planned | |
| X15 | Linux AppImage and `.deb`, with `fyke` bundled | planned | |
| X16 | Icons from `tools/gen_icon.swift` through `tauri icon` | done | `desktop/tools/icons.sh` (`bun run icons`); the sizes are committed in `src-tauri/icons` |
| X17 | Size and speed measured in CI, with budgets | planned | |
| X18 | `release.yml` and `tools/release.py` publish the installers with checksums | planned | |
| X19 | `docs/desktop.md`, README, CHANGELOG | planned | |
| X20 | `docs/desktop-windows-checklist.md` handed to the owner | in progress | The [Windows checklist](desktop-windows-checklist.md) covers Add Feed and the native file dialogs. Platform and installer scenarios are planned. |
