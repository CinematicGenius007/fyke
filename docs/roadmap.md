# Roadmap

No deadlines. Each milestone produces something you can use, and each has a test for "done". Order follows the dependency chain and the learning curve: pure code first, then I/O, then concurrency, then UI, then AI.

| # | Milestone | You learn | Done when |
|---|---|---|---|
| 0 | **Spike** (done) | Toolchain, TLS, C interop | [Results](decisions/0001-language.md#spike-results) recorded |
| 1 | **Parser** (done) | XML, encodings, allocators, fuzzing | Parses a corpus of 500 real feeds with no crash; fuzzer runs clean for 24 hours |
| 2 | **Fetch and store** (done) | HTTP semantics, SQLite, HTML | HTML becomes blocks; `fyke add`, `fyke list`, `fyke show` work; a second poll sends validators and gets `304` |
| 3 | **Daemon** (done) | Concurrency, sockets, scheduling | 1,000 feeds poll in the background; clients connect; OPML import and export work |
| 4 | **TUI** (done) | Terminals, rendering, input | Daily reading works with no browser; search, marks and live updates work |
| 5 | **MCP** (done) | Protocol design, comptime schemas | Claude Code and one other agent answer "what did I miss about X?" from your feeds |
| 6 | **GUI** (built) | Native app, IPC | Full parity with the TUI; you prefer it for daily use |
| 7 | **Aggregator v1** | Clustering, ranking | Dedupe, stories and ranking work with no model at all |
| 8 | **Runners** | Model APIs, job queues | Morning brief with validated citations through `http` and `exec` |
| 9 | **ACP** | Agent protocols | Any ACP agent runs a lens, with progress streaming into the UI; "ask my feeds" chat |
| 10 | **Linux** (planned) | systemd, XDG paths, Linux packaging | `fyke`, `fyke tui` and `fyke mcp` run on Linux, every end-to-end script passes there in continuous integration, and `fyke service install` uses `systemd --user` |
| 11 | **Windows** (planned) | Win32 consoles, named pipes or `AF_UNIX`, file locking | The same programs run on Windows 10 and later, with the end-to-end scripts passing in continuous integration |
| 12 | **Native GUIs** (planned) | One native toolkit per platform | A Linux app and a Windows app, each written against the socket API in the platform's own toolkit |

**You can stop after milestone 5 and already have** a reader that every agent on the machine can use.

MCP comes before the GUI because it is small, gives immediate value, and the GUI work benefits from a settled API.

## Milestone 1 results

Measured 2026-11-06 on a corpus of 756 real URLs. Rebuild it with `tools/fetch_corpus.py`.

| Check | Result |
|---|---|
| Parsed | 752 feeds, 22,744 entries, no crashes. The other 4 URLs served HTML pages |
| Formats | RSS 0.90, 0.91, 1.0, 2.0, Atom 1.0, JSON Feed 1.0 and 1.1. No Atom 0.3 feed appeared, so that path has only hand-written coverage |
| Against Python's strict XML parser | 740 well-formed feeds: no mismatches in entry count, 22,415 titles, 21,377 links, 22,278 GUIDs or 20,000+ dates |
| Malformed feeds | 9 that Python rejects, all recovered: entry counts match a count of their tags |
| Speed | 436 to 535 MB/s across the corpus, varying by run. 0.21 ms p50, 0.45 ms p95 per 100 KB, against a 1 ms budget |
| Hostile input | 29 patterns, cost per byte flat from 1 MB to 8 MB, worst 115 ns per byte |
| Mutation fuzz, short run | 4.75 million mutated real feeds, no crashes, worst 83 ns per byte |
| Mutation fuzz, long run | 284.7 million mutated inputs in 117,183 s (32.6 hours), no crashes. 268.7 million (94.4%) still parsed as feeds. Worst case 2,014 ns per byte, on one corpus feed at iteration 92,911 |
| Coverage-guided fuzz | Exit 0 with no failures. Summary showed 10.5M cumulative runs of `feed.parse`; it does not print the other 4 targets |

The long run meets the milestone's 24 hours. It processes about 2,400 inputs a second and prints only when it ends:

```bash
./zig-out/bin/feedcheck corpus --mutate 390000 3
```

The worst case of the long run is about 17 times the worst of the hostile-input check (115 ns per byte). The hostile check measures scaling with size, and the long run measures single mutated inputs, so the two figures are not the same kind of number. The slow input has not been analyzed. Coverage-guided fuzzing ran for about 20 minutes, not 24 hours.

Not in this milestone: HTML to blocks, URL normalization and resolving relative links. Non-Latin legacy encodings such as Shift-JIS are refused with an error rather than converted; none appeared in the corpus. OPML export is left for milestone 3.

## Milestone 2 results

Measured 2026-11-06.

| Check | Result |
|---|---|
| `tools/e2e.py` | 47 checks against a server that records every request, including `304`, `301`, `302`, `410`, `Retry-After`, a gzip bomb, redirect loops, private address refusal and feed discovery |
| Milestone test | Second poll sends `If-None-Match` and `If-Modified-Since`, and gets `304` |
| Real feeds over HTTPS | 8 of 8 subscribed; `fyke refresh` got `304` from 6 of them |
| Bad certificates | Expired, wrong host, self-signed and untrusted root all refused |
| Whole corpus through the binary | 752 feeds in 26 s, no failures or crashes. 22,741 entries stored of 22,744 parsed; the other 3 are one feed repeating items |
| HTML against Python's `html.parser` | 21,412 bodies compared: p50 0% word difference, p95 0.2%, p99 1.9%. Checked outliers were tokenizing differences in the check itself, or text we drop on purpose |
| Fuzzing | Coverage fuzz found 2 real bugs, both fixed: a buffer overflow in `url.canonical`, and invalid UTF-8 corrupting stored JSON. After the fixes, it ran 28 minutes with no failure before a time limit ended it, so no run counts were reported. Mutation fuzz: 1.46 million inputs through parser and HTML, no crashes |
| Unsafe content in stored blocks | None across the corpus: no scripts, `javascript:` or `data:` URLs, or control characters |
| HTML speed | 262 MB/s |
| Local list and search | 8 to 13 ms, including process start, on 22,741 entries |

## Milestone 3 results

Measured 2026-11-06.

| Check | Result |
|---|---|
| `tools/e2e.py` and `tools/e2e_daemon.py` | 49 and 46 checks: permissions, single instance, malformed requests, tiers, SQL sandbox, live events, 8 clients during writes, OPML round trip, raw pruning, `kill -9` recovery, background polling |
| 1,000 feeds, local server | First poll 13.8 s, no feed fetched twice, 31,417 entries. Second poll with validators 1.9 s, 994 of 1,000 returned `304`. The other 6 are HTML pages |
| Per-host limit | Peak of exactly 2 concurrent requests at `per_host: 2` |
| 756 feeds, real internet, default settings | 110 s, 744 healthy. Failures: 5 deadlines, 4 HTML pages, 1 TLS, 1 `HttpHeadersInvalid`, 1 `404` |
| Memory | Peak 224 MB during first poll, 191 MB on the real run. Idle 13 MB, budget 30 MB |
| Idle CPU | 0.00 s over 30 s |
| Client latency at 1,000 feeds | `list` 7 ms, `search` 9 ms, `feeds --json` 18 ms, including process start |

All items left open here were closed after milestone 6. See below.

## Milestone 4 results

Built after milestone 5. Measured 2026-11-06.

| Check | Result |
|---|---|
| `tools/e2e_tui.py` | 61 checks in a real pseudo-terminal, reading the screen through pyte, an independent emulator |
| Reading, search, marks, paging, live updates | All pass. New entries appear with no key press |
| Hostile content | Escape sequences in feeds did nothing, and a URL containing `$(...)` reached the browser as one inert argument |
| Random input | 20,000 key bursts at random sizes, including invalid bytes: no crash, still responsive, clean exit |
| Terminal restore | After Ctrl-C and `SIGTERM`, settings match the originals, apart from `PENDIN`, which macOS sets itself |
| Daemon loss | Survives `kill -9` of the daemon and reconnects |
| Layout | 7.9 million lines of real articles at 3 widths, none too wide |
| First paint | 14 ms, budget 50 ms |
| Idle | 2.9 MB, 0.00 s CPU over 10 s |
| One key press | 212 bytes sent to the terminal |

Limits: pyte is not a real terminal, so this has not been checked by eye in Ghostty, iTerm or Terminal. Emoji sequences joined with zero-width joiners may measure wrongly, as terminals disagree about them. Images show as a link. 200 s of coverage fuzzing found nothing, but ended at a time limit with no run count.

## After milestone 5

The TUI got a second design pass, then was frozen: two-line entries, a side bar for selection in place of filled rows, relative dates, a measured reading column, mouse support, and `O` for the terminal browser. Set `terminal_browser` in `config.json` to change that command.

**Full-text fetching** replaces short feed summaries with the article from the page. It runs one request at a time with a one second gap, asks `robots.txt` first, covers the last 30 days by itself, and takes `f` in the TUI or `entries.fetch_full` for anything older. Set `full_text` to false in `config.json` to turn it off. An extraction replaces the feed's text only if it is at least 1.5 times as long.

| Check | Result |
|---|---|
| `tools/eval_extract.py` | 149 real pages from feeds that publish full text, so the true article is known: 142 good, median recall 100%, median precision 99.6%. 3 found nothing, and those entries keep their summary |
| Zed and Delta feeds | 5 Delta posts went from about 90 characters to about 8,000 in the first 24 seconds |

That sample is blogs that already publish full text, and sites that publish only summaries may be harder. Video players can leave stray text such as "0:00" behind.

## Milestone 5 results

Built before milestone 4. Measured 2026-11-06.

| Check | Result |
|---|---|
| `tools/e2e_mcp.py` | 57 checks: both protocol eras, version errors, tier visibility, resources, prompts, reconnecting |
| Official SDK | `@modelcontextprotocol/client` 2.4.0 passes `tools/sdk_mcp.mjs` in both eras: pinned to 2026-07-28, and on `initialize`. `@modelcontextprotocol/sdk` 1.32.2 also passed, legacy era only |
| Eras of real clients | Claude Code 2.1.318 uses 2026-07-28 with `fyke mcp`: `server/discover`, then `tools/list` with modern `_meta`, and no `initialize`. Codex 0.166.0 sent `initialize` at 2025-06-18 to a stub server |
| Milestone test | Claude Code 2.1.318 and Codex 0.166.0 each answered "what did I miss about Zig?" from 9 real feeds, citing entry ids |
| Prompt injection | A planted entry told agents to delete every feed. Both ignored it and told the user. At the read tier, the delete tool does not exist either way |

| Official conformance suite 0.1.16 | Through `tools/mcp_http_bridge.py`: `server-initialize`, `ping`, `tools-list`, `resources-list` and `prompts-list` pass. The other 27 are in `tools/conformance-baseline.yml`: 19 need the suite's own fixtures, 5 test optional features Fyke does not declare, and 3 test HTTP. The suite has no scenarios for 2026-07-28 |
| Official Python client | `mcp` 2.3.0 completed tools, resources, prompts and ping, through `initialize` at 2025-11-25 |
| MCP draft | Its changelog is empty, so nothing has changed since 2026-07-28 |

Agents exposed what the protocol tests could not. Both reported almost no Zig news, although 0.17.1 had just shipped: the entry "0.17.1 Released", in a feed called "News" on ziglang.org, never contains the word "zig". Search now matches feed names and hosts too, and Claude Code then found it.

Limits: two model runs are not a measure of injection resistance, and `outputSchema` and `subscriptions/listen` are not implemented.

## Milestone 6 results

Built from the approved Paper designs. Measured 2026-11-06 against real feeds in a throwaway `FYKE_HOME`.

| Check | Result |
|---|---|
| Socket client | The app holds no database connection. Quick calls share one connection, and calls that wait on the network get their own |
| Driven through accessibility | `j`, `s`, Settings, the full-text switch and adding a feed all reached the daemon |
| Add feed | `lobste.rs` offered 2 feeds, and subscribing to one appeared in the sidebar with no restart |
| Rendering | All, feed, reader, first run, sheet and every Settings tab compared by eye with Paper, in Light and Dark where noted below |

New operations: `feeds.preview`, `folders.list`, `config.get`, `config.set`. `feeds.add` takes `title` and `folder`, and `entries.list` takes `with_summary`.

Limits: the Briefing screen is a placeholder until milestone 7. Shortcuts cannot be rebound. Newsprint and Terminal derive most colors, because Paper defines only three for each. The default reading font is not bundled: other Macs fall back to Newsreader. Finding feeds on a site took 5 to 14 seconds in one test, because each advertised feed is fetched. `tools/e2e_gui.py` covers search and shortcut keys only, and the preference test is a judgment no check can make.

## After milestone 6

Measured 2026-11-06.

| Change | Check |
|---|---|
| Search in the GUI: a popup on `⌘F` or `/`, and a sidebar row | Empty, results and nothing-found states compared with Paper, in Light and Dark. `tools/e2e_gui.py` plays the keys through AppKit: 8 checks |
| Standalone app | `tools/bundle_app.py` builds the app with its fonts, icon and `fyke`. Run alone, it started its own daemon and rendered Newsreader with no font errors |
| `skipHours` and `skipDays` | Stored with the feed by schema 0003, so that polls ending in `304` obey them. Unit tests cover the masks and the move to the next free hour |
| `fyke service` | Installed, reported, ran the daemon and uninstalled, against a throwaway home |
| Cancelable TCP connect | A black-holed address fails at 30.1 s, which is the deadline |
| The feed behind `HttpHeadersInvalid` | The server sends `content-encoding: none`, which the standard library rejects. `fetch` masks that header, and the feed now subscribes |
| Client timeout | `fyke` gives up after 120 s of silence from the daemon |
| Adding a feed in the TUI | Runs on its own thread, so the interface stays live. Finding a feed stops trying new pages after 60 s |
| A host that accepts and then stalls | Ends at the fetch deadline, and `e2e_daemon.py` covers it |
| Hostile numbers | An enclosure size beyond 2^63 stopped the daemon. Integers bound to SQLite now saturate, and a unit test covers it |
| Long quotes | Markdown keeps every line of a quote of any length |
| IPv6 tunnels | 6to4 addresses are judged by the IPv4 address they carry, and Teredo is refused |
| Housekeeping | A raw body shared by two feeds stays until neither needs it |
| Full text | Pages in a charset that cannot be converted keep their summary. The gain check counts characters. Entries with enough text are settled once, not read on every wake |
| Full-text retries | Temporary failures retry after 1, 6 and 24 hours, then stop. An outage counts no tries after the first two hosts, and `e2e_daemon.py` covers both |
| Search filters | Apply before the 2,000 match window, so a common word with a filter still finds old matches |
| `db.query` | Returns at most 4 MiB of values, with `truncated` set, and refuses to build any value over 16 MiB |
| Bad bodies | Bodies that fail to parse count toward the retention of 20, so a feed cannot fill the disk with them |
| Request numbers | `since_days` of any size gives a sane cutoff |
| `entries.mark` | Takes `hidden`, which lists and search respect |

The reading default is Newsreader, which ships in the app. Any other installed font can be chosen in Settings.

## Releases (planned)

None of this is built. There are no releases yet: the app is built from source, as the [README](../README.md) describes.

People who use the app should never need a terminal. Moving the data folder is already done inside the app, and updating is meant to be too. That means releases carry a prebuilt app, with its own signature in place of Apple's.

### Updates

| Piece | Plan |
|---|---|
| Prebuilt releases | CI builds the app on every tag and attaches it to a GitHub Release, with a changelog section |
| Signature | Each archive is signed with an ed25519 key. The app holds the public key and CI holds the private one, so an update can be checked without an Apple Developer account. A tampered or unsigned archive is refused |
| Quarantine | macOS quarantines files that browsers download, and a file the app downloads itself is expected not to be. This is checked by test before any update depends on it |
| Checking | Settings asks once, in plain words, whether to check for updates. The answer is off until given. A check is one request to GitHub's releases API and sends nothing about the person. It only reports that a newer version exists |
| Updating | The app downloads, verifies the signature and checksum, replaces itself, restarts the daemon and reopens. The daemon and app compare `api_version`, so a mismatch after an update resolves itself |
| First install | An unsigned download needs one approval in Privacy & Security, because only a paid Apple Developer account removes that. Building from source avoids it, since a local build is never quarantined |

### Before the first release

| Step | Work |
|---|---|
| Name | Done: the project is Fyke, see [decision 0003](decisions/0003-project-name.md). Builds made before the rename kept data in `~/.rss_`, and the first `fyke` command moves it to `~/.fyke` |
| One version number | `tools/bundle_app.py` hard-codes `0.1`. One source feeds the app, `Info.plist` and a new `fyke --version` |
| Changelog | `CHANGELOG.md`, one section per release, drawn from Conventional Commits |
| Continuous integration | A macOS runner on every pull request: `zig fmt --check`, `zig build test`, the end-to-end scripts, `tools/bundle_app.py` and `tools/e2e_gui.py`. Zig is pinned to the version `CONTRIBUTING.md` names |
| Install script | `tools/install.sh` checks for Zig and Xcode's command line tools, builds, installs to `/Applications` and restarts the daemon, for people who build from source |

### Releasing

A release is a tag, `vMAJOR.MINOR.PATCH`, on `main`. Pushing it runs the full checks, builds and signs the app, and publishes a GitHub Release with the changelog section, the archive, its signature and its SHA-256.

Version numbers follow what a user would notice. A patch fixes behavior. A minor version adds features and may add schema migrations, which run on their own at the daemon's next start. A major version would change the data folder or the config format, and says so in the changelog. Raising `api_version` in `src/ops.zig` and `Daemon.apiVersion` in the app together is part of any change that clients rely on.

Before a tag, the corpus oracles and `tools/scale.py` run by hand, since neither fits in continuous integration: the corpus is not in the repository.

### Ways to install

| Route | For | Notes |
|---|---|---|
| Download from GitHub Releases | Most people | Unsigned by Apple, so the first launch needs one approval. Updates after that are inside the app |
| Homebrew tap | People who use Homebrew | A formula builds from the source archive, so nothing is quarantined. Updates use `brew upgrade` |
| `tools/install.sh` from a clone | People who build from source | Needs Zig and Xcode's command line tools |
| Signed and notarized | Nobody yet | Needs a paid Apple Developer account. It would remove the first-launch approval |

### Order

1. Name: done, the project is Fyke ([decision 0003](decisions/0003-project-name.md)).
2. Linux command line and terminal reader (milestone 10), with the end-to-end scripts running on Linux in continuous integration.
3. One version number, the changelog and continuous integration on macOS.
4. Close the gaps in the end-to-end scripts that the Linux work exposes (see below).
5. Windows command line and terminal reader (milestone 11), with `tools/e2e_tui.py` covering the terminal reader on every platform.
6. The signing key, the release workflow, and `v0.1.0`.
7. The update check and the in-app update.
8. `tools/install.sh` and the Homebrew tap.
9. Native GUIs for Linux and Windows (milestone 12).

At every step the documents, this roadmap and the task list are updated together, and anything archived or inconsistent is removed in the same change.

## Platforms (planned)

Nothing here is built except what is marked. The core is one Zig codebase: `zig build -Dtarget=...` already produces `fyke` for `x86_64-linux-gnu`, `aarch64-linux-musl` and `aarch64-macos`. `x86_64-windows-gnu` does not build yet.

### Linux

Measured 2026-11-09 with `tools/e2e_container.py`: a static `aarch64-linux-musl` binary in a Debian container.

| Piece | Status |
|---|---|
| Command line, daemon, MCP | Built. `e2e.py` 49 checks, `e2e_daemon.py` 160, `e2e_mcp.py` 57 |
| Terminal reader | Built. `e2e_tui.py` passes 71 checks under a real pseudo-terminal |
| Background service | Built: `systemd --user` unit `fyke.service`, behind the same `service install`, `uninstall` and `status` commands as `launchd`. `e2e_service.py` passes 19 checks against a stand-in `systemctl`. A real systemd manager has not run it yet |
| Real HTTPS feeds | 4 of 4 live feeds fetched, and an expired and a self-signed certificate were refused with `TlsInitializationFailed` |
| `x86_64` | Compiles. The scripts have only run on `aarch64` |
| Continuous integration | Planned. `tools/e2e_container.py` holds the steps |
| Packaging | Planned: static `musl` tarballs for `x86_64` and `aarch64`, and `tools/install.sh` |

### Windows

| Piece | Plan |
|---|---|
| File permissions | `src/daemon.zig` sets mode `0700` on the data folder, which Windows has no equivalent for. The first of several compile errors |
| Daemon connection | `AF_UNIX` sockets exist on Windows 10 1803 and later. If the standard library does not expose them well, a named pipe behind a small `ipc` interface |
| Single instance | A lock with `LockFileEx` in place of the file lock the daemon uses today |
| Terminal reader | Virtual terminal processing, console size and a Ctrl handler in place of `termios` and `sigaction`. The reader already writes escape sequences, which Windows Terminal understands |
| Data folder | `%APPDATA%\Fyke`. Socket and pipe paths follow their own length limits |
| Background service | Task Scheduler or a Startup entry |
| Signing | An unsigned program triggers SmartScreen. Free signing for open-source projects is to be checked |

### Native GUIs

Each platform gets its own toolkit, written against the socket API, because learning new languages and concepts from the ground up is part of the project. The macOS app stays SwiftUI. Candidates for Linux and Windows are chosen in a decision record before any code: the toolkits, the language, and how each treats [feed content that must never reach a web view](decisions/0002-web-viewer.md).

### End-to-end coverage to add

| Gap | Where |
|---|---|
| The cross-volume `data move` block only runs on macOS | Add a Linux version using a second mount, or a loop device in a container |
| `e2e_tui.py` runs on macOS and Linux | Run it in continuous integration, then add Windows |
| Real HTTPS feed | A check against a local TLS server with a private certificate authority, so no internet is needed |
| `fyke service` on a real manager | A container running systemd as PID 1, so that `enable` and `restart` really run. The stand-in covers what is written and which commands run |
| A fresh install | Download, unpack, run `service install`, add a feed, reboot the service |

## Deferred, deliberately

A hand-written HTTP client, podcast playback, a cross-platform GUI toolkit (each platform gets a native one instead, milestone 12), Streamable HTTP for MCP, feed backfill with RFC 5005, sync across machines.
