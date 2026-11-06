# How RSS actually works

The background you need before writing the parser. Every section ends with what it means for this project.

## The whole idea

A feed is a file on a web server that lists recent content. There is no push, no account, no protocol beyond HTTP. A reader downloads the file on a timer, compares it with what it saw last time, and shows you what is new.

That simplicity is why it survives, and it has three consequences:

- The publisher does not know you exist, so nobody can deplatform your reader.
- The file only holds the last N items. Anything you did not fetch in time is gone, so **your local copy is the archive**.
- Nothing enforces the formats. A reader's real job is surviving what publishers actually emit.

## Three formats, one concept

| | RSS 2.0 | Atom 1.0 | JSON Feed 1.1 |
|---|---|---|---|
| Spec | [RSS 2.0](https://www.rssboard.org/rss-specification), frozen | [RFC 4287](https://www.rfc-editor.org/rfc/rfc4287) | [jsonfeed.org](https://www.jsonfeed.org/version/1.1/) |
| Container | `<rss><channel>` | `<feed>` | `{ "items": [] }` |
| Item | `<item>` | `<entry>` | item object |
| Identity | `<guid>`, optional | `<id>`, required | `id`, required |
| Date | `<pubDate>`, RFC 822 | `<updated>`, RFC 3339 | `date_published`, RFC 3339 |
| Body | `<description>`, often escaped HTML | `<content type="html\|xhtml\|text">` | `content_html`, `content_text` |
| Media | `<enclosure>` | `<link rel="enclosure">` | `attachments` |

Older variants still exist in the wild: RSS 0.9x, RSS 1.0 (RDF, with a different namespace and `<item>` outside `<channel>`), and Atom 0.3.

Minimal RSS 2.0:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Example</title>
    <link>https://example.com/</link>
    <item>
      <title>Hello</title>
      <link>https://example.com/hello</link>
      <guid isPermaLink="true">https://example.com/hello</guid>
      <pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate>
      <description>Short text</description>
      <content:encoded><![CDATA[<p>Full <b>HTML</b> body</p>]]></content:encoded>
    </item>
  </channel>
</rss>
```

Extensions arrive through XML namespaces. The ones that matter: `content:encoded` (full body), `dc:creator` and `dc:date` (Dublin Core), `media:*` (Media RSS), `itunes:*` (podcasts), `atom:link rel="self"` inside RSS. Match namespaces by URI, never by prefix: the prefix is the publisher's choice.

**For us:** three format front-ends feed one normalized `Entry` type. Everything downstream knows nothing about RSS.

## Being a polite HTTP client

Polling well is most of the difference between a good reader and a bad one.

**Conditional requests** ([RFC 9110](https://www.rfc-editor.org/rfc/rfc9110)). Save the `ETag` and `Last-Modified` response headers and send them back as `If-None-Match` and `If-Modified-Since`. An unchanged feed then answers `304 Not Modified` with no body. Most polls should end there.

| Response | Meaning | What we do |
|---|---|---|
| `200` | New body | Parse it, save the validators |
| `304` | Unchanged | Nothing except rescheduling. Never read a body, even if headers claim `content-encoding: gzip` |
| `301`, `308` | Moved permanently | Update the stored URL |
| `302`, `307` | Moved temporarily | Follow, keep the stored URL |
| `410` | Gone | Stop polling and tell the user |
| `429`, `503` | Slow down | Obey `Retry-After` |
| Other `4xx`, `5xx` | Failure | Exponential backoff, with jitter |

In a test of 178 feeds offering validators, 17 still returned the full body, unchanged. So also compare a hash of the body before parsing.

**Other manners:**

- Send `Accept-Encoding: gzip` and a `User-Agent` that names the project.
- Limit concurrent requests per host, since many feeds share a host.
- Spread polls with jitter so they do not all fire on the hour.
- Respect hints where present: `<ttl>`, `<skipHours>`, `<skipDays>`, `sy:updatePeriod`. `Cache-Control` is not read yet.
- Adapt: a feed that posts monthly does not need hourly polling.

**Push exists but is optional.** [WebSub](https://www.w3.org/TR/websub/) lets a hub call you when a feed changes, but needs a publicly reachable callback. A local-first app has none, so we poll.

**For us:** the fetcher and scheduler are a real state machine, and `fetch_log` records each step.

## Finding the feed

People paste website URLs, not feed URLs. Discovery order:

1. If the URL returns a feed, use it.
2. Parse the HTML for `<link rel="alternate" type="application/rss+xml">` (also `atom+xml`, `feed+json`).
3. Try well-known paths: `/feed`, `/rss`, `/atom.xml`, `/index.xml`.

Subscriptions move between readers as [OPML](https://opml.org/spec2.opml), a small XML outline. Import and export are required from the start, so that adopting this reader never traps your data.

## What goes wrong in practice

These are why the parser needs a corpus of real feeds, not just the specs.

- **Bad XML:** unescaped `&`, undeclared namespaces, HTML entities such as `&nbsp;` that XML does not define, junk before the `<?xml` line, a byte order mark.
- **Wrong encoding:** declared UTF-8 but actually Windows-1252, or a conflict between the HTTP header and the XML declaration.
- **Bad dates:** `Fri, 6 Nov 2026 9:30 PST`, localized month names, no timezone, no date at all, dates in the future.
- **Double escaping:** `&amp;lt;p&amp;gt;` in a body, so tags show up as text.
- **Relative links** in bodies, which need `xml:base` or the feed URL to resolve.
- **Unstable identity:** GUIDs that change on every build, which makes every old post look new.
- **Summary-only feeds** where the body is one sentence.

Found in a corpus of 756 real feeds while building the parser:

- **Broken CDATA:** a generator wrote `]]</description>`, dropping the `>`. A strict reading swallows every later entry.
- **Placeholder dates:** `Mon, 01 Jan 0001 00:00:00 +0000`, the .NET empty date, in 26 feeds. Treated as no date.
- **JavaScript date strings:** `Mon Sep 28 2026 00:00:00 GMT+0000 (Coordinated Universal Time)`.
- **Year-only dates:** `2026`, which stay unread rather than becoming a guess.
- **Trailing `&nbsp;`** on titles.
- **Shared links:** different posts all pointing at `/undefined/`, a template bug.
- **HTML served as a feed:** 4 of 756 URLs returned a web page with status `200`.
- **No link at all:** one podcast feed had 1,100 episodes with no `<link>`, only an enclosure.

**For us:** the XML layer is lenient and recovers instead of aborting, but it is also hostile-input hardened. Those are separate requirements.

## Entry identity

This decides whether a user sees duplicates, so it gets its own rule. `entries.identity` takes the first available of:

1. `guid`, Atom `id`, or JSON Feed `id`
2. `link`, after URL normalization
3. A hash of title plus published date
4. A hash of the content

Identity is scoped per feed, because different feeds may reuse a value. If one fetch contains the same identity with different titles, those are different posts behind a broken generator, so every one of them gets a hash of its title appended. Without this, the unique constraint would merge them. In the corpus, 43 posts across 4 feeds would have been lost. The known cost: if only one such post remains in a later fetch, it loses its suffix and appears once more as new. A repeat is preferred to a lost post.
 An identical identity with a changed `content_hash` is an edit, not a new entry: bump `revision`, keep read state.

**Dates are claims, not facts.** Keep `published_at` as stated, always record `first_seen_at`, and sort by `sort_at`, the earlier of the two. This means a publisher cannot pin a post to the top with a future date.

## Reading list

- [RSS 2.0 specification](https://www.rssboard.org/rss-specification)
- [RSS Best Practices Profile](https://www.rssboard.org/rss-profile), which documents real-world behavior
- [RFC 4287: Atom](https://www.rfc-editor.org/rfc/rfc4287)
- [JSON Feed 1.1](https://www.jsonfeed.org/version/1.1/)
- [RFC 5005: Feed Paging and Archiving](https://www.rfc-editor.org/rfc/rfc5005), for backfilling history
