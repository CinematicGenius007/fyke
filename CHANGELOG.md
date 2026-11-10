# Changelog

All notable changes are listed here, newest first. Each release is a section headed by its version and date. Entries say what a person using the app would notice. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow the rules in [the roadmap](docs/roadmap.md#releasing).

There are no releases yet. Everything below is built from source and is unreleased. Edit this file by hand as work lands: add a line under Unreleased with the change, and at release time rename that section to the version and date.

## Unreleased

### Added

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

### Changed

- **The project is named Fyke.** The command is `fyke`, the data folder is `~/.fyke` (set `FYKE_HOME` to use another), the app is `Fyke.app`, and the background service is `local.fyke.daemon`. Data in `~/.rss_`, from builds before the name, moves to `~/.fyke` the first time any `fyke` command runs, including a folder moved elsewhere with `data move`. Quit an earlier build's daemon first: while it runs, `fyke` stops with `EarlierDaemonRunning` and changes nothing. `fyke service install` and `uninstall` also remove a launch agent installed under the old label, and `bundle_app.py --install` removes `/Applications/rss_.app`.
- Search matches feed names and hosts as well as entry text.
- Settings follow `config.json` alone, and a half-applied change is refused instead of kept.

### Fixed

- Every HTTPS fetch no longer crashes.
- A buffer overflow while canonicalizing addresses, and invalid UTF-8 that corrupted stored JSON, found by fuzzing.
- Fetch deadlines now hold on stalled reads.
- Full-article extraction no longer garbles pages and scans less of each one.
- The daemon replies before exiting when told to stop.
- A broken `config.json` is kept safe instead of being overwritten.
