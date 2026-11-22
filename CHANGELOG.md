# Changelog

All notable changes are listed here, newest first. Each release is a section headed by its version and date. Entries say what a person using the app would notice. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow the rules in [the roadmap](docs/roadmap.md#releasing).

There are no releases yet. Everything below is built from source and is unreleased. Edit this file by hand as work lands: add a line under Unreleased with the change, and at release time rename that section to the version and date.

## Unreleased

### Added

- **`fyke --version`** prints the release number, which comes from the `VERSION` file.
- **Windows (preview).** `fyke.exe` builds for Windows 10 1803 and later, and runs the daemon, the command line and `fyke mcp`, checked in continuous integration. `fyke tui` runs in the Windows console, and `fyke service install` starts the daemon at sign-in through the `Run` key. `fyke data move` works there too, through a pointer file in `%LOCALAPPDATA%\Fyke`. Releases are not signed, so SmartScreen warns the first time: choose More info, then Run anyway.
- **Linux.** `fyke`, `fyke tui` and `fyke mcp` build for Linux. `fyke service install` writes a `systemd` user unit, `fyke.service`, that starts the daemon at login and restarts it after a crash.
- **Daemon.** One background process owns the database, polls feeds in the background and serves every client over a local socket. It starts on demand, and `fyke service install` runs it from login as a `launchd` agent (macOS) or a `systemd` user unit (Linux).
- **Feeds.** RSS 0.90, 0.91, 1.0 and 2.0, Atom 1.0 and JSON Feed 1.0 and 1.1. Conditional requests send validators and accept `304`. Redirects, `410`, `Retry-After`, compressed bodies, feed discovery from a page address, and OPML import and export are handled. Private addresses are refused.
- **Content.** Article HTML is converted to blocks when it is stored, so no surface renders raw HTML. When a feed gives only a summary, the daemon fetches the full article and retries temporary failures after 1, 6 and 24 hours.
- **Search.** Full-text search over titles, bodies, feed names and hosts, with filters that apply before the match window, so old matches for a common word are still found.
- **`fyke` command line.** `add`, `list`, `show`, `refresh`, `data move`, `service` and more, as a client of the daemon's socket. `--json` output is available for scripts.
- **`fyke tui`.** A terminal reader with search, marks, mouse support and live updates.
- **`fyke mcp`.** An MCP server on standard input and output for any agent on the machine, with a read-only SQL tool that is sandboxed and capped in size. It speaks both protocol eras.
- **macOS app.** A SwiftUI reader with folders, search, themes, a bundled reading font, its own controls and a page viewer that loads addresses only and never feed content. `python3 tools/bundle_app.py --install` builds and installs it.
- **Data folder.** Data lives in `~/.fyke`. `fyke data move`, and Settings > General, move it to another folder or volume, verify the copy, and undo the steps already done if one fails.
- **Website.** The project site in `site/` renders the documents in `docs/`.
- **Desktop app for Windows and Linux (in progress).** A Tauri 2 app in `desktop/` that matches the macOS app. So far: the sidebar with places, views and the feed tree, the timeline for All and Starred, a feed, folder or view beside the reader with a divider that resizes and resets, the reader with its actions, the Mac's keys for moving, opening, starring and marking, and links that open in the default browser, and search (Ctrl+F or /) with its arrow keys, unread-only scope and Ctrl+S to keep a search as a view, with undo, and the command palette (Ctrl+K or the sidebar's Search row) with places, views, feeds, articles and the commands built so far, the shortcuts sheet (?), and managing feeds: rename in place, right-click menus for views, folders and feeds, new folders, Move to, and delete and remove with a confirmation that keeps data by default, and its own window buttons and title strip on Windows and Linux, with Ctrl+Q to quit on Linux and the webview's print, reload, zoom and developer keys turned off. Routines that notify post a system notification, from the open app or, when it is closed, from a copy the daemon starts that opens no window; a second launch brings the open window forward. Screen readers get a name for every control, sidebar rows read their counts after their names, and Windows contrast themes keep selections, unread dots and panel edges visible. A per-user Windows installer, a `.deb` and an AppImage each bring the daemon along. The installer can put `fyke` on PATH and start the background service at sign-in, and uninstalling keeps your data. [desktop.md](docs/desktop.md) says how to build them, and [desktop-parity.md](docs/desktop-parity.md) tracks each line.

- **Desktop subscriptions.** Preview feeds before subscribing, choose or create a folder, drag feeds and folders in the sidebar, and import or export subscriptions with OPML.

- **Desktop reading.** Edit saved views from their sentence and undo rule changes. Use Ctrl+J to catch up on unread articles and press C from a Hacker News story to expand its discussion. Empty places, such as a view with nothing matching or an empty Starred, say so in the same type and spacing as on the Mac. A closed folder stays closed the next time the app opens.

- **Desktop briefs and questions.** Write a brief in Today, open its cited articles, edit and try recipes, ask follow-up questions, and schedule a routine from a saved view. Activity shows running jobs and feeds that need attention. Open public pages in the app on Windows and Linux; the web bar names your default browser, as in "Open in Firefox".

- **Desktop Settings.** Use General for fetching and opening links, Reading and Tokens for appearance (a font changed from the text menu or Reading can be saved to its theme, dropped, or saved as a new theme), Agents for writer and MCP settings, and Data for storage and the data folder.

### Changed

- **The project is named Fyke.** The command is `fyke`, the data folder is `~/.fyke` (set `FYKE_HOME` to use another), the app is `Fyke.app`, and the background service is `local.fyke.daemon`. Data in `~/.rss_`, from builds before the name, moves to `~/.fyke` the first time any `fyke` command runs, including a folder moved elsewhere with `data move`. Quit an earlier build's daemon first: while it runs, `fyke` stops with `EarlierDaemonRunning` and changes nothing. `fyke service install` and `uninstall` also remove a launch agent installed under the old label, and `bundle_app.py --install` removes `/Applications/rss_.app`.
- Search matches feed names and hosts as well as entry text.
- Settings follow `config.json` alone, and a half-applied change is refused instead of kept.
- The macOS app's article list starts 368 points wide, as the design rules set, instead of 375. Double-click the divider to return to it.

### Fixed

- macOS and desktop apps: when the background service does not start, the window says so at once instead of trying to replace it for about two and a half minutes, and a failed settings read is no longer called a config.json mistake. A theme chosen at launch holds even then.
- macOS app: picking one feed from several advertised by a site keeps that feed’s own name.

- macOS app: a folder name that is already taken now shows why it was refused.
- Every HTTPS fetch no longer crashes.
- A buffer overflow while canonicalizing addresses, and invalid UTF-8 that corrupted stored JSON, found by fuzzing.
- Fetch deadlines now hold on stalled reads.
- Full-article extraction no longer garbles pages and scans less of each one.
- The daemon replies before exiting when told to stop.
- A broken `config.json` is kept safe instead of being overwritten.
- macOS: a brief's sources note says "2 more read but not cited", not "2 mores".
- macOS: Mark All Read is not offered in Starred, Today or Routines. In Starred it used to mark every feed.
- A writer that is not installed is "Not found on this PC" on Windows and "Not found on this computer" on Linux, not "on this Mac". On Windows, a writer whose version check failed says so instead of "Not found".
- macOS: renaming a folder, feed or view in the sidebar saves on Return. Before, the reader's shortcuts took Return, Esc and letters such as j or n away from the name field, so nothing was saved.
