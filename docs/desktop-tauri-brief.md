# Brief: the Fyke desktop app for Windows and Linux, in Tauri 2

This is the complete brief for one long piece of work. Read all of it before writing code, then carry it out end to end. It is written for an agent working in this repository with no memory of earlier sessions.

## The goal

Build the Fyke desktop app for **Windows and Linux** with **Tauri 2** (a Rust shell over the system web view) and a **TypeScript** UI. It must match the **macOS SwiftUI app in `gui/`** in look and behaviour: the same screens, layout, measurements, colors, type, motion, keyboard shortcuts, states, undo, and wording. The bar is that a person who uses the Mac app cannot find a difference other than the platform's own window chrome and the Ctrl key in place of ⌘.

Build the whole app, not a prototype. It is done when every item in "Done means" at the end is true.

Why this exists: a WinUI 3 version was built and removed ([ADR 0004](decisions/0004-desktop-tauri.md)). It could only be compiled on Windows, was 76 MB, and Linux had no GUI. This app replaces it on both systems. Its code is in git history at `bd837fa` (`gui-windows/`); read it for Windows-specific lessons (daemon start, data path, installer behaviour, `--notify`), never as the design reference. The Mac app is the design reference.

## Read first, in this order

1. `AGENTS.md`, `CONTRIBUTING.md`.
2. `docs/design-rules.md`. It is the source of truth for every interface. Where the Mac app and this document disagree, the document wins: follow it, and list the disagreement in the parity document (below) so the Mac app can be fixed too.
3. `docs/decisions/0002-web-viewer.md` and `docs/decisions/0004-desktop-tauri.md`.
4. `docs/architecture.md` (above all the content model: feed HTML becomes blocks at ingest), `docs/api.md` (every socket operation and event), `docs/reader-features.md` (views, briefs, recipes, routines, catch-up, writers, undo).
5. `gui/tokens.css`: every color, font and radius, exported from Paper. Use it directly as CSS; never hand-copy values.
6. **Every file in `gui/Sources/`** and `gui/Tests/`. About 12,000 lines of Swift. This is the specification for behaviour and layout: sizes, paddings, animations, copy, keyboard handling, edge cases. Read each file fully before building the matching part.
7. `tools/e2e_gui.py` and `gui/Sources/Reader/TestMode.swift`: how the Mac app is driven and photographed in tests. Your harness mirrors it.
8. If the Paper MCP tools are available, the v2 design file linked from `docs/design-rules.md`, board 00 and the screen boards. Read values with `get_computed_styles` / `get_jsx`, never from screenshots.

## Fixed decisions (do not reopen them)

| Area | Decision |
|---|---|
| Shell | Tauri 2, Rust stable. Pin every crate and npm version; check each package's README or `npm view` / `cargo info` for the current API before first use. |
| UI | TypeScript, **SolidJS**, Vite. No CSS framework and no component library: plain CSS with the tokens, because the look must be exact and the app small. |
| Tooling | **Bun** installs, runs scripts and runs unit tests (`bun test`). Bun is not shipped. Playwright for UI tests. |
| Location | `desktop/`: `desktop/src` (UI), `desktop/src-tauri` (Rust), `desktop/tests`. |
| Mac | The SwiftUI app stays the shipped Mac app. The Tauri app may build on macOS for development and tests only. |
| Daemon | Unchanged except where this brief says. The app is a client of its socket, like the CLI, TUI and MCP server. |
| Systems | Windows 10 1803+ x64 (WebView2, Evergreen) and Linux x64 (WebKitGTK 4.1, tested under GNOME and one other desktop). |

## Architecture

**Rust side (small, and the only part that touches the system).**
- Find the data folder exactly as `src/main.zig` does: `%LOCALAPPDATA%\Fyke` on Windows, following its `location` pointer file; `~/.fyke` elsewhere (a symlink after a data move); `FYKE_HOME` overrides. The daemon listens on the Unix socket `fyked.sock` there **on every system, Windows included** (Windows uses AF_UNIX, not a named pipe). Rust's std has no AF_UNIX on Windows: use a maintained crate or `windows-sys`, and test it on Windows CI.
- Start the daemon if it is not running: the `fyke` binary shipped beside the app (`fyke.exe` on Windows). Reconnect after the daemon dies, as `gui/Sources/Reader/Daemon.swift` does.
- Expose to the UI: one `call(method, params)` command, and one event channel that holds a second connection on `events.subscribe` and resumes from the last `since_seq` after a reconnect. Keep the daemon's request size limit and a timeout. A request whose reply was lost is reported as "outcome unknown" and **never retried automatically** if it changes data.
- Settings that are about the machine rather than the data (window size, pane widths if the Mac keeps them locally) go where the Mac keeps them; everything the Mac stores in the daemon's `config` (`ui` object) stays there, so both apps share it.
- The **web viewer** (ADR 0002) is a separate Tauri webview: `http`/`https` only, checked on every navigation and redirect; private and local addresses refused after DNS resolution (do it in Rust); an incognito, in-memory profile; **no IPC capability at all** for that webview (Tauri capabilities are per window/webview, so grant none); new windows open in the pane; downloads, camera and microphone refused. Back returns to the article.
- Notifications: the daemon starts `Fyke.App.exe --notify` beside `fyke.exe` on Windows (`src/notify.zig`). Either name the Windows binary `Fyke.App.exe` or change `notify.zig` and its tests, and add Linux (`fyke-desktop --notify` or similar) the same way. `--notify` posts one notification and exits; clicking it opens the run.
- Single instance: a second launch focuses the first window and passes on any activation.
- "Keep updating in the background" runs `fyke service status|install|uninstall`, as the Mac's General tab does.

**UI side (everything else).**
- A `transport` interface with two implementations: Tauri IPC in the app, and a **WebSocket bridge used only in development and tests** (a Bun script, `desktop/tools/bridge.ts`, that bound to 127.0.0.1 forwards to the daemon socket and its event stream). With the bridge, the whole UI runs in an ordinary browser on the Mac against a real daemon. That is what makes fast local testing possible.
- Port `gui/Sources/ReaderLogic` (rules, sentences, pure logic) to TypeScript modules with the same names and their `gui/Tests` cases as `bun test` tests. Model state the way `AppModel.swift` and `Models.swift` do, so a reader of both codebases can map one to the other.
- **Feed content never becomes HTML.** The reader builds DOM nodes from the daemon's blocks and sets `textContent` and attributes, never `innerHTML` with feed data. Links open in the web viewer or the browser as the Mac decides. A strict Content Security Policy: no remote scripts or styles; images only from where the Mac loads them.
- Fonts: bundle the files in `gui/Fonts` (Inter, Newsreader, Source Serif 4, JetBrains Mono, with their italics and OFL licenses) as `@font-face` with the variable axes (`opsz`, `wght`). Match the Mac's optical size and weight settings for each kind of text.

## Matching the Mac: how to reach and prove it

**Inventory first.** Before building screens, write `docs/desktop-parity.md`: every Swift file and the TS module that takes its job; every screen and state (below); every keyboard shortcut (⌘ becomes Ctrl, ⌥ becomes Alt, and list any that clash with Windows or Linux and what you chose); every undoable action; every piece of user-facing copy that depends on the platform ("on this Mac" becomes "on this PC" on Windows and "on this computer" on Linux, as the daemon already does for writers). Tick each line only with evidence: a test name or a snapshot pair.

**Screens and states to cover** (each in light and dark, and with each built-in theme where the Mac has one):
Today with a brief and citations (source pinned open), All, Starred, a folder, a feed, a saved view (sentence rule, chips, editing in place), search with results and with none, the command palette, the shortcuts sheet, catch-up, ask with a cited answer, recipe (open in place, edit, try, reset with undo), routines (list, editor, dry run, run), activity popover and the status line, feed health, toasts with Undo, the discussion / comments pane, the web viewer, add feed (discovery, preview, choosing a folder), folder and feed rename / move / delete with undo where the Mac has it, OPML import and export, the pane divider, folder disclosure that survives relaunch, empty / failed / in-progress states for every list, the daemon-unavailable state, and Settings: General, Reading (font family and weight per kind of text), Tokens (theme gallery, new theme, token editor), Agents (writers, profiles), Data (storage, trimming, data move).

**Every control has every state** (design rules): rest, hover, pressed, focus ring, selected, disabled; the right pointer cursor; motion 120–200 ms ease-out, off under `prefers-reduced-motion`; `forced-colors` (Windows high contrast) handled so nothing disappears.

**Window.** Default 1440 × 900, minimum 960 × 600, panes 232 / 368 / flexible, reading column 640 wide, exactly as the Mac. The Mac hides its title bar and draws the sidebar under the traffic lights. On Windows draw the same layout with the system caption buttons (minimize, maximize, close) at the top right and a drag region where the Mac has one; snap layouts must keep working. On Linux use client-side decorations that follow the same layout. Write the choice into the parity document.

**Pictures, compared.** Mirror the Mac's test mode (`FYKE_SCREEN`, `FYKE_KEYS`, `FYKE_SNAPSHOT`, `FYKE_HEADLESS`) so the same scenario can be photographed in both apps at 1440 × 900:
1. Move the fixture setup in `tools/e2e_gui.py` (the local feed server, the stand-in writer, the throwaway home, any frozen clock) into a shared module, so both apps photograph **identical data**. Keep `e2e_gui.py` working and passing.
2. Write `desktop/tests/snapshots` with Playwright that saves the same screen names as `zig-out/gui-snapshots` (`today-light.png`, `settings-tokens-dark.png`, …).
3. Write a comparison tool that, for every pair, reports a pixel difference score and writes a side-by-side and a difference image to `zig-out/parity/`. Run the UI in **Playwright WebKit on the Mac** for this comparison: it uses the same text rasterizer as the Mac app, so remaining differences are real. Chromium and the real WebView2 / WebKitGTK are checked for layout, not pixels.
4. Target: 99.99 % of pixels equal per screen after anti-aliasing tolerance, and every element's box within 1 px of the Mac's. Where that is impossible (a native control that differs by platform), say so in the parity document with the two images. Look at every difference image yourself before calling a screen done.

**Interactions, compared.** Port every scenario in `tools/e2e_gui.py` (`keys`, `themes`, `divider`, `move`, `settings-route`, `mark-all`, `rename`, `font-weight`, `view-save`, `catchup-keys`, `palette-keys`, `brief`, `answer`, `routine-save`, `discussion`, and every `shot:`) to Playwright, checking the same daemon state afterwards, and add scenarios for everything in the parity document that they do not cover. They run headless, in the background, without taking focus.

## Testing and checks

- Unit: `bun test` for logic, `cargo test` for the Rust side (socket and path resolution, URL and address guard, single instance, notify argument handling).
- UI: Playwright (WebKit and Chromium) against the real daemon through the bridge, headless.
- The real app: a WebDriver smoke test (`tauri-driver`) on Windows and Linux CI that launches the built app, connects, opens an article, opens Settings, and checks that the web viewer has no IPC access.
- Add the new suites to `tools/check.py` with rules so a change runs only what it affects. During work run only the affected checks. Run `python3 tools/check.py --all` once at the end of each phase.
- Everything except Windows packaging and the WebView2 smoke test runs on the Mac. Push when a phase is green locally; do not sit waiting for GitHub CI. Read CI results when they arrive and fix failures before the next phase.
- A second agent runs on the user's Windows PC. For checks only a person or a real Windows machine can do (Narrator, 100/150/200 % scaling, two monitors, high contrast, IME, installer upgrade and uninstall, notifications with no window open), write `docs/desktop-windows-checklist.md` with exact steps and expected results, and tell the user it is ready for that agent.

## Packaging, size and speed

- Windows: the Tauri NSIS installer, per user, no administrator prompt, with `fyke.exe` bundled. Keep what the WinUI installer did (read `bd837fa:gui-windows/installer/Fyke.iss` and `bd837fa:tools/e2e_installer_windows.py`): Start menu entry; optional `fyke` on PATH; optional start at sign-in through `fyke service install`; an upgrade over a running daemon; an upgrade or uninstall that closes only the app it installed; uninstall keeps feeds and articles. Port the installer end-to-end test.
- Linux: AppImage and `.deb`, with `fyke` bundled.
- Icons from the Mac icon (`tools/gen_icon.swift`), through `tauri icon`.
- The app must be **small on disk and fast**. Measure installed size, installer size, cold start to first article list, and idle memory on Windows and Linux in CI. Record the first measurement in the docs and set each CI budget a little above it; a later change that exceeds a budget must say why in its pull request.
- Release: extend `.github/workflows/release.yml` and `tools/release.py` so a tag publishes the Windows installer and the Linux packages beside the `fyke` archives, with checksums.

## Order of work

Each phase is one or more commits on the branch `feat/desktop-tauri` from `main`, and ends with its checks green and its parity lines ticked.

1. **Inventory**: `docs/desktop-parity.md` as described. No app code.
2. **Foundation**: scaffold `desktop/`; tokens and fonts; transport (Rust socket client and the bridge); daemon start and reconnect; event stream; test mode; the shared fixtures; the snapshot and comparison harness, proven on one screen.
3. **Reading**: sidebar (indent formula, disclosure, counts, the status line), article list, reader with every block type, divider, keyboard navigation, themes, light and dark, marks and stars.
4. **Finding and managing**: search, command palette, shortcuts sheet, mark all read with undo, add feed, folders and feeds (rename, move, delete, undo), OPML.
5. **Reader features**: saved views and sentence rules, Today and briefs with citations, recipes, ask, routines, catch-up, activity and health, discussion, web viewer.
6. **Settings**: all five tabs, including the theme gallery, new theme and token editor, font family and weight per kind of text, storage and data move, agents, background updating.
7. **Platform**: window chrome on both systems, single instance, `--notify`, high contrast, accessibility (roles, names, focus order; Narrator and Orca), Linux desktop checks.
8. **Ship**: installers and packages, their end-to-end tests, size and speed budgets, CI jobs (Linux and Windows), release workflow, `docs/desktop.md` (how it is built, run, tested and released), README and CHANGELOG lines, the Windows checklist.

## Working rules

- Follow `docs/design-rules.md`, including "Undo instead of confirm" and "States say three things".
- Code is readable, typed, documented where the reason is not obvious, and testable: logic out of components, side effects behind the transport.
- When behaviour changes, update the docs and `CHANGELOG.md` (entries say what a person would notice).
- Commits end with the co-author line the session gives you. Open one pull request for the branch early, as a draft, and update it as phases land; **do not merge it**. The user reviews and merges.
- Keep the user's name, email and other personal details out of anything sent to an outside service.
- Ask the user only when a decision is truly theirs and blocks you; otherwise choose, record the choice in the parity document, and continue.
- Report honestly: a check that failed, a screen that does not match yet, or a step skipped is said plainly, with the evidence.

## Done means

- Every line of `docs/desktop-parity.md` is ticked with evidence, and every disagreement with the Mac is either fixed or explained.
- Every screen in both themes passes the comparison target, and you have looked at every difference image.
- Every ported and new UI scenario passes headless; `bun test`, `cargo test` and `python3 tools/check.py --all` pass.
- CI builds, tests and packages the app on Windows and Linux, inside its budgets.
- The installer and Linux packages install, upgrade and uninstall in their end-to-end tests.
- `docs/desktop-windows-checklist.md` is written and handed to the user for the Windows PC agent.
