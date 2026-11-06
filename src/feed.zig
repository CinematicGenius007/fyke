//! Turns feed bytes into one normalized `Feed`, whatever the source format.
//! Everything downstream of this file knows nothing about RSS or Atom.
//!
//! All results live in the caller's arena and may slice the input, so the input
//! must outlive them. Bodies are kept as HTML here; the `html` module turns them
//! into blocks later.

const std = @import("std");
const dates = @import("dates.zig");
const encoding = @import("encoding.zig");
const xml = @import("xml.zig");

/// Entries past this count are ignored. Matches no real feed.
pub const max_entries = 10_000;

pub const Error = error{ OutOfMemory, NotAFeed, UnsupportedEncoding, TooDeep };

/// Values match the `feeds.format` column.
pub const Format = enum { rss090, rss091, rss10, rss20, atom03, atom10, json10, json11 };

pub const Body = struct {
    value: []const u8,
    kind: enum { html, text },
};

pub const Enclosure = struct {
    url: []const u8,
    mime_type: ?[]const u8 = null,
    bytes: ?u64 = null,
};

pub const Entry = struct {
    /// The publisher's identifier for this entry, if any. See `identity`.
    guid: ?[]const u8 = null,
    url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    published_at: ?i64 = null,
    updated_at: ?i64 = null,
    summary: ?Body = null,
    content: ?Body = null,
    /// Base for resolving relative links in this entry, from xml:base.
    base: ?[]const u8 = null,
    enclosures: []const Enclosure = &.{},
    categories: []const []const u8 = &.{},
};

pub const Feed = struct {
    format: Format,
    title: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    /// The feed's own stated URL.
    self_url: ?[]const u8 = null,
    description: ?[]const u8 = null,
    language: ?[]const u8 = null,
    author: ?[]const u8 = null,
    base: ?[]const u8 = null,
    /// Publisher's polling hint, from <ttl> or the syndication module.
    poll_seconds_hint: ?u32 = null,
    entries: []const Entry = &.{},
    /// Date strings that could not be read, kept for diagnostics.
    unparsed_dates: u32 = 0,
    sample_unparsed_date: ?[]const u8 = null,
};

pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Error!Feed {
    const text = try encoding.toUtf8(arena, bytes);
    const start = std.mem.indexOfNone(u8, text, " \t\r\n") orelse return error.NotAFeed;
    if (text[start] == '{') return parseJson(arena, text);
    return parseXml(arena, text);
}

/// The stable identity of an entry within its feed. See docs/rss-primer.md.
pub fn identity(arena: std.mem.Allocator, entry: Entry) error{OutOfMemory}![]const u8 {
    if (entry.guid) |guid| return guid;
    if (entry.url) |url| return url;

    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    if (entry.title != null) {
        hash.update(entry.title.?);
        if (entry.published_at) |at| hash.update(std.mem.asBytes(&at));
    } else {
        if (entry.content) |body| hash.update(body.value);
        if (entry.summary) |body| hash.update(body.value);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(arena, "sha256:{s}", .{digest});
}

/// Identities for every entry of one parsed feed, in order.
///
/// Broken generators give different posts the same link or guid, for instance
/// ".../undefined/". Left alone, a unique identity column would silently merge
/// those posts. So when an identity repeats with a different title, every member
/// of that group gets the title's hash added. True repeats stay merged.
pub fn identities(arena: std.mem.Allocator, entries: []const Entry) error{OutOfMemory}![]const []const u8 {
    const ids = try arena.alloc([]const u8, entries.len);
    const Seen = struct { title: []const u8, conflict: bool };
    var seen: std.StringHashMapUnmanaged(Seen) = .empty;
    for (entries, ids) |entry, *id| {
        id.* = try identity(arena, entry);
        const title = entry.title orelse "";
        const slot = try seen.getOrPut(arena, id.*);
        if (!slot.found_existing) {
            slot.value_ptr.* = .{ .title = title, .conflict = false };
        } else if (!std.mem.eql(u8, slot.value_ptr.title, title)) {
            slot.value_ptr.conflict = true;
        }
    }
    for (entries, ids) |entry, *id| {
        if (!seen.get(id.*).?.conflict) continue;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.title orelse "", &digest, .{});
        id.* = try std.fmt.allocPrint(arena, "{s}#{s}", .{ id.*, std.fmt.bytesToHex(digest[0..8].*, .lower) });
    }
    return ids;
}

const Ns = enum { core, rss090, rss10, atom, atom03, content, dc, media, itunes, syndication, other };

/// Matches by URI, since prefixes are the publisher's choice. A known prefix with
/// no declaration falls back to its usual meaning, which is common in the wild.
fn namespaceOf(name: xml.Name) Ns {
    if (name.uri.len == 0) {
        if (name.prefix.len == 0) return .core;
        const prefixes = [_]struct { []const u8, Ns }{
            .{ "content", .content }, .{ "dc", .dc },     .{ "media", .media },
            .{ "itunes", .itunes },   .{ "atom", .atom }, .{ "sy", .syndication },
        };
        for (prefixes) |entry| {
            if (std.ascii.eqlIgnoreCase(name.prefix, entry[0])) return entry[1];
        }
        return .other;
    }
    var uri = std.mem.trimEnd(u8, name.uri, "/");
    if (std.mem.startsWith(u8, uri, "https://")) uri = uri["https://".len..];
    if (std.mem.startsWith(u8, uri, "http://")) uri = uri["http://".len..];
    const uris = [_]struct { []const u8, Ns }{
        .{ "www.w3.org/2005/Atom", .atom },
        .{ "purl.org/atom/ns#", .atom03 },
        .{ "purl.org/rss/1.0", .rss10 },
        .{ "my.netscape.com/rdf/simple/0.9", .rss090 },
        .{ "purl.org/rss/1.0/modules/content", .content },
        .{ "purl.org/dc/elements/1.1", .dc },
        .{ "search.yahoo.com/mrss", .media },
        .{ "www.itunes.com/dtds/podcast-1.0.dtd", .itunes },
        .{ "purl.org/rss/1.0/modules/syndication", .syndication },
        .{ "backend.userland.com/rss2", .core },
    };
    for (uris) |entry| {
        if (std.ascii.eqlIgnoreCase(uri, entry[0])) return entry[1];
    }
    return .other;
}

fn isRssCore(ns: Ns) bool {
    return ns == .core or ns == .rss10 or ns == .rss090;
}

fn isAtom(ns: Ns) bool {
    return ns == .atom or ns == .atom03 or ns == .core;
}

fn is(name: xml.Name, local: []const u8) bool {
    return std.mem.eql(u8, name.local, local);
}

/// Reads the element whose start event was just returned. Plain text and CDATA
/// are concatenated and decoded. If it contains child elements, as in unescaped
/// inline HTML, the raw inner markup is returned instead.
fn readText(arena: std.mem.Allocator, p: *xml.Parser) Error![]const u8 {
    const inner_start = p.pos;
    const target = p.depth - 1;
    var first: ?[]const u8 = null;
    var joined: std.ArrayList(u8) = .empty;
    var has_children = false;
    while (true) {
        const chunk = switch (try p.next()) {
            .eof => break,
            .end => {
                if (p.depth == target) break;
                continue;
            },
            .start => {
                has_children = true;
                continue;
            },
            .text => |raw| try xml.decodeText(arena, raw),
            .cdata => |raw| raw,
        };
        if (has_children) continue;
        if (first == null) {
            first = chunk;
        } else {
            if (joined.items.len == 0) try joined.appendSlice(arena, first.?);
            try joined.appendSlice(arena, chunk);
        }
    }
    if (has_children) return trim(p.input[inner_start..@max(inner_start, p.token_start)]);
    return trim(if (joined.items.len != 0) joined.items else first orelse "");
}

/// Trims whitespace, including the no-break spaces left by "&nbsp;" in titles.
fn trim(text: []const u8) []const u8 {
    var result = std.mem.trim(u8, text, " \t\r\n");
    const nbsp = "\xC2\xA0";
    while (true) {
        if (std.mem.endsWith(u8, result, nbsp)) {
            result = std.mem.trimEnd(u8, result[0 .. result.len - nbsp.len], " \t\r\n");
        } else if (std.mem.startsWith(u8, result, nbsp)) {
            result = std.mem.trimStart(u8, result[nbsp.len..], " \t\r\n");
        } else return result;
    }
}

/// Stores `text` in an empty field. Earlier values win, and blanks never count.
fn setFirst(field: *?[]const u8, text: []const u8) void {
    if (field.* == null and text.len != 0) field.* = text;
}

fn attr(arena: std.mem.Allocator, start: xml.Start, name: []const u8) error{OutOfMemory}!?[]const u8 {
    const raw = start.attribute(name) orelse return null;
    const value = trim(try xml.decodeText(arena, raw));
    return if (value.len == 0) null else value;
}

const Dates = struct {
    feed: *Feed,

    fn read(d: Dates, text: []const u8) ?i64 {
        if (text.len == 0) return null;
        if (dates.parse(text)) |value| return value;
        d.feed.unparsed_dates += 1;
        if (d.feed.sample_unparsed_date == null) d.feed.sample_unparsed_date = text;
        return null;
    }
};

const EntryLists = struct {
    enclosures: std.ArrayList(Enclosure) = .empty,
    categories: std.ArrayList([]const u8) = .empty,

    fn finish(lists: EntryLists, entry: *Entry) void {
        entry.enclosures = lists.enclosures.items;
        entry.categories = lists.categories.items;
    }
};

fn parseXml(arena: std.mem.Allocator, text: []const u8) Error!Feed {
    var p: xml.Parser = .init(text);
    while (true) {
        switch (try p.next()) {
            .eof => return error.NotAFeed,
            .start => |root| {
                const local = root.name.local;
                if (std.ascii.eqlIgnoreCase(local, "rss") or std.ascii.eqlIgnoreCase(local, "channel")) {
                    return parseRss(arena, &p, rssVersion(root));
                }
                if (std.ascii.eqlIgnoreCase(local, "rdf")) {
                    const default_ns = root.attribute("xmlns") orelse "";
                    const old = std.mem.indexOf(u8, default_ns, "my.netscape.com") != null;
                    return parseRss(arena, &p, if (old) .rss090 else .rss10);
                }
                if (std.ascii.eqlIgnoreCase(local, "feed")) {
                    const old = namespaceOf(root.name) == .atom03 or
                        std.mem.eql(u8, root.attribute("version") orelse "", "0.3");
                    return parseAtom(arena, &p, root, if (old) .atom03 else .atom10);
                }
                return error.NotAFeed;
            },
            else => {},
        }
    }
}

fn rssVersion(root: xml.Start) Format {
    const version = root.attribute("version") orelse return .rss20;
    if (std.mem.startsWith(u8, version, "0.90")) return .rss090;
    if (std.mem.startsWith(u8, version, "0.9")) return .rss091;
    return .rss20;
}

fn parseRss(arena: std.mem.Allocator, p: *xml.Parser, format: Format) Error!Feed {
    var feed: Feed = .{ .format = format };
    var entries: std.ArrayList(Entry) = .empty;
    var update_period: ?[]const u8 = null;
    var update_frequency: ?[]const u8 = null;

    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event != .start) continue;
        const start = event.start;
        const name = start.name;
        const ns = namespaceOf(name);

        if (isRssCore(ns)) {
            if (is(name, "channel")) continue; // Its children are read by this same loop.
            if (is(name, "item")) {
                const entry = try parseRssItem(arena, p, .{ .feed = &feed });
                if (entries.items.len < max_entries) try entries.append(arena, entry);
            } else if (is(name, "title")) {
                setFirst(&feed.title, try readText(arena, p));
            } else if (is(name, "link")) {
                setFirst(&feed.site_url, try readText(arena, p));
            } else if (is(name, "description")) {
                setFirst(&feed.description, try readText(arena, p));
            } else if (is(name, "language")) {
                setFirst(&feed.language, try readText(arena, p));
            } else if (is(name, "ttl")) {
                const minutes = std.fmt.parseInt(u32, try readText(arena, p), 10) catch 0;
                if (minutes != 0) feed.poll_seconds_hint = minutes *| 60;
            } else {
                // Includes <image> and <textinput>, whose own <title> and <link>
                // must not be mistaken for the feed's.
                _ = try p.skipElement();
            }
        } else if (ns == .atom and is(name, "link")) {
            if (std.mem.eql(u8, start.attribute("rel") orelse "", "self")) {
                if (try attr(arena, start, "href")) |href| setFirst(&feed.self_url, href);
            }
            _ = try p.skipElement();
        } else if (ns == .syndication and is(name, "updatePeriod")) {
            update_period = try readText(arena, p);
        } else if (ns == .syndication and is(name, "updateFrequency")) {
            update_frequency = try readText(arena, p);
        } else if (ns == .dc and is(name, "language")) {
            setFirst(&feed.language, try readText(arena, p));
        } else {
            _ = try p.skipElement();
        }
    }

    if (feed.poll_seconds_hint == null) {
        if (update_period) |period| feed.poll_seconds_hint = syndicationSeconds(period, update_frequency);
    }
    feed.entries = entries.items;
    return feed;
}

fn syndicationSeconds(period: []const u8, frequency: ?[]const u8) ?u32 {
    const seconds: u32 = if (std.mem.eql(u8, period, "hourly"))
        3600
    else if (std.mem.eql(u8, period, "daily"))
        86400
    else if (std.mem.eql(u8, period, "weekly"))
        604800
    else if (std.mem.eql(u8, period, "monthly"))
        2592000
    else if (std.mem.eql(u8, period, "yearly"))
        31536000
    else
        return null;
    const times = std.fmt.parseInt(u32, frequency orelse "1", 10) catch 1;
    return if (times == 0) seconds else seconds / times;
}

fn parseRssItem(arena: std.mem.Allocator, p: *xml.Parser, d: Dates) Error!Entry {
    var entry: Entry = .{};
    var lists: EntryLists = .{};
    var permalink_guid = true;
    var summary_fallback: ?[]const u8 = null;
    var author_fallback: ?[]const u8 = null;
    const target = p.depth - 1;

    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event == .end) {
            if (p.depth == target) break;
            continue;
        }
        if (event != .start) continue;
        const start = event.start;
        const name = start.name;
        const ns = namespaceOf(name);

        if (isRssCore(ns)) {
            if (is(name, "title")) {
                setFirst(&entry.title, try readText(arena, p));
            } else if (is(name, "link")) {
                setFirst(&entry.url, try readText(arena, p));
            } else if (is(name, "guid")) {
                const is_permalink = start.attribute("isPermaLink") orelse "true";
                permalink_guid = !std.ascii.eqlIgnoreCase(is_permalink, "false");
                setFirst(&entry.guid, try readText(arena, p));
            } else if (is(name, "pubDate")) {
                if (entry.published_at == null) entry.published_at = d.read(try readText(arena, p)) else _ = try p.skipElement();
            } else if (is(name, "description")) {
                const value = try readText(arena, p);
                if (entry.summary == null and value.len != 0) entry.summary = .{ .value = value, .kind = .html };
            } else if (is(name, "author")) {
                setFirst(&entry.author, try readText(arena, p));
            } else if (is(name, "category")) {
                const value = try readText(arena, p);
                if (value.len != 0) try lists.categories.append(arena, value);
            } else if (is(name, "enclosure")) {
                if (try attr(arena, start, "url")) |url| {
                    try lists.enclosures.append(arena, .{
                        .url = url,
                        .mime_type = try attr(arena, start, "type"),
                        .bytes = parseBytes(start.attribute("length")),
                    });
                }
                _ = try p.skipElement();
            } else {
                _ = try p.skipElement();
            }
        } else if (ns == .content and is(name, "encoded")) {
            const value = try readText(arena, p);
            if (entry.content == null and value.len != 0) entry.content = .{ .value = value, .kind = .html };
        } else if (ns == .dc and is(name, "creator")) {
            setFirst(&entry.author, try readText(arena, p));
        } else if (ns == .dc and is(name, "date")) {
            if (entry.published_at == null) entry.published_at = d.read(try readText(arena, p)) else _ = try p.skipElement();
        } else if (ns == .dc and is(name, "subject")) {
            const value = try readText(arena, p);
            if (value.len != 0) try lists.categories.append(arena, value);
        } else if (ns == .atom and is(name, "link")) {
            const rel = start.attribute("rel") orelse "alternate";
            if (std.mem.eql(u8, rel, "alternate")) {
                if (try attr(arena, start, "href")) |href| setFirst(&entry.url, href);
            }
            _ = try p.skipElement();
        } else if (ns == .atom and is(name, "updated")) {
            entry.updated_at = d.read(try readText(arena, p));
        } else if (ns == .media and is(name, "group")) {
            continue; // Its <media:content> children are read by this same loop.
        } else if (ns == .media and is(name, "content")) {
            if (try attr(arena, start, "url")) |url| {
                try lists.enclosures.append(arena, .{
                    .url = url,
                    .mime_type = try attr(arena, start, "type"),
                    .bytes = parseBytes(start.attribute("fileSize")),
                });
            }
            _ = try p.skipElement();
        } else if (ns == .itunes and is(name, "summary")) {
            summary_fallback = try readText(arena, p);
        } else if (ns == .itunes and is(name, "author")) {
            author_fallback = try readText(arena, p);
        } else {
            _ = try p.skipElement();
        }
    }

    if (entry.url == null and permalink_guid) entry.url = entry.guid;
    if (entry.summary == null) {
        if (summary_fallback) |value| {
            if (value.len != 0) entry.summary = .{ .value = value, .kind = .text };
        }
    }
    if (author_fallback) |value| setFirst(&entry.author, value);
    lists.finish(&entry);
    return entry;
}

fn parseBytes(text: ?[]const u8) ?u64 {
    const value = std.fmt.parseInt(u64, trim(text orelse return null), 10) catch return null;
    return if (value == 0) null else value;
}

fn parseAtom(arena: std.mem.Allocator, p: *xml.Parser, root: xml.Start, format: Format) Error!Feed {
    var feed: Feed = .{ .format = format, .base = try attr(arena, root, "xml:base"), .language = try attr(arena, root, "xml:lang") };
    var entries: std.ArrayList(Entry) = .empty;

    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event != .start) continue;
        const start = event.start;
        const name = start.name;

        if (!isAtom(namespaceOf(name))) {
            _ = try p.skipElement();
        } else if (is(name, "entry")) {
            const entry = try parseAtomEntry(arena, p, start, .{ .feed = &feed });
            if (entries.items.len < max_entries) try entries.append(arena, entry);
        } else if (is(name, "title")) {
            setFirst(&feed.title, try readText(arena, p));
        } else if (is(name, "subtitle") or is(name, "tagline")) {
            setFirst(&feed.description, try readText(arena, p));
        } else if (is(name, "author")) {
            setFirst(&feed.author, try readAtomPerson(arena, p));
        } else if (is(name, "link")) {
            const rel = start.attribute("rel") orelse "alternate";
            if (try attr(arena, start, "href")) |href| {
                if (std.mem.eql(u8, rel, "alternate")) setFirst(&feed.site_url, href);
                if (std.mem.eql(u8, rel, "self")) setFirst(&feed.self_url, href);
            }
            _ = try p.skipElement();
        } else {
            _ = try p.skipElement();
        }
    }

    const items = entries.items;
    if (feed.author) |author| {
        for (items) |*entry| {
            if (entry.author == null) entry.author = author;
        }
    }
    feed.entries = items;
    return feed;
}

/// Reads an Atom text construct, whose `type` says how to read it. Atom 0.3 used
/// `mode="escaped"` for the same purpose.
fn readAtomBody(arena: std.mem.Allocator, p: *xml.Parser, start: xml.Start) Error!?Body {
    const kind = start.attribute("type") orelse "text";
    const is_html = std.mem.indexOf(u8, kind, "html") != null or
        std.mem.eql(u8, start.attribute("mode") orelse "", "escaped");
    const value = try readText(arena, p);
    if (value.len == 0) return null;
    return .{ .value = value, .kind = if (is_html) .html else .text };
}

fn parseAtomEntry(arena: std.mem.Allocator, p: *xml.Parser, entry_start: xml.Start, d: Dates) Error!Entry {
    var entry: Entry = .{ .base = try attr(arena, entry_start, "xml:base") };
    var lists: EntryLists = .{};
    const target = p.depth - 1;

    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event == .end) {
            if (p.depth == target) break;
            continue;
        }
        if (event != .start) continue;
        const start = event.start;
        const name = start.name;

        if (!isAtom(namespaceOf(name))) {
            _ = try p.skipElement();
        } else if (is(name, "id")) {
            setFirst(&entry.guid, try readText(arena, p));
        } else if (is(name, "title")) {
            // A title of type "html" is escaped twice: once for XML, once for HTML.
            const is_html = std.mem.indexOf(u8, start.attribute("type") orelse "", "html") != null;
            const value = try readText(arena, p);
            setFirst(&entry.title, if (is_html) try xml.decodeText(arena, value) else value);
        } else if (is(name, "link")) {
            const rel = start.attribute("rel") orelse "alternate";
            if (try attr(arena, start, "href")) |href| {
                if (std.mem.eql(u8, rel, "alternate")) {
                    setFirst(&entry.url, href);
                } else if (std.mem.eql(u8, rel, "enclosure")) {
                    try lists.enclosures.append(arena, .{
                        .url = href,
                        .mime_type = try attr(arena, start, "type"),
                        .bytes = parseBytes(start.attribute("length")),
                    });
                }
            }
            _ = try p.skipElement();
        } else if (is(name, "published") or is(name, "issued") or is(name, "created")) {
            const value = d.read(try readText(arena, p));
            if (entry.published_at == null) entry.published_at = value;
        } else if (is(name, "updated") or is(name, "modified")) {
            const value = d.read(try readText(arena, p));
            if (entry.updated_at == null) entry.updated_at = value;
        } else if (is(name, "summary")) {
            if (try readAtomBody(arena, p, start)) |body| {
                if (entry.summary == null) entry.summary = body;
            }
        } else if (is(name, "content")) {
            if (try readAtomBody(arena, p, start)) |body| {
                if (entry.content == null) entry.content = body;
            }
        } else if (is(name, "author")) {
            setFirst(&entry.author, try readAtomPerson(arena, p));
        } else if (is(name, "category")) {
            if (try attr(arena, start, "term")) |term| try lists.categories.append(arena, term);
            _ = try p.skipElement();
        } else {
            // Includes <source>, whose <title> and <id> describe another feed.
            _ = try p.skipElement();
        }
    }
    lists.finish(&entry);
    return entry;
}

fn readAtomPerson(arena: std.mem.Allocator, p: *xml.Parser) Error![]const u8 {
    const target = p.depth - 1;
    var person: ?[]const u8 = null;
    while (true) {
        const event = try p.next();
        if (event == .eof) break;
        if (event == .end and p.depth == target) break;
        if (event != .start) continue;
        if (is(event.start.name, "name")) {
            setFirst(&person, try readText(arena, p));
        } else {
            _ = try p.skipElement();
        }
    }
    return person orelse "";
}

fn parseJson(arena: std.mem.Allocator, text: []const u8) Error!Feed {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NotAFeed,
    };
    if (root != .object) return error.NotAFeed;
    const version = string(root, "version") orelse return error.NotAFeed;
    if (std.mem.indexOf(u8, version, "jsonfeed.org/version/") == null) return error.NotAFeed;

    var feed: Feed = .{
        .format = if (std.mem.endsWith(u8, version, "/1")) .json10 else .json11,
        .title = string(root, "title"),
        .site_url = string(root, "home_page_url"),
        .self_url = string(root, "feed_url"),
        .description = string(root, "description"),
        .language = string(root, "language"),
        .author = jsonAuthor(root),
    };

    const items = root.object.get("items") orelse return feed;
    if (items != .array) return feed;
    const d: Dates = .{ .feed = &feed };
    var entries: std.ArrayList(Entry) = .empty;
    for (items.array.items[0..@min(items.array.items.len, max_entries)]) |item| {
        if (item != .object) continue;
        try entries.append(arena, try parseJsonItem(arena, item, d));
    }
    feed.entries = entries.items;
    return feed;
}

fn parseJsonItem(arena: std.mem.Allocator, item: std.json.Value, d: Dates) Error!Entry {
    var entry: Entry = .{
        .guid = try jsonId(arena, item),
        .url = string(item, "url") orelse string(item, "external_url"),
        .title = string(item, "title"),
        .author = jsonAuthor(item) orelse d.feed.author,
        .published_at = d.read(string(item, "date_published") orelse ""),
        .updated_at = d.read(string(item, "date_modified") orelse ""),
    };
    if (string(item, "content_html")) |value| {
        entry.content = .{ .value = value, .kind = .html };
    } else if (string(item, "content_text")) |value| {
        entry.content = .{ .value = value, .kind = .text };
    }
    if (string(item, "summary")) |value| entry.summary = .{ .value = value, .kind = .text };

    var lists: EntryLists = .{};
    if (item.object.get("tags")) |tags| {
        if (tags == .array) {
            for (tags.array.items) |tag| {
                if (tag == .string) try lists.categories.append(arena, tag.string);
            }
        }
    }
    if (item.object.get("attachments")) |attachments| {
        if (attachments == .array) {
            for (attachments.array.items) |attachment| {
                if (attachment != .object) continue;
                const url = string(attachment, "url") orelse continue;
                const size = attachment.object.get("size_in_bytes");
                try lists.enclosures.append(arena, .{
                    .url = url,
                    .mime_type = string(attachment, "mime_type"),
                    .bytes = if (size != null and size.? == .integer and size.?.integer > 0) @intCast(size.?.integer) else null,
                });
            }
        }
    }
    lists.finish(&entry);
    return entry;
}

fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = value.object.get(key) orelse return null;
    if (field != .string) return null;
    const text = trim(field.string);
    return if (text.len == 0) null else text;
}

/// The spec says `id` is a string, but numbers are common.
fn jsonId(arena: std.mem.Allocator, item: std.json.Value) error{OutOfMemory}!?[]const u8 {
    const id = item.object.get("id") orelse return null;
    return switch (id) {
        .string => |text| if (trim(text).len == 0) null else trim(text),
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        else => null,
    };
}

/// `authors` is JSON Feed 1.1, `author` is 1.0.
fn jsonAuthor(value: std.json.Value) ?[]const u8 {
    if (value.object.get("authors")) |authors| {
        if (authors == .array and authors.array.items.len != 0 and authors.array.items[0] == .object) {
            if (string(authors.array.items[0], "name")) |name| return name;
        }
    }
    const author = value.object.get("author") orelse return null;
    return if (author == .object) string(author, "name") else null;
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .arena = .init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }
    fn parse(f: *Fixture, text: []const u8) !Feed {
        return @import("feed.zig").parse(f.arena.allocator(), text);
    }
};

test "RSS 2.0" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"
        \\     xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
        \\  <channel>
        \\    <title>Example &amp; Co</title>
        \\    <link>https://example.com/</link>
        \\    <description>News</description>
        \\    <language>en</language>
        \\    <ttl>60</ttl>
        \\    <atom:link rel="self" href="https://example.com/feed.xml"/>
        \\    <image><title>Wrong</title><link>https://wrong.example/</link></image>
        \\    <item>
        \\      <title>Hello</title>
        \\      <link>https://example.com/hello</link>
        \\      <guid isPermaLink="false">post-1</guid>
        \\      <pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate>
        \\      <dc:creator>Sam</dc:creator>
        \\      <description>Short</description>
        \\      <content:encoded><![CDATA[<p>Full <b>body</b></p>]]></content:encoded>
        \\      <category>news</category>
        \\      <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="123"/>
        \\    </item>
        \\  </channel>
        \\</rss>
    );
    try testing.expectEqual(Format.rss20, feed.format);
    try testing.expectEqualStrings("Example & Co", feed.title.?);
    try testing.expectEqualStrings("https://example.com/", feed.site_url.?);
    try testing.expectEqualStrings("https://example.com/feed.xml", feed.self_url.?);
    try testing.expectEqual(3600, feed.poll_seconds_hint.?);
    try testing.expectEqual(1, feed.entries.len);
    const entry = feed.entries[0];
    try testing.expectEqualStrings("Hello", entry.title.?);
    try testing.expectEqualStrings("post-1", entry.guid.?);
    try testing.expectEqualStrings("https://example.com/hello", entry.url.?);
    try testing.expectEqualStrings("Sam", entry.author.?);
    try testing.expectEqual(1793957400000, entry.published_at.?);
    try testing.expectEqualStrings("Short", entry.summary.?.value);
    try testing.expectEqualStrings("<p>Full <b>body</b></p>", entry.content.?.value);
    try testing.expectEqualStrings("news", entry.categories[0]);
    try testing.expectEqual(123, entry.enclosures[0].bytes.?);
}

test "RSS 1.0 keeps items outside the channel" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
        \\  <channel><title>Old</title><link>https://example.com/</link></channel>
        \\  <item><title>One</title><link>https://example.com/1</link></item>
        \\</rdf:RDF>
    );
    try testing.expectEqual(Format.rss10, feed.format);
    try testing.expectEqualStrings("Old", feed.title.?);
    try testing.expectEqualStrings("One", feed.entries[0].title.?);
}

test "a permalink guid stands in for a missing link" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse("<rss><channel><item><guid>https://example.com/1</guid></item></channel></rss>");
    try testing.expectEqualStrings("https://example.com/1", feed.entries[0].url.?);
}

test "undeclared prefixes keep their usual meaning" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse("<rss><channel><item><content:encoded>body</content:encoded></item></channel></rss>");
    try testing.expectEqualStrings("body", feed.entries[0].content.?.value);
}

test "namespaces match by URI, not prefix" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\<rss xmlns:x="http://purl.org/rss/1.0/modules/content/"><channel><item><x:encoded>body</x:encoded></item></channel></rss>
    );
    try testing.expectEqualStrings("body", feed.entries[0].content.?.value);
}

test "unescaped HTML in a description stays as markup" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse("<rss><channel><item><description><p>Hi <b>there</b></p></description></item></channel></rss>");
    try testing.expectEqualStrings("<p>Hi <b>there</b></p>", feed.entries[0].summary.?.value);
}

test "no-break spaces are trimmed" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse("<rss><channel><item><title>&nbsp; A&nbsp;B &#160;</title></item></channel></rss>");
    try testing.expectEqualStrings("A\xC2\xA0B", feed.entries[0].title.?);
}

test "broken XML still yields entries" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\<rss version="2.0"><channel><title>AT&T &nbsp;News</title>
        \\<item><title>One</title></item>
        \\<item><title>Two
    );
    try testing.expectEqualStrings("AT&T \xC2\xA0News", feed.title.?);
    try testing.expectEqual(2, feed.entries.len);
    try testing.expectEqualStrings("Two", feed.entries[1].title.?);
}

test "Atom 1.0" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\<feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en" xml:base="https://example.com/">
        \\  <title>Blog</title>
        \\  <subtitle>Notes</subtitle>
        \\  <link rel="self" href="https://example.com/atom.xml"/>
        \\  <link href="https://example.com/"/>
        \\  <author><name>Sam</name></author>
        \\  <entry>
        \\    <id>urn:1</id>
        \\    <title type="html">A &amp;amp; B</title>
        \\    <link rel="alternate" href="https://example.com/1"/>
        \\    <link rel="enclosure" href="https://example.com/a.mp3" length="9"/>
        \\    <published>2026-11-06T09:30:00Z</published>
        \\    <updated>2026-11-06T10:30:00Z</updated>
        \\    <summary>Short</summary>
        \\    <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Body</p></div></content>
        \\    <category term="zig"/>
        \\    <source><title>Other</title><id>urn:other</id></source>
        \\  </entry>
        \\</feed>
    );
    try testing.expectEqual(Format.atom10, feed.format);
    try testing.expectEqualStrings("Blog", feed.title.?);
    try testing.expectEqualStrings("Notes", feed.description.?);
    try testing.expectEqualStrings("en", feed.language.?);
    try testing.expectEqualStrings("https://example.com/", feed.site_url.?);
    const entry = feed.entries[0];
    try testing.expectEqualStrings("urn:1", entry.guid.?);
    try testing.expectEqualStrings("A & B", entry.title.?);
    try testing.expectEqualStrings("https://example.com/1", entry.url.?);
    try testing.expectEqualStrings("Sam", entry.author.?);
    try testing.expectEqual(1793957400000, entry.published_at.?);
    try testing.expectEqual(1793957400000 + 3600000, entry.updated_at.?);
    try testing.expectEqualStrings("<div xmlns=\"http://www.w3.org/1999/xhtml\"><p>Body</p></div>", entry.content.?.value);
    try testing.expectEqualStrings("zig", entry.categories[0]);
    try testing.expectEqual(9, entry.enclosures[0].bytes.?);
}

test "JSON Feed" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse(
        \\{ "version": "https://jsonfeed.org/version/1.1", "title": "J", "home_page_url": "https://example.com/",
        \\  "authors": [{"name": "Sam"}],
        \\  "items": [
        \\    { "id": 7, "url": "https://example.com/7", "title": "T", "content_html": "<p>x</p>",
        \\      "date_published": "2026-11-06T09:30:00Z", "tags": ["a"],
        \\      "attachments": [{"url": "https://example.com/a.mp3", "mime_type": "audio/mpeg", "size_in_bytes": 5}] },
        \\    "not an object"
        \\  ] }
    );
    try testing.expectEqual(Format.json11, feed.format);
    try testing.expectEqual(1, feed.entries.len);
    const entry = feed.entries[0];
    try testing.expectEqualStrings("7", entry.guid.?);
    try testing.expectEqualStrings("Sam", entry.author.?);
    try testing.expectEqualStrings("<p>x</p>", entry.content.?.value);
    try testing.expectEqual(1793957400000, entry.published_at.?);
    try testing.expectEqual(5, entry.enclosures[0].bytes.?);
}

test "other documents are not feeds" {
    var f: Fixture = .init();
    defer f.deinit();
    try testing.expectError(error.NotAFeed, f.parse("<!DOCTYPE html><html><body>hi</body></html>"));
    try testing.expectError(error.NotAFeed, f.parse("{\"a\":1}"));
    try testing.expectError(error.NotAFeed, f.parse("   "));
    try testing.expectError(error.NotAFeed, f.parse(""));
}

test "unreadable dates are counted, not dropped silently" {
    var f: Fixture = .init();
    defer f.deinit();
    const feed = try f.parse("<rss><channel><item><pubDate>sometime</pubDate></item></channel></rss>");
    try testing.expectEqual(null, feed.entries[0].published_at);
    try testing.expectEqual(1, feed.unparsed_dates);
    try testing.expectEqualStrings("sometime", feed.sample_unparsed_date.?);
}

test "different posts sharing an identity stay separate" {
    var f: Fixture = .init();
    defer f.deinit();
    const ids = try identities(f.arena.allocator(), &.{
        .{ .url = "https://example.com/undefined/", .title = "One" },
        .{ .url = "https://example.com/undefined/", .title = "Two" },
        .{ .url = "https://example.com/ok", .title = "Three" },
        .{ .url = "https://example.com/same", .title = "Four" },
        .{ .url = "https://example.com/same", .title = "Four" },
    });
    try testing.expect(!std.mem.eql(u8, ids[0], ids[1]));
    try testing.expectEqualStrings("https://example.com/ok", ids[2]);
    try testing.expectEqualStrings(ids[3], ids[4]);
}

test "identity prefers guid, then link, then a hash" {
    var f: Fixture = .init();
    defer f.deinit();
    const a = f.arena.allocator();
    try testing.expectEqualStrings("g", try identity(a, .{ .guid = "g", .url = "u" }));
    try testing.expectEqualStrings("u", try identity(a, .{ .url = "u", .title = "t" }));
    const by_title = try identity(a, .{ .title = "t", .published_at = 1 });
    try testing.expect(std.mem.startsWith(u8, by_title, "sha256:"));
    try testing.expectEqualStrings(by_title, try identity(a, .{ .title = "t", .published_at = 1 }));
    const other = try identity(a, .{ .title = "t", .published_at = 2 });
    try testing.expect(!std.mem.eql(u8, by_title, other));
}
