//! Finds the article inside a web page.
//!
//! A page is mostly not the article. This walks the HTML once, keeping a stack of
//! open elements and counting the text inside each, then scores every container:
//! a lot of paragraph text, few links and a helpful class name mean article. It is
//! a heuristic, so `pipeline` only uses the result when it clearly beats the feed.

const std = @import("std");
const blocks = @import("blocks.zig");
const html = @import("html.zig");

/// Elements nested deeper than this are ignored, which bounds the stack.
const max_depth = 256;
/// Less paragraph text than this is not an article.
const min_article_text = 200;
/// Among containers this close to the best, the smallest wins. An outer wrapper
/// holds the same text as the article, plus whatever else is on the page.
const near_best = 0.9;

const Frame = struct {
    name: []const u8,
    start: usize,
    inner: usize,
    paragraph_text: usize = 0,
    link_text: usize = 0,
    total_text: usize = 0,
    weight: f32 = 1,
    in_paragraph: bool,
    in_link: bool,
    /// This element is boilerplate. Its text counts for nothing, and it is cut out.
    skipped: bool,
    candidate: bool,
};

const Candidate = struct { start: usize, end: usize, score: f32 };
const Range = struct { start: usize, end: usize };

const Scan = struct {
    arena: std.mem.Allocator,
    input: []const u8,
    frames: [max_depth]Frame = undefined,
    depth: usize = 0,
    candidates: std.ArrayList(Candidate) = .empty,
    cuts: std.ArrayList(Range) = .empty,

    fn top(s: *Scan) ?*Frame {
        return if (s.depth == 0) null else &s.frames[s.depth - 1];
    }

    fn insideSkipped(s: *Scan) bool {
        for (s.frames[0..s.depth]) |frame| {
            if (frame.skipped) return true;
        }
        return false;
    }

    fn cut(s: *Scan, start: usize, end: usize) error{OutOfMemory}!void {
        if (!s.insideSkipped()) try s.cuts.append(s.arena, .{ .start = start, .end = end });
    }

    fn push(s: *Scan, tag: html.Tag, start: usize, inner: usize) void {
        if (s.depth == max_depth) return;
        const parent = s.top();
        const name = tag.name;
        s.frames[s.depth] = .{
            .name = name,
            .start = start,
            .inner = inner,
            .weight = weightOf(tag),
            .in_paragraph = (parent != null and parent.?.in_paragraph) or isParagraph(name),
            .in_link = (parent != null and parent.?.in_link) or std.ascii.eqlIgnoreCase(name, "a"),
            .skipped = isBoilerplate(tag),
            .candidate = isContainer(name),
        };
        s.depth += 1;
    }

    fn pop(s: *Scan, end: usize, inner_end: usize) error{OutOfMemory}!void {
        const frame = s.frames[s.depth - 1];
        s.depth -= 1;
        if (frame.skipped) return s.cut(frame.start, end);
        if (frame.candidate and frame.paragraph_text >= min_article_text) {
            const total: f32 = @floatFromInt(@max(frame.total_text, 1));
            const links: f32 = @floatFromInt(frame.link_text);
            const score = @as(f32, @floatFromInt(frame.paragraph_text)) * (1 - links / total) * frame.weight;
            try s.candidates.append(s.arena, .{ .start = frame.inner, .end = inner_end, .score = score });
        }
        if (s.top()) |parent| {
            parent.paragraph_text += frame.paragraph_text;
            parent.link_text += frame.link_text;
            parent.total_text += frame.total_text;
        }
    }

    fn close(s: *Scan, name: []const u8, inner_end: usize, end: usize) error{OutOfMemory}!void {
        var d = s.depth;
        while (d > 0) : (d -= 1) {
            if (std.ascii.eqlIgnoreCase(s.frames[d - 1].name, name)) {
                while (s.depth >= d) try s.pop(end, inner_end);
                return;
            }
        }
    }

    fn text(s: *Scan, raw: []const u8) void {
        const frame = s.top() orelse return;
        var count: usize = 0;
        for (raw) |c| {
            if (c != ' ' and c != '\n' and c != '\t' and c != '\r') count += 1;
        }
        frame.total_text += count;
        if (frame.in_paragraph) frame.paragraph_text += count;
        if (frame.in_link) frame.link_text += count;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isIn(name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |candidate| {
        if (eql(name, candidate)) return true;
    }
    return false;
}

fn isParagraph(name: []const u8) bool {
    return isIn(name, &.{ "p", "li", "pre", "blockquote", "dd", "figcaption" });
}

fn isContainer(name: []const u8) bool {
    return isIn(name, &.{ "article", "main", "section", "div", "td", "body" });
}

fn isVoid(name: []const u8) bool {
    return isIn(name, &.{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" });
}

/// Elements whose content is never read, so the tokenizer must not parse it.
fn isRaw(name: []const u8) bool {
    return isIn(name, &.{ "script", "style", "noscript", "template", "svg", "textarea" });
}

const negative_words = [_][]const u8{
    "comment", "comments",   "sidebar",   "footer",      "nav",        "navbar",     "navigation", "menu",
    "related", "share",      "sharing",   "social",      "promo",      "ad",         "ads",        "advert",
    "sponsor", "newsletter", "subscribe", "cookie",      "breadcrumb", "pagination", "popup",      "modal",
    "widget",  "banner",     "masthead",  "recommended", "signup",
};

const positive_words = [_][]const u8{ "article", "post", "content", "entry", "story", "prose", "body", "main", "blog", "text", "markdown" };

/// True if a class or id holds any of `words` as a whole word, so that "ad" does
/// not match "header" or "reading".
fn hasWord(value: []const u8, comptime words: []const []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, value, " -_\t\n");
    while (parts.next()) |part| {
        inline for (words) |word| {
            if (eql(part, word)) return true;
        }
    }
    return false;
}

fn isBoilerplate(tag: html.Tag) bool {
    if (isIn(tag.name, &.{ "nav", "header", "footer", "aside", "form", "button", "select" })) return true;
    if (tag.attribute("hidden") != null) return true;
    if (eql(tag.attribute("aria-hidden") orelse "", "true")) return true;
    if (isIn(tag.name, &.{ "article", "main", "body", "html" })) return false;
    const class = tag.attribute("class") orelse "";
    const id = tag.attribute("id") orelse "";
    if (hasWord(class, &positive_words) or hasWord(id, &positive_words)) return false;
    return hasWord(class, &negative_words) or hasWord(id, &negative_words);
}

fn weightOf(tag: html.Tag) f32 {
    var weight: f32 = 1;
    if (eql(tag.name, "article")) weight *= 1.3;
    if (eql(tag.name, "main")) weight *= 1.15;
    const class = tag.attribute("class") orelse "";
    const id = tag.attribute("id") orelse "";
    if (hasWord(class, &positive_words) or hasWord(id, &positive_words)) weight *= 1.25;
    return weight;
}

/// Returns the article's blocks, or null if no part of the page looks like one.
pub fn extract(arena: std.mem.Allocator, page: []const u8, base: []const u8) error{OutOfMemory}!?[]const blocks.Node {
    var scan: Scan = .{ .arena = arena, .input = page };
    var t: html.Tokenizer = .{ .input = page };
    var token_start: usize = 0;
    while (t.next()) |token| {
        const position = t.pos;
        switch (token) {
            .text => |raw| {
                if (!scan.insideSkipped()) scan.text(raw);
            },
            .open => |tag| {
                const start = offsetOf(page, tag.name) - 1;
                if (isRaw(tag.name)) {
                    if (!tag.self_closing) t.skipRaw(tag.name);
                    try scan.cut(start, t.pos);
                } else if (!tag.self_closing and !isVoid(tag.name)) {
                    scan.push(tag, start, position);
                }
            },
            .close => |name| {
                const end_tag = std.mem.lastIndexOfScalar(u8, page[0..position], '<') orelse token_start;
                try scan.close(name, end_tag, position);
            },
        }
        token_start = t.pos;
    }
    while (scan.depth > 0) try scan.pop(page.len, page.len);

    var best: f32 = 0;
    for (scan.candidates.items) |candidate| best = @max(best, candidate.score);
    if (best == 0) return null;

    var chosen: ?Candidate = null;
    for (scan.candidates.items) |candidate| {
        if (candidate.score < best * near_best) continue;
        if (chosen == null or candidate.end - candidate.start < chosen.?.end - chosen.?.start) chosen = candidate;
    }
    const article = chosen.?;

    // Rebuild the article without the boilerplate inside it.
    std.mem.sort(Range, scan.cuts.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var clean: std.ArrayList(u8) = try .initCapacity(arena, article.end - article.start);
    var position = article.start;
    for (scan.cuts.items) |range| {
        if (range.start < position or range.end > article.end) continue;
        clean.appendSliceAssumeCapacity(page[position..range.start]);
        position = range.end;
    }
    clean.appendSliceAssumeCapacity(page[position..article.end]);
    return try html.toBlocks(arena, clean.items, .{ .base = base });
}

fn offsetOf(page: []const u8, slice: []const u8) usize {
    return @intFromPtr(slice.ptr) - @intFromPtr(page.ptr);
}

const testing = std.testing;

fn expectArticle(page: []const u8, wanted: []const []const u8, unwanted: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = (try extract(a, page, "https://example.com/post")) orelse return error.TestUnexpectedResult;
    var out: std.Io.Writer.Allocating = .init(a);
    try blocks.writeText(&out.writer, nodes);
    for (wanted) |text| try testing.expect(std.mem.indexOf(u8, out.written(), text) != null);
    for (unwanted) |text| try testing.expect(std.mem.indexOf(u8, out.written(), text) == null);
}

const body = "<p>" ++ "This sentence is real article text that goes on for a while. " ++ "It has plenty of words in it, as articles do, and more than enough to count.</p>" ++
    "<p>A second paragraph continues the argument with even more words, all of them part of the article itself, and it carries on for a good while longer.</p>" ++
    "<p>THE-END of the article.</p>";

test "finds an article element and leaves the page around it" {
    try expectArticle(
        "<html><head><title>x</title><script>var a='<p>nope</p>';</script></head><body>" ++
            "<nav><a href=\"/\">Home</a><a href=\"/about\">NAV-LINK</a></nav><article>" ++ body ++ "</article>" ++
            "<footer>FOOTER-TEXT</footer></body></html>",
        &.{ "real article text", "THE-END" },
        &.{ "NAV-LINK", "FOOTER-TEXT", "nope" },
    );
}

test "works with plain divs, using text density" {
    try expectArticle(
        "<body><div class=\"links\"><p><a href=\"/1\">LINK-ONE</a></p><p><a href=\"/2\">LINK-TWO</a></p></div><div>" ++ body ++ "</div></body>",
        &.{"THE-END"},
        &.{"LINK-ONE"},
    );
}

test "boilerplate inside the article is cut out" {
    try expectArticle(
        "<article>" ++ body ++ "<div class=\"share-buttons\"><p>SHARE-THIS</p></div><aside>ASIDE-TEXT</aside><div id=\"comments\"><p>COMMENT-TEXT</p></div></article>",
        &.{"THE-END"},
        &.{ "SHARE-THIS", "ASIDE-TEXT", "COMMENT-TEXT" },
    );
}

test "a positive class outweighs a negative word" {
    try expectArticle("<div class=\"post-content sidebar-open\">" ++ body ++ "</div>", &.{"THE-END"}, &.{});
}

test "class words match whole words only" {
    try expectArticle("<div class=\"reading\">" ++ body ++ "</div><div class=\"ad\"><p>AD-TEXT</p></div>", &.{"THE-END"}, &.{"AD-TEXT"});
}

test "unclosed tags are survived" {
    try expectArticle("<body><article><p>" ++ body ++ "<div><p>more", &.{"THE-END"}, &.{});
}

test "pages with no article give null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try extract(a, "<html><body><p>short</p></body></html>", "https://e.test/"));
    try testing.expectEqual(null, try extract(a, "", "https://e.test/"));
    try testing.expectEqual(null, try extract(a, "not html at all", "https://e.test/"));
}

test "links resolve against the page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = (try extract(a, "<article>" ++ body ++ "<p><a href=\"/x\">y</a></p></article>", "https://example.com/post")).?;
    var out: std.Io.Writer.Allocating = .init(a);
    try blocks.writeJson(&out.writer, nodes);
    try testing.expect(std.mem.indexOf(u8, out.written(), "https://example.com/x") != null);
}
