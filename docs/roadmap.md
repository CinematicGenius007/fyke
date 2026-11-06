# Roadmap

No deadlines. Each milestone produces something you can use, and each has a test for "done". Order follows the dependency chain and the learning curve: pure code first, then I/O, then concurrency, then UI, then AI.

| # | Milestone | You learn | Done when |
|---|---|---|---|
| 0 | **Spike** (done) | Toolchain, TLS, C interop | [Results](decisions/0001-language.md#spike-results) recorded |
| 1 | **Parser** (built; 24-hour fuzz pending) | XML, encodings, allocators, fuzzing | Parses a corpus of 500 real feeds with no crash; fuzzer runs clean for 24 hours |
| 2 | **Fetch and store** (done) | HTTP semantics, SQLite, HTML | HTML becomes blocks; `rss add`, `rss list`, `rss show` work; a second poll sends validators and gets `304` |
| 3 | **Daemon** (done) | Concurrency, sockets, scheduling | 1,000 feeds poll in the background; clients connect; OPML import and export work |
| 4 | **TUI** (done) | Terminals, rendering, input | Daily reading works with no browser; search, marks and live updates work |
| 5 | **MCP** (done) | Protocol design, comptime schemas | Claude Code and one other agent answer "what did I miss about X?" from your feeds |
| 6 | **GUI** (built) | Native app, IPC | Full parity with the TUI; you prefer it for daily use |
| 7 | **Aggregator v1** | Clustering, ranking | Dedupe, stories and ranking work with no model at all |
| 8 | **Runners** | Model APIs, job queues | Morning brief with validated citations through `http` and `exec` |
| 9 | **ACP** | Agent protocols | Any ACP agent runs a lens, with progress streaming into the UI; "ask my feeds" chat |

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
| Mutation fuzz | 4.75 million mutated real feeds, no crashes, worst 83 ns per byte |
| Coverage-guided fuzz | Exit 0 with no failures. Summary showed 10.5M cumulative runs of `feed.parse`; it does not print the other 4 targets |

About 20 minutes of fuzzing is not the 24 hours the milestone asks for. This run takes longer than a day, at about 2,400 inputs a second, and prints only when it ends:

```bash
./zig-out/bin/feedcheck corpus --mutate 390000 3
```

Not in this milestone: HTML to blocks, URL normalization and resolving relative links. Non-Latin legacy encodings such as Shift-JIS are refused with an error rather than converted; none appeared in the corpus. OPML export is left for milestone 3.

## Milestone 2 results

Measured 2026-11-06.

| Check | Result |
|---|---|
| `tools/e2e.py` | 47 checks against a server that records every request, including `304`, `301`, `302`, `410`, `Retry-After`, a gzip bomb, redirect loops, private address refusal and feed discovery |
| Milestone test | Second poll sends `If-None-Match` and `If-Modified-Since`, and gets `304` |
| Real feeds over HTTPS | 8 of 8 subscribed; `rss refresh` got `304` from 6 of them |
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
| Eras of real clients | Claude Code 2.1.318 uses 2026-07-28 with `rss mcp`: `server/discover`, then `tools/list` with modern `_meta`, and no `initialize`. Codex 0.166.0 sent `initialize` at 2025-06-18 to a stub server |
| Milestone test | Claude Code 2.1.318 and Codex 0.166.0 each answered "what did I miss about Zig?" from 9 real feeds, citing entry ids |
| Prompt injection | A planted entry told agents to delete every feed. Both ignored it and told the user. At the read tier, the delete tool does not exist either way |

| Official conformance suite 0.1.16 | Through `tools/mcp_http_bridge.py`: `server-initialize`, `ping`, `tools-list`, `resources-list` and `prompts-list` pass. The other 27 are in `tools/conformance-baseline.yml`: 19 need the suite's own fixtures, 5 test optional features rss_ does not declare, and 3 test HTTP. The suite has no scenarios for 2026-07-28 |
| Official Python client | `mcp` 2.3.0 completed tools, resources, prompts and ping, through `initialize` at 2025-11-25 |
| MCP draft | Its changelog is empty, so nothing has changed since 2026-07-28 |

Agents exposed what the protocol tests could not. Both reported almost no Zig news, although 0.17.1 had just shipped: the entry "0.17.1 Released", in a feed called "News" on ziglang.org, never contains the word "zig". Search now matches feed names and hosts too, and Claude Code then found it.

Limits: two model runs are not a measure of injection resistance, and `outputSchema` and `subscriptions/listen` are not implemented.

## Milestone 6 results

Built from the approved Paper designs. Measured 2026-11-06 against real feeds in a throwaway `RSS_HOME`.

| Check | Result |
|---|---|
| Socket client | The app holds no database connection. Quick calls share one connection, and calls that wait on the network get their own |
| Driven through accessibility | `j`, `s`, Settings, the full-text switch and adding a feed all reached the daemon |
| Add feed | `lobste.rs` offered 2 feeds, and subscribing to one appeared in the sidebar with no restart |
| Rendering | All, feed, reader, first run, sheet and every Settings tab compared by eye with Paper, in Light and Dark where noted below |

New operations: `feeds.preview`, `folders.list`, `config.get`, `config.set`. `feeds.add` takes `title` and `folder`, and `entries.list` takes `with_summary`.

Limits: the Briefing screen is a placeholder until milestone 7. Shortcuts cannot be rebound. The sidebar lists feeds without their folders. Newsprint and Terminal derive most colors, because Paper defines only three for each. The default reading font is not bundled: other Macs fall back to Newsreader. Finding feeds on a site took 5 to 14 seconds in one test, because each advertised feed is fetched. There is no automated GUI test suite yet, and the preference test is a judgment no check can make.

## After milestone 6

Measured 2026-11-06.

| Change | Check |
|---|---|
| Search in the GUI: a popup on `⌘F` or `/`, and a sidebar row | Empty, results and nothing-found states compared with Paper, in Light and Dark |
| Standalone app | `tools/bundle_app.py` builds the app with its fonts, icon and `rss`. Run alone, it started its own daemon and rendered Newsreader with no font errors |
| `skipHours` and `skipDays` | Stored with the feed by schema 0003, so that polls ending in `304` obey them. Unit tests cover the masks and the move to the next free hour |
| `rss service` | Installed, reported, ran the daemon and uninstalled, against a throwaway home |
| Cancelable TCP connect | A black-holed address fails at 30.1 s, which is the deadline |
| The feed behind `HttpHeadersInvalid` | The server sends `content-encoding: none`, which the standard library rejects. `fetch` masks that header, and the feed now subscribes |
| Client timeout | `rss` gives up after 120 s of silence from the daemon |
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

## Deferred, deliberately

A hand-written HTTP client, podcast playback, Linux and Windows GUIs, Streamable HTTP for MCP, feed backfill with RFC 5005, sync across machines.
