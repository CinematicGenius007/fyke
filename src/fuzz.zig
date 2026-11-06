//! Fuzz targets. `zig build test` runs each once on its seeds; add `--fuzz` to
//! search for crashes with coverage guidance. tools/feedcheck.zig has a second,
//! mutation-based fuzzer that starts from real feeds.

const std = @import("std");
const dates = @import("dates.zig");
const blocks = @import("blocks.zig");
const feed = @import("feed.zig");
const html = @import("html.zig");
const layout = @import("layout.zig");
const opml = @import("opml.zig");
const terminal = @import("terminal.zig");
const url = @import("url.zig");
const xml = @import("xml.zig");

const testing = std.testing;
const Smith = testing.Smith;

const seeds: []const []const u8 = &.{
    "<rss version=\"2.0\"><channel><title>t</title><item><title>a</title><guid>g</guid><pubDate>Fri, 06 Nov 2026 09:30:00 GMT</pubDate><description><![CDATA[<p>x</p>]]></description></item></channel></rss>",
    "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>t</title><entry><id>1</id><link href=\"u\"/><content type=\"xhtml\"><div>x</div></content></entry></feed>",
    "<rdf:RDF xmlns=\"http://purl.org/rss/1.0/\"><item><title>a &amp; b</title></item></rdf:RDF>",
    "{\"version\":\"https://jsonfeed.org/version/1.1\",\"items\":[{\"id\":1,\"title\":\"a\",\"attachments\":[{\"url\":\"u\"}]}]}",
    "<opml><body><outline text=\"f\"><outline xmlUrl=\"u\"/></outline></body></opml>",
    "<!DOCTYPE a [<!ENTITY b \"c\">]><a>&b;&#x41;<!-- c --><?p i?></a>",
};

test "feed.parse never crashes" {
    try testing.fuzz({}, parseFeed, .{ .corpus = seeds });
}

test "xml.Parser always balances" {
    try testing.fuzz({}, parseXml, .{ .corpus = seeds });
}

test "opml.parse never crashes" {
    try testing.fuzz({}, parseOpml, .{ .corpus = seeds });
}

test "dates.parse never crashes" {
    try testing.fuzz({}, parseDate, .{ .corpus = &.{ "Fri, 06 Nov 2026 09:30:00 GMT", "2026-11-06T09:30:00.123+05:30" } });
}

test "decodeText never grows its input" {
    try testing.fuzz({}, decode, .{ .corpus = &.{ "a&amp;b&#x41;&nbsp;&bad;&#xD800;&", "&#1114111;" } });
}

test "html.toBlocks keeps its guarantees" {
    try testing.fuzz({}, convertHtml, .{ .corpus = &.{
        "<p>a <b>b</b> <a href=\"x\">c</a></p><ul><li>d<li>e</ul><table><tr><td>f</table><pre><code>g</code></pre><img src=\"h\"><script>i</script>",
        "<blockquote><h1>a</h1><iframe src=\"http://e/\"></iframe></blockquote><hr><br>&lt;p&gt;",
    } });
}

test "url functions never crash" {
    try testing.fuzz({}, urls, .{ .corpus = &.{ "http://a/b/c/d;p?q#f", "../../g?x=1&utm_source=2", "//host:80/.." } });
}

test "the key decoder always makes progress" {
    try testing.fuzz({}, decodeKeys, .{ .corpus = &.{ "j\x1b[A\x1b[6~\x1bOB\xE4\xB8\xAD\x7f\r", "\x1b[1;5A\x1b", "\xFF\x1b[" } });
}

test "the screen renders any text without control bytes" {
    try testing.fuzz({}, drawText, .{ .corpus = &.{ "plain \xE4\xB8\xAD\xF0\x9F\x98\x80 e\xCC\x81 \x1b[2J\xC2\x9B\xE2\x80\xAE\xFF", "\xE4\xB8\xAD\xE4\xB8\xAD\xE4\xB8\xAD" } });
}

test "layout handles any article at any width" {
    try testing.fuzz({}, layArticle, .{ .corpus = &.{"<h1>a</h1><p>b <a href=\"http://e/\">c</a></p><ul><li>d</ul><blockquote><pre>e</pre></blockquote><table><tr><td>f<td>g</table><img src=\"http://e/i\">"} });
}

var input_buffer: [64 * 1024]u8 = undefined;

fn input(smith: *Smith) []const u8 {
    return input_buffer[0..smith.slice(&input_buffer)];
}

fn parseFeed(_: void, smith: *Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const result = feed.parse(arena.allocator(), input(smith)) catch return;
    _ = try feed.identities(arena.allocator(), result.entries);
}

fn parseXml(_: void, smith: *Smith) anyerror!void {
    var p: xml.Parser = .init(input(smith));
    var depth: usize = 0;
    while (true) {
        const event = p.next() catch return;
        switch (event) {
            .start => depth += 1,
            .end => depth -= 1,
            .eof => break,
            else => {},
        }
    }
    try testing.expectEqual(0, depth);
}

fn parseOpml(_: void, smith: *Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = opml.parse(arena.allocator(), input(smith)) catch return;
}

fn parseDate(_: void, smith: *Smith) anyerror!void {
    _ = dates.parse(input(smith));
}

fn decode(_: void, smith: *Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw = input(smith);
    const decoded = try xml.decodeText(arena.allocator(), raw);
    try testing.expect(decoded.len <= raw.len);
}

fn convertHtml(_: void, smith: *Smith) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = try html.toBlocks(arena, input(smith), .{ .base = "https://example.com/a/" });

    var json: std.Io.Writer.Allocating = .init(arena);
    try blocks.writeJson(&json.writer, nodes);
    var again: std.Io.Writer.Allocating = .init(arena);
    try blocks.writeJson(&again.writer, try blocks.parseJson(arena, json.written()));
    if (!std.mem.eql(u8, json.written(), again.written())) {
        const at = std.mem.indexOfDiff(u8, json.written(), again.written()).?;
        std.debug.print("DIFF at {d}\n1: {f}\n2: {f}\n", .{ at, std.ascii.hexEscape(json.written()[at -| 80..@min(json.written().len, at + 80)], .lower), std.ascii.hexEscape(again.written()[at -| 80..@min(again.written().len, at + 80)], .lower) });
        return error.TestExpectedEqual;
    }

    var markdown: std.Io.Writer.Allocating = .init(arena);
    try blocks.writeMarkdown(&markdown.writer, nodes);
    try expectNoControlBytes(markdown.written());
    try expectSafeUrls(nodes);
}

fn expectNoControlBytes(text: []const u8) !void {
    for (text) |c| try testing.expect(c >= 0x20 or c == '\n' or c == '\t');
}

fn expectSafeUrls(nodes: []const blocks.Node) !void {
    for (nodes) |node| {
        if (node.url.len != 0) try testing.expect(url.isSafeLink(node.url));
        try expectSafeUrls(node.children);
    }
}

fn urls(_: void, smith: *Smith) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = input(smith);
    const middle = text.len / 2;
    _ = try url.resolve(arena.allocator(), text[0..middle], text[middle..]);
    _ = try url.canonical(arena.allocator(), text);
    _ = url.isSafeLink(text);
    _ = url.isHttp(text);
}

fn decodeKeys(_: void, smith: *Smith) anyerror!void {
    var rest = input(smith);
    while (rest.len != 0) {
        const decoded = terminal.decodeKey(rest) orelse return;
        try testing.expect(decoded.consumed != 0 and decoded.consumed <= rest.len);
        rest = rest[decoded.consumed..];
    }
}

fn drawText(_: void, smith: *Smith) anyerror!void {
    const text = input(smith);
    const columns = 1 + text.len % 17;
    var previous: terminal.Screen = try .init(testing.allocator, columns, 3);
    defer previous.deinit(testing.allocator);
    var screen: terminal.Screen = try .init(testing.allocator, columns, 3);
    defer screen.deinit(testing.allocator);

    const half = text.len / 2;
    _ = previous.put(0, 0, columns, text[0..half], .{});
    _ = screen.put(0, 0, columns, text[half..], .{ .bold = true });
    _ = screen.put(columns / 2, 0, columns, text[0..half], .{});
    screen.fill(columns / 3, 1, columns, .{ .reverse = true });

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try screen.render(&previous, &out.writer);

    // Every escape must be one of the few sequences that render itself produces.
    const bytes = out.written();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, i, 0x1B)) |at| {
        try testing.expect(at + 1 < bytes.len and bytes[at + 1] == '[');
        i = at + 1;
    }
    for (bytes) |byte| try testing.expect(byte >= 0x20 or byte == 0x1B);
}

fn layArticle(_: void, smith: *Smith) anyerror!void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = input(smith);
    const nodes = try html.toBlocks(arena, text, .{ .base = "https://example.com/" });
    for ([_]usize{ 1, 8, 20 + text.len % 80 }) |columns| _ = try layout.lay(arena, nodes, columns);
}
