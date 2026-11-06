# 0002: Show remote pages in the app

Status: accepted.

## Context

The content model removes the need for an HTML engine: feed HTML becomes [blocks](../architecture.md#content-model) at ingest, and surfaces render blocks. An article's own page, with its layout, comments and media, is not in the feed. Reading it meant leaving for a browser, and finding the way back.

## Decision

The GUI shows remote pages in place of the reader, with `WKWebView`. Back returns to the article.

The rule about blocks narrows rather than ends. **Feed content still never reaches a web view.** The viewer takes only an `http` or `https` address and loads it, which is what "open in browser" does. It has no path for a string of HTML, so sanitizing stays a property of the block model, and feed text still cannot run script.

## Why WebKit is acceptable

The [boundary](../architecture.md#what-from-scratch-means) leaves OS windowing and text rendering to the OS. A web engine is the same kind of thing: a system framework, linked by the GUI alone, with nothing added to the core. The TUI, CLI and MCP server are unchanged and still have no HTML engine.

## What protects the user

| Risk | Measure |
|---|---|
| A feed chooses the address | `http` and `https` only, checked on every navigation, not only the first |
| A page reaches this Mac or its network | Navigation to a private or local address is refused, and a content rule blocks subresources from those addresses |
| Tracking across visits | Each visit has an in-memory data store, so cookies, caches and logins end with the pane |
| A page reaches our data | No script message handler is installed, so page script has no route to the app or daemon. WebKit runs pages in its own sandboxed process |
| A page opens more surface | New windows open in the pane. Downloads, camera and microphone are refused |

JavaScript stays on, because most sites do not work without it.

## Limits

- The private address check reads the host name. A public name resolving to a private address passes it. The daemon's fetcher checks the connected socket, and WebKit offers no equivalent.
- Private sessions mean paywalled sites appear logged out. Those pages open in a browser with one action.
- The app's scrollbar does not apply inside a page.
- The app allows plain `http` for web content only, since many blogs still use it.

## Alternatives

**Browser only.** The simplest choice, and it stays available through command-click and a setting. It leaves the problem as it was.

**Reader mode through `entries.fetch_full`.** Already built, and safer. It shows article text, not the page, so it complements the viewer rather than replacing it.
