# 0001: Language

Status: accepted 2026-11-06, after the [spike](#spike-results) passed. Researched November 2026.

## Decision

**Zig for the core, CLI, TUI and MCP server. SwiftUI for the macOS GUI, connected over the daemon socket.**

Pin Zig to 0.17.1, the latest tagged release (2026-11-02).

This is the structure [Ghostty](https://github.com/ghostty-org/ghostty) uses, the best-known desktop application written in Zig: a shared Zig core, with SwiftUI on macOS and GTK on Linux.

## What matters here

In priority order, from the project's goals:

1. Teaches how things work, with nothing hidden
2. Efficient: memory, startup, idle cost
3. A GUI that is good for long reading sessions
4. Learning Zig is a goal of the project
5. No deadline, so churn costs patience, not delivery

## Options

| | Zig + SwiftUI | Zig everywhere | Rust | Swift only | Go |
|---|---|---|---|---|---|
| Learning from scratch | Best | Best | Good | Fair | Fair |
| Efficiency | Best | Best | Best | Good | Fair |
| GUI for reading today | Best | Weak | Fair | Best | Weak |
| Learn Zig | Yes | Yes | No | No | No |
| Toolchain stability | Weak | Weakest | Best | Good | Best |
| Cross-platform GUI | No | Yes | Yes | No | Partly |
| Languages to learn | 2 | 1 | 1 | 1 | 1 |

**Why Zig suits this project.** Allocators are explicit, and a feed reader is a natural fit for arenas: one per fetch, freed at once. With no XML library in the standard library, the parser is yours by necessity. `comptime` reflection can generate the JSON Schemas for MCP tools from plain structs, which is what the [operation registry](../api.md#operation-registry) needs. C interop gives direct access to SQLite.

The standard library has what the core needs. Checked in the 0.17.1 source: `std.http.Client`, `std.crypto.tls.Client`, gzip (`flate`) and `zstd` decompression, and `std.json`. There is no `std.xml`.

**Why not Rust,** the serious alternative. It is the safer engineering choice: stable, and memory-safe on hostile input without relying on fuzzing. It loses on two counts. Learning Zig is a goal here, and Rust's ecosystem makes the from-scratch path feel like an artificial handicap, where in Zig it is simply how you work. Choose Rust if stability ever outranks learning.

**Why not Swift alone.** The best GUI result for the least work, but it teaches the least about the layers this project exists to explore.

**Why not Go.** Productive and stable, but the garbage collector and weak native GUI story work against the efficiency goal.

## Zig GUI: the honest state

These projects are moving fast. None was ready to carry a reading app when this was written.

| Project | Approach | State |
|---|---|---|
| [DVUI](https://github.com/david-vanderson/dvui) | Immediate mode | Most established. Accessibility through AccessKit. README lists Zig 0.16 |
| [Gooey](https://github.com/duanebester/gooey) | GPU-rendered hybrid | "Early Development", API changing. Has VoiceOver support. One global font |
| [zigui](https://github.com/ddalcu/zigui) | SwiftUI-style, own renderer | "Pre-alpha", 27 commits. Needs Zig 0.17 |
| [Capy](https://github.com/capy-ui/capy) | Native OS controls | README warns it is not production ready. Targets Zig 0.14.1 |

A reader is a text application, which is the hardest case for a custom-rendered toolkit. It needs mixed fonts, shaping for every script, selection across paragraphs, smooth scrolling through long content, and accessibility. As one example, a single global font rules out body text next to monospace code. SwiftUI and CoreText provide all of this for free.

**The architecture keeps this option open.** The GUI is only a socket client. Once the API settles, a Zig GUI is a self-contained experiment that touches nothing else, and the best of these toolkits may be ready by then.

## Risks

| Risk | Evidence | Response |
|---|---|---|
| **Breaking changes** | Pre-1.0. 0.17 alone removed `@cImport`, renamed allocators and deprecated `std.builtin` | Pin the version. Upgrade deliberately. Keep stdlib use behind small wrappers |
| **Fewer memory guarantees than Rust** | The parser takes hostile input | Ship the `safe` optimize mode, fuzz from day one, use the 0.17 `SafeAllocator` in tests |
| **Gaps in the standard HTTP client** | Matched curl on 200 feeds, but its TCP connect cannot be timed out or canceled | Solved in `src/fetch.zig`, which replaces connect through the `Io` interface. `fetch` is an interface, so libcurl remains a fallback |
| **SQLite binding work** | `@cImport` is gone | Solved in the spike: hand-written `extern` declarations work, and the amalgamation builds from `build.zig` |
| **Two languages** | Swift is new work | The GUI is thin, and it does not start until milestone 6 |
| **macOS only** | SwiftUI | Accepted. A later Linux client would use GTK or a Zig toolkit over the same socket |

## Spike before committing

Milestone 0, a few evenings of throwaway code, to test the riskiest assumptions before building on them:

1. Fetch 200 real feeds with `std.http.Client` over TLS, with gzip, redirects and conditional GET.
2. Build the SQLite amalgamation from `build.zig` with FTS5 on. Insert 1,000,000 rows and run the search budget from [architecture.md](../architecture.md#performance-budgets).
3. Build a minimal SwiftUI app that reads 10,000 rows over a Unix socket and scrolls smoothly.

| Result | Then |
|---|---|
| All pass | Accept this decision |
| TLS or HTTP failures | Keep Zig, move `fetch` to libcurl |
| Working in Zig proves unpleasant | Switch to Rust. The design and schema carry over unchanged |

## Spike results

Run 2026-11-06: Zig 0.17.1, SQLite 3.54.1, Swift 6.4, Apple silicon. Code is in [spikes/](../../spikes/README.md). Criteria 1 and 3 passed. Criterion 2 passed except for one search case, which is a SQLite and design matter, not a language one.

### 1. HTTP and TLS: pass, with one gap

200 feeds: 30 large sites and 170 sampled from Kagi's small web list. Every result was compared with curl.

| Measure | Result |
|---|---|
| `200` responses | Zig 195, curl 194. Zig got all of curl's, plus Reddit, which refused curl |
| Failures only Zig had | **0** |
| Other outcomes | 3 × `404`, 1 connect timeout, 1 TLS failure. curl failed on all of these too |
| Content encoding | 169 gzip, 26 identity, all decoded |
| Redirects | 5 followed, all permanent |
| Conditional GET | 161 of 178 returned `304`. The other 17 returned `200` with identical bytes |
| One process, shared client, 16 workers | 194 successes; one slow host hit the 15 s deadline. Peak RSS 92 MB, including an 8 MB feed |

Findings that change the design:

- **TCP connect has no timeout.** `Io` cancelation stopped a stalled read at exactly the deadline (4,002 ms for a 4 s limit), but not a connect: a blackholed host held its worker for 90 s, until the OS gave up. In the 0.17.1 source, `netConnectIpPosix` panics with a TODO if given a timeout, and `http.Client` ignores its own `timeout` field. This wasted a worker slot but did not fail. `src/fetch.zig` now supplies a non-blocking connect through the `Io` interface, so a deadline holds for these hosts too.
- **A `304` can claim `content-encoding: gzip`.** Reading its empty body fails, so never read a `304` body. This caused the only crash in the run, and it was a spike bug, not a Zig one. `bodyErr()` was also null in that case, so it must not be unwrapped with `.?`.
- **About 10% of servers ignore validators.** Compare the body hash with the last fetch, and skip parsing when it matches.
- **The client speaks HTTP/1.1 only**, which caused no failures.

### 2. SQLite: pass, except relevance search on common terms

Built with `zig build`, FTS5 on, hand-written externs. 1,000,000 synthetic entries of 100 to 400 words in the real schema, Zipf word frequencies. Load: about 3,100 rows per second, 2.9 GB. Latency over repeated queries:

| Query | p50 | p95 | Budget |
|---|---|---|---|
| Timeline page of 50, random depth | 0.55 ms | 1.30 ms | Under 5 ms: met |
| Unread in one feed | 0.09 ms | 0.26 ms | Under 5 ms: met |
| Search, newest first, any term | 0.25 to 0.42 ms | 0.50 ms | Under 20 ms: met |
| Search by relevance, rare term | 2.24 ms | 2.94 ms | Met |
| Search by relevance, mid-frequency term | 21.72 ms | 59.73 ms | **Missed** |
| Search by relevance, very common term | 862 ms | 1,079 ms | **Missed** |

Relevance ranking must score every match, and the common terms here appear in up to 98% of rows, which is close to worst case. Limiting ranking to recent rows helps but does not reach the budget: on that same term, the latest 50,000 rows took 140 ms and the latest 10,000 took 40 ms (single runs). So search defaults to newest first, and relevance is opt-in and limited to a recent window.

Read-only access also has a trap. After a clean shutdown of the last connection, the `-wal` and `-shm` files are gone, and `sqlite3 -readonly` fails with error 14. It works while the daemon runs, and `file:rss.db?immutable=1` works while it does not.

### 3. SwiftUI over a socket: pass

Zig stand-in server, Swift client, newline-delimited JSON-RPC.

| Measure | Result |
|---|---|
| Fetch and decode 10,000 rows, 200 pages | 21 ms total, 0.1 ms per page |
| Scroll a real `List` to row 9,999 at 400 pt per frame | 960 frames at 60 Hz, none over budget, max gap 16.80 ms |
| App peak RSS | 126 MB |

Limits of this test: rows were simple text, scrolling was programmatic rather than by trackpad, and the display ran at 60 Hz. Long article rendering was not tested. It also showed that a bare executable opens no window under the SwiftUI `App` lifecycle, so the real GUI needs a proper app bundle. One `NSTableView` reentrancy warning appeared while rows were being appended, so batch updates in the real app.

### Not tested

Streaming parse speed, the 1,000-feed daemon, idle memory and CPU, and real feed text in FTS5, where word frequencies differ from this synthetic data.

## What would change this decision

- A Linux or Windows GUI becomes a requirement: use a Zig toolkit or GTK for the GUI, or reconsider Rust.
- Stability outranks learning: Rust.
- Zig ships a release that is hard to follow: stay pinned. Nothing forces an upgrade.
