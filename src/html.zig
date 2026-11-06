//! Converts HTML to blocks. This is an allowlist, not a filter: known structure
//! becomes nodes and everything else is discarded, so sanitizing happens as a
//! side effect of parsing rather than as a separate step that could be bypassed.
//!
//! The builder keeps a stack of open containers. Unknown tags such as <div> and
//! <span> are simply transparent, which is why it survives very bad markup.

const std = @import("std");
const blocks = @import("blocks.zig");
const url = @import("url.zig");
const xml = @import("xml.zig");

const Node = blocks.Node;

/// Containers nested deeper than this become transparent, which bounds both the
/// stack and the recursion of every renderer.
const max_depth = 32;

pub const Options = struct {
    /// Base for resolving relative links and images.
    base: []const u8 = "",
};

pub const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    self_closing: bool,

    pub fn attribute(tag: Tag, name: []const u8) ?[]const u8 {
        var it: xml.AttributeIterator = .{ .bytes = tag.attrs };
        while (it.next()) |attr| {
            if (std.ascii.eqlIgnoreCase(attr.name, name)) return attr.value;
        }
        return null;
    }
};

pub const Token = union(enum) {
    open: Tag,
    close: []const u8,
    text: []const u8,
};

pub const Tokenizer = struct {
    input: []const u8,
    pos: usize = 0,
    no_comment_close: bool = false,

    pub fn next(t: *Tokenizer) ?Token {
        while (t.pos < t.input.len) {
            const rest = t.input[t.pos..];
            if (rest[0] != '<') {
                const end = std.mem.indexOfScalarPos(u8, t.input, t.pos, '<') orelse t.input.len;
                defer t.pos = end;
                return .{ .text = t.input[t.pos..end] };
            }
            if (std.mem.startsWith(u8, rest, "<!--")) {
                // An unclosed "<!--" is usually code that was not escaped, so only
                // the marker is dropped. The flag keeps repeats of this linear.
                const end = if (t.no_comment_close) null else std.mem.indexOfPos(u8, t.input, t.pos + 4, "-->");
                if (end) |close| {
                    t.pos = close + 3;
                } else {
                    t.no_comment_close = true;
                    t.pos += 4;
                }
                continue;
            }
            if (rest.len > 1 and (rest[1] == '!' or rest[1] == '?')) {
                const end = std.mem.indexOfScalarPos(u8, t.input, t.pos, '>') orelse t.input.len;
                t.pos = @min(end + 1, t.input.len);
                continue;
            }
            if (rest.len > 2 and rest[1] == '/' and std.ascii.isAlphabetic(rest[2])) {
                var i = t.pos + 2;
                while (i < t.input.len and isNameChar(t.input[i])) i += 1;
                const name = t.input[t.pos + 2 .. i];
                const end = std.mem.indexOfScalarPos(u8, t.input, i, '>') orelse t.input.len;
                t.pos = @min(end + 1, t.input.len);
                return .{ .close = name };
            }
            if (rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
                var i = t.pos + 1;
                while (i < t.input.len and isNameChar(t.input[i])) i += 1;
                const name = t.input[t.pos + 1 .. i];
                const end = findTagEnd(t.input, i);
                var attrs_end = end;
                const self_closing = attrs_end > i and t.input[attrs_end - 1] == '/';
                if (self_closing) attrs_end -= 1;
                t.pos = @min(end + 1, t.input.len);
                return .{ .open = .{ .name = name, .attrs = t.input[i..attrs_end], .self_closing = self_closing } };
            }
            // A bare "<" is text.
            const end = std.mem.indexOfScalarPos(u8, t.input, t.pos + 1, '<') orelse t.input.len;
            defer t.pos = end;
            return .{ .text = t.input[t.pos..end] };
        }
        return null;
    }

    /// Moves past the end tag of a raw element such as <script>, unread.
    pub fn skipRaw(t: *Tokenizer, name: []const u8) void {
        var i = t.pos;
        while (std.mem.indexOfPos(u8, t.input, i, "</")) |at| {
            const after = at + 2;
            if (after + name.len <= t.input.len and std.ascii.eqlIgnoreCase(t.input[after .. after + name.len], name)) {
                const end = std.mem.indexOfScalarPos(u8, t.input, after, '>') orelse t.input.len;
                t.pos = @min(end + 1, t.input.len);
                return;
            }
            i = after;
        }
        t.pos = t.input.len;
    }
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == ':' or c == '_';
}

fn findTagEnd(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '>' => return i,
            '"', '\'' => {
                i = std.mem.indexOfScalarPos(u8, input, i + 1, input[i]) orelse {
                    return std.mem.indexOfScalarPos(u8, input, start, '>') orelse input.len;
                };
            },
            else => {},
        }
    }
    return input.len;
}

const Frame = struct {
    node: Node,
    children: std.ArrayList(Node) = .empty,
    /// Tag that closes this frame, or empty for the root.
    close: []const u8,
};

const Builder = struct {
    arena: std.mem.Allocator,
    base: []const u8,
    frames: [max_depth]Frame = undefined,
    depth: usize = 0,
    /// True when the next text should drop its leading space.
    at_line_start: bool = true,

    fn top(b: *Builder) *Frame {
        return &b.frames[b.depth - 1];
    }

    fn push(b: *Builder, node: Node, close: []const u8) void {
        b.frames[b.depth] = .{ .node = node, .close = close };
        b.depth += 1;
    }

    fn hasRoom(b: *const Builder) bool {
        return b.depth < max_depth - 2;
    }

    /// Closes the top frame into its parent. Empty frames disappear.
    fn pop(b: *Builder) error{OutOfMemory}!void {
        const frame = b.top();
        b.depth -= 1;
        var node = frame.node;
        trimTrailingSpace(frame);
        node.children = frame.children.items;
        const empty = node.children.len == 0;
        const keep = switch (node.kind) {
            .p, .h, .em, .strong, .link, .quote, .list, .table, .item, .row => !empty,
            else => true,
        };
        if (keep) try b.top().children.append(b.arena, node);
    }

    fn trimTrailingSpace(frame: *Frame) void {
        const items = frame.children.items;
        if (items.len == 0 or items[items.len - 1].kind != .text) return;
        if (frame.node.kind != .p and frame.node.kind != .h and frame.node.kind != .cell) return;
        const last = &items[items.len - 1];
        last.value = std.mem.trimEnd(u8, last.value, " ");
        if (last.value.len == 0) frame.children.shrinkRetainingCapacity(items.len - 1);
    }

    fn isInline(kind: blocks.Kind) bool {
        return switch (kind) {
            .p, .h, .em, .strong, .link, .cell => true,
            else => false,
        };
    }

    /// Closes any paragraph, heading and inline frames, leaving a block container
    /// on top. Table cells stay open, since they hold inline content directly.
    fn flushInline(b: *Builder) error{OutOfMemory}!void {
        while (b.top().node.kind != .cell and isInline(b.top().node.kind)) try b.pop();
        b.at_line_start = true;
    }

    /// Leaves any list or table that is not holding a cell or item open, so that a
    /// block can never become a direct child of one, as in <ul><h2>.
    fn leaveStructure(b: *Builder) error{OutOfMemory}!void {
        try b.flushInline();
        while (b.depth > 1) {
            switch (b.top().node.kind) {
                .list, .table, .row => try b.pop(),
                else => return,
            }
        }
    }

    /// Makes sure text can be added, opening an implicit paragraph if needed.
    fn ensureInline(b: *Builder) error{OutOfMemory}!void {
        switch (b.top().node.kind) {
            .list, .table, .row => {
                // Stray text directly inside a list or table has no valid place.
                while (b.depth > 1 and (b.top().node.kind == .list or b.top().node.kind == .table or b.top().node.kind == .row)) try b.pop();
            },
            else => {},
        }
        if (!isInline(b.top().node.kind)) {
            b.push(.{ .kind = .p }, "");
            b.at_line_start = true;
        }
    }

    fn addText(b: *Builder, raw: []const u8) error{OutOfMemory}!void {
        const decoded = try xml.decodeText(b.arena, raw);
        if (isBlank(decoded) and !isInline(b.top().node.kind)) return;
        var out: std.ArrayList(u8) = try .initCapacity(b.arena, decoded.len);
        var previous_space = b.at_line_start;
        for (decoded) |c| {
            const space = c == ' ' or c == '\n' or c == '\t' or c == '\r';
            if (space) {
                if (!previous_space) out.appendAssumeCapacity(' ');
                previous_space = true;
            } else if (c >= 0x20 and c != 0x7F) {
                // Dropping control characters stops terminal escape injection.
                out.appendAssumeCapacity(c);
                previous_space = false;
            }
        }
        if (out.items.len == 0) return;
        try b.ensureInline();
        b.at_line_start = previous_space;
        try b.top().children.append(b.arena, .{ .kind = .text, .value = out.items });
    }

    fn addBlock(b: *Builder, node: Node) error{OutOfMemory}!void {
        try b.leaveStructure();
        try b.top().children.append(b.arena, node);
    }

    fn closeTo(b: *Builder, name: []const u8) error{OutOfMemory}!void {
        var d = b.depth;
        while (d > 1) : (d -= 1) {
            if (std.ascii.eqlIgnoreCase(b.frames[d - 1].close, name)) {
                while (b.depth >= d) try b.pop();
                return;
            }
        }
    }

    /// Closes up to and including the nearest frame of `kind`, unless a list or
    /// table boundary comes first. This is what makes a missing </li> harmless.
    fn closeSibling(b: *Builder, kind: blocks.Kind, boundary: blocks.Kind) error{OutOfMemory}!void {
        var d = b.depth;
        while (d > 1) : (d -= 1) {
            const current = b.frames[d - 1].node.kind;
            if (current == boundary) return;
            if (current == kind) {
                while (b.depth >= d) try b.pop();
                return;
            }
        }
    }

    fn resolveUrl(b: *Builder, raw: []const u8) error{OutOfMemory}![]const u8 {
        const decoded = try cleanAttribute(b.arena, raw);
        if (b.base.len == 0) return decoded;
        return url.resolve(b.arena, b.base, decoded);
    }

    fn readPre(b: *Builder, t: *Tokenizer, pre: Tag) error{OutOfMemory}!void {
        var code: std.ArrayList(u8) = .empty;
        var language = languageOf(pre);
        while (t.next()) |token| {
            switch (token) {
                .text => |raw| {
                    for (try xml.decodeText(b.arena, raw)) |c| {
                        if (c >= 0x20 or c == '\n' or c == '\t') try code.append(b.arena, c);
                    }
                },
                .open => |tag| {
                    if (language.len == 0 and std.ascii.eqlIgnoreCase(tag.name, "code")) language = languageOf(tag);
                    if (std.ascii.eqlIgnoreCase(tag.name, "br")) try code.append(b.arena, '\n');
                },
                .close => |name| if (std.ascii.eqlIgnoreCase(name, "pre")) break,
            }
        }
        const value = std.mem.trim(u8, code.items, "\n");
        if (value.len != 0) try b.addBlock(.{ .kind = .code, .value = value, .label = language });
    }

    fn readInlineCode(b: *Builder, t: *Tokenizer) error{OutOfMemory}!void {
        var code: std.ArrayList(u8) = .empty;
        while (t.next()) |token| {
            switch (token) {
                .text => |raw| {
                    for (try xml.decodeText(b.arena, raw)) |c| {
                        if (c >= 0x20) try code.append(b.arena, c);
                    }
                },
                .close => |name| if (std.ascii.eqlIgnoreCase(name, "code") or std.ascii.eqlIgnoreCase(name, "kbd") or
                    std.ascii.eqlIgnoreCase(name, "samp") or std.ascii.eqlIgnoreCase(name, "tt")) break,
                .open => {},
            }
        }
        if (code.items.len == 0) return;
        try b.ensureInline();
        b.at_line_start = false;
        try b.top().children.append(b.arena, .{ .kind = .code, .value = code.items });
    }

    fn open(b: *Builder, t: *Tokenizer, tag: Tag) error{OutOfMemory}!void {
        const kind = tag_kinds.get(lowerName(tag.name)) orelse return;
        switch (kind) {
            .skip => if (!tag.self_closing) t.skipRaw(tag.name),
            .boundary => try b.flushInline(),
            .heading => {
                try b.leaveStructure();
                if (b.hasRoom()) {
                    b.push(.{ .kind = .h, .level = tag.name[1] - '0' }, tag.name);
                    b.at_line_start = true;
                }
            },
            .paragraph => {
                try b.leaveStructure();
                if (b.hasRoom()) b.push(.{ .kind = .p }, tag.name);
            },
            .quote => {
                try b.leaveStructure();
                if (b.hasRoom()) b.push(.{ .kind = .quote }, tag.name);
            },
            .list => {
                try b.leaveStructure();
                if (b.hasRoom()) b.push(.{ .kind = .list, .ordered = tag.name[0] == 'o' or tag.name[0] == 'O' }, tag.name);
            },
            .list_item => {
                try b.flushInline();
                try b.closeSibling(.item, .list);
                if (b.top().node.kind != .list and b.hasRoom()) b.push(.{ .kind = .list }, "");
                if (b.hasRoom()) b.push(.{ .kind = .item }, tag.name);
            },
            .table => {
                try b.leaveStructure();
                if (b.hasRoom()) b.push(.{ .kind = .table }, tag.name);
            },
            .table_row => {
                try b.closeSibling(.row, .table);
                if (b.top().node.kind == .table and b.hasRoom()) b.push(.{ .kind = .row }, tag.name);
            },
            .table_cell => {
                try b.closeSibling(.cell, .row);
                if (b.top().node.kind == .table and b.hasRoom()) b.push(.{ .kind = .row }, "");
                if (b.top().node.kind == .row and b.hasRoom()) {
                    b.push(.{ .kind = .cell }, tag.name);
                    b.at_line_start = true;
                }
            },
            .pre => try b.readPre(t, tag),
            .code => if (!tag.self_closing) try b.readInlineCode(t),
            .em, .strong => {
                try b.ensureInline();
                if (b.hasRoom()) b.push(.{ .kind = if (kind == .em) .em else .strong }, tag.name);
            },
            .anchor => {
                const raw = std.mem.trim(u8, tag.attribute("href") orelse return, " ");
                // A link within the same page, such as a heading's anchor, leads nowhere here.
                if (raw.len == 0 or raw[0] == '#') return;
                const href = try b.resolveUrl(raw);
                if (!url.isSafeLink(href) or isSamePage(href, b.base)) return;
                try b.ensureInline();
                if (b.hasRoom()) b.push(.{ .kind = .link, .url = href }, tag.name);
            },
            .br => if (isInline(b.top().node.kind)) {
                try b.top().children.append(b.arena, .{ .kind = .br });
                b.at_line_start = true;
            },
            .hr => try b.addBlock(.{ .kind = .hr }),
            .image => {
                const src = tag.attribute("src") orelse tag.attribute("data-src") orelse firstCandidate(tag.attribute("srcset")) orelse return;
                const resolved = try b.resolveUrl(src);
                if (!url.isHttp(resolved) or isTrackingPixel(tag)) return;
                const alt = try cleanAttribute(b.arena, tag.attribute("alt") orelse "");
                try b.addBlock(.{ .kind = .img, .url = resolved, .label = alt });
            },
            .embed => {
                const src = try b.resolveUrl(tag.attribute("src") orelse "");
                if (url.isHttp(src)) try b.addBlock(.{ .kind = .embed, .url = src });
                if (!tag.self_closing) t.skipRaw(tag.name);
            },
        }
    }
};

/// Returns the first URL of a srcset list such as "a.jpg 1x, b.jpg 2x".
fn firstCandidate(srcset: ?[]const u8) ?[]const u8 {
    var parts = std.mem.tokenizeAny(u8, srcset orelse return null, " ,\t\n");
    return parts.next();
}

fn cleanAttribute(arena: std.mem.Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    const decoded = try xml.decodeText(arena, raw);
    var out: std.ArrayList(u8) = try .initCapacity(arena, decoded.len);
    for (decoded) |c| {
        if (c >= 0x20 and c != 0x7F) out.appendAssumeCapacity(c);
    }
    return std.mem.trim(u8, out.items, " ");
}

fn isSamePage(href: []const u8, base: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, href, '#') orelse return false;
    const base_end = std.mem.indexOfScalar(u8, base, '#') orelse base.len;
    return std.mem.eql(u8, href[0..end], base[0..base_end]);
}

fn isTrackingPixel(tag: Tag) bool {
    const width = tag.attribute("width") orelse "";
    const height = tag.attribute("height") orelse "";
    const tiny_width = std.mem.eql(u8, width, "1") or std.mem.eql(u8, width, "0");
    const tiny_height = std.mem.eql(u8, height, "1") or std.mem.eql(u8, height, "0");
    return tiny_width and tiny_height;
}

fn isBlank(text: []const u8) bool {
    return std.mem.indexOfNone(u8, text, " \t\r\n") == null;
}

fn languageOf(tag: Tag) []const u8 {
    const class = tag.attribute("class") orelse return "";
    var names = std.mem.tokenizeScalar(u8, class, ' ');
    while (names.next()) |name| {
        const language = if (std.mem.startsWith(u8, name, "language-"))
            name["language-".len..]
        else if (std.mem.startsWith(u8, name, "lang-"))
            name["lang-".len..]
        else
            continue;
        for (language) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '+' and c != '#' and c != '_') return "";
        }
        return language;
    }
    return "";
}

/// Tag names are matched in lower case. Longer names are not in the table.
fn lowerName(name: []const u8) LowerName {
    var lower: LowerName = .{};
    lower.len = @min(name.len, lower.bytes.len);
    if (name.len > lower.bytes.len) lower.len = 0;
    for (name[0..lower.len], 0..) |c, i| lower.bytes[i] = std.ascii.toLower(c);
    return lower;
}

const LowerName = struct {
    bytes: [12]u8 = undefined,
    len: usize = 0,
};

const TagKind = enum {
    skip,
    boundary,
    heading,
    paragraph,
    quote,
    list,
    list_item,
    table,
    table_row,
    table_cell,
    pre,
    code,
    em,
    strong,
    anchor,
    br,
    hr,
    image,
    embed,
};

const tag_kinds = struct {
    const map: std.StaticStringMap(TagKind) = .initComptime(.{
        .{ "script", .skip },      .{ "style", .skip },       .{ "noscript", .skip },       .{ "template", .skip },
        .{ "svg", .skip },         .{ "math", .skip },        .{ "head", .skip },           .{ "title", .skip },
        .{ "form", .skip },        .{ "select", .skip },      .{ "textarea", .skip },       .{ "button", .skip },
        .{ "canvas", .skip },      .{ "nav", .skip },         .{ "aside", .boundary },      .{ "div", .boundary },
        .{ "section", .boundary }, .{ "article", .boundary }, .{ "main", .boundary },       .{ "header", .boundary },
        .{ "footer", .boundary },  .{ "figure", .boundary },  .{ "figcaption", .boundary }, .{ "details", .boundary },
        .{ "summary", .boundary }, .{ "center", .boundary },  .{ "address", .boundary },    .{ "dl", .boundary },
        .{ "dt", .boundary },      .{ "dd", .boundary },      .{ "h1", .heading },          .{ "h2", .heading },
        .{ "h3", .heading },       .{ "h4", .heading },       .{ "h5", .heading },          .{ "h6", .heading },
        .{ "p", .paragraph },      .{ "blockquote", .quote }, .{ "ul", .list },             .{ "ol", .list },
        .{ "li", .list_item },     .{ "table", .table },      .{ "tr", .table_row },        .{ "td", .table_cell },
        .{ "th", .table_cell },    .{ "pre", .pre },          .{ "code", .code },           .{ "kbd", .code },
        .{ "samp", .code },        .{ "tt", .code },          .{ "em", .em },               .{ "i", .em },
        .{ "cite", .em },          .{ "strong", .strong },    .{ "b", .strong },            .{ "a", .anchor },
        .{ "br", .br },            .{ "hr", .hr },            .{ "img", .image },           .{ "iframe", .embed },
        .{ "video", .embed },      .{ "audio", .embed },      .{ "embed", .embed },         .{ "object", .skip },
    });

    fn get(name: LowerName) ?TagKind {
        return map.get(name.bytes[0..name.len]);
    }
};

/// Converts an HTML fragment to blocks.
pub fn toBlocks(arena: std.mem.Allocator, input: []const u8, options: Options) error{OutOfMemory}![]const Node {
    // Double-escaped bodies arrive with their tags as "&lt;p&gt;" and no real tags.
    var html = input;
    if (std.mem.indexOfScalar(u8, html, '<') == null and std.mem.indexOf(u8, html, "&lt;") != null) {
        html = try xml.decodeText(arena, html);
    }

    var t: Tokenizer = .{ .input = html };
    var b: Builder = .{ .arena = arena, .base = options.base };
    b.push(.{ .kind = .quote }, "");

    while (t.next()) |token| {
        switch (token) {
            .text => |raw| try b.addText(raw),
            .open => |tag| try b.open(&t, tag),
            .close => |name| try b.closeTo(name),
        }
    }
    while (b.depth > 1) try b.pop();
    return b.frames[0].children.items;
}

/// Converts plain text to blocks: one paragraph per blank-line-separated section.
pub fn textToBlocks(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    const unix_text = try std.mem.replaceOwned(u8, arena, text, "\r\n", "\n");
    var sections = std.mem.splitSequence(u8, unix_text, "\n\n");
    while (sections.next()) |section| {
        var clean: std.ArrayList(u8) = try .initCapacity(arena, section.len);
        for (section) |c| {
            if (c == '\n' or c == '\t' or c == '\r') {
                clean.appendAssumeCapacity(' ');
            } else if (c >= 0x20 and c != 0x7F) {
                clean.appendAssumeCapacity(c);
            }
        }
        const value = std.mem.trim(u8, clean.items, " ");
        if (value.len == 0) continue;
        const child = try arena.alloc(Node, 1);
        child[0] = .{ .kind = .text, .value = value };
        try nodes.append(arena, .{ .kind = .p, .children = child });
    }
    return nodes.items;
}

/// Finds feeds advertised by an HTML page through <link rel="alternate">.
pub fn discoverFeeds(arena: std.mem.Allocator, page: []const u8, base: []const u8) error{OutOfMemory}![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var t: Tokenizer = .{ .input = page };
    while (t.next()) |token| {
        if (token != .open) continue;
        const tag = token.open;
        if (!std.ascii.eqlIgnoreCase(tag.name, "link")) continue;
        const rel = tag.attribute("rel") orelse continue;
        if (std.ascii.findIgnoreCase(rel, "alternate") == null) continue;
        const kind = tag.attribute("type") orelse continue;
        const is_feed = std.ascii.findIgnoreCase(kind, "rss") != null or
            std.ascii.findIgnoreCase(kind, "atom") != null or
            std.ascii.findIgnoreCase(kind, "feed+json") != null;
        if (!is_feed) continue;
        const href = tag.attribute("href") orelse continue;
        try found.append(arena, try url.resolve(arena, base, try xml.decodeText(arena, href)));
    }
    return found.items;
}

const testing = std.testing;

fn expectMarkdown(expected: []const u8, html: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const nodes = try toBlocks(arena.allocator(), html, .{ .base = "https://example.com/blog/post" });
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try blocks.writeMarkdown(&w, nodes);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "paragraphs and inline styles" {
    try expectMarkdown("Hello **bold** and *em*\n\nSecond", "<p>Hello <b>bold</b> and <em>em</em></p><p>Second</p>");
}

test "whitespace collapses" {
    try expectMarkdown("a b c", "<p>  a \n  b\t\tc  </p>");
}

test "bare text gets a paragraph" {
    try expectMarkdown("just text", "just text");
}

test "missing end tags" {
    try expectMarkdown("one\n\ntwo", "<p>one<p>two");
    try expectMarkdown("- a\n- b", "<ul><li>a<li>b</ul>");
}

test "headings, links and images resolve against the base" {
    try expectMarkdown("## T\n\n[x](https://example.com/blog/a)\n\n![pic](https://example.com/i.png)", "<h2>T</h2><a href=\"a\">x</a><img src=\"/i.png\" alt=\"pic\">");
}

test "code blocks keep their whitespace and language" {
    try expectMarkdown("```zig\nconst x = 1;\n  y();\n```", "<pre><code class=\"language-zig\">const x = 1;\n  <span>y</span>();\n</code></pre>");
}

test "inline code" {
    try expectMarkdown("use `a < b` here", "<p>use <code>a &lt; b</code> here</p>");
}

test "nested lists and quotes" {
    try expectMarkdown("- a\n  - b", "<ul><li>a<ul><li>b</li></ul></li></ul>");
    try expectMarkdown("> q", "<blockquote><p>q</p></blockquote>");
}

test "tables" {
    try expectMarkdown("| h |\n| --- |\n| c |", "<table><thead><tr><th>h</th></tr></thead><tbody><tr><td>c</td></tr></tbody></table>");
}

test "scripts and styles leave nothing behind" {
    try expectMarkdown("a\n\nb", "<p>a</p><script>alert('<p>x</p>')</script><style>p{}</style><p>b</p>");
    try expectMarkdown("a", "<p>a</p><SCRIPT>evil()</SCRIPT>");
}

test "event handlers and styles cannot survive" {
    try expectMarkdown("x", "<p onclick=\"evil()\" style=\"color:red\">x</p>");
}

test "dangerous links lose their link but keep their text" {
    try expectMarkdown("click", "<a href=\"javascript:alert(1)\">click</a>");
    try expectMarkdown("click", "<a href=\"JaVaScRiPt:alert(1)\">click</a>");
    try expectMarkdown("click", "<a href=\"java&#115;cript:alert(1)\">click</a>");
    try expectMarkdown("click", "<a href=\"data:text/html,x\">click</a>");
}

test "data URIs and tracking pixels are not images" {
    try expectMarkdown("", "<img src=\"data:image/png;base64,AAAA\">");
    try expectMarkdown("", "<img src=\"https://t.example/p.gif\" width=\"1\" height=\"1\">");
}

test "blocks cannot land directly inside a list or table" {
    try expectMarkdown("- a\n\n## T", "<li>a</li><h2>T</h2>");
    try expectMarkdown("- a\n\nb", "<ul><li>a</li><p>b</p></ul>");
    try expectMarkdown("x", "<table><p>x</p></table>");
}

test "terminal escape sequences are removed" {
    try expectMarkdown("[31mred", "<p>\x1B[31mred</p>");
    try expectMarkdown("[2Jclear", "<p>&#27;[2Jclear</p>");
    try expectMarkdown("[x](https://example.com/[2J)", "<a href=\"https://example.com/&#27;[2J\">x</a>");
}

test "double-escaped bodies" {
    try expectMarkdown("Hi **there**", "&lt;p&gt;Hi &lt;b&gt;there&lt;/b&gt;&lt;/p&gt;");
}

test "images with only a srcset" {
    try expectMarkdown("![a](https://example.com/s.jpg)", "<img srcset=\"https://example.com/s.jpg, https://example.com/l.jpg 2x\" alt=\"a\">");
}

test "an unclosed comment does not swallow the rest" {
    try expectMarkdown("a\n\nb", "<p>a</p><!-- <p>b</p>");
}

test "links within the page keep their text only" {
    try expectMarkdown("## Part", "<h2><a href=\"#part\">Part</a></h2>");
    try expectMarkdown("## Part", "<h2><a href=\"https://example.com/blog/post#part\">Part</a></h2>");
    try expectMarkdown("[x](https://example.com/other#part)", "<a href=\"/other#part\">x</a>");
}

test "embeds become links" {
    try expectMarkdown("[Embedded media](https://video.example/1)", "<iframe src=\"https://video.example/1\">fallback</iframe>");
}

test "deep nesting stays bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var input: std.ArrayList(u8) = .empty;
    for (0..10_000) |_| try input.appendSlice(arena.allocator(), "<blockquote><ul><li><b>");
    try input.appendSlice(arena.allocator(), "x");
    const nodes = try toBlocks(arena.allocator(), input.items, .{});
    try testing.expect(nodes.len != 0);
}

test "plain text bodies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const nodes = try textToBlocks(arena.allocator(), "one\nline\n\n<b>two</b>");
    try testing.expectEqual(2, nodes.len);
    try testing.expectEqualStrings("one line", nodes[0].children[0].value);
    try testing.expectEqualStrings("<b>two</b>", nodes[1].children[0].value);
}

test "feed discovery" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const found = try discoverFeeds(arena.allocator(),
        \\<html><head><link rel="stylesheet" href="a.css">
        \\<link rel="alternate" type="application/rss+xml" href="/feed.xml">
        \\<link rel="alternate" type="application/atom+xml" href="https://other.example/atom">
        \\<link rel="alternate" type="text/html" href="/x">
    , "https://example.com/blog/");
    try testing.expectEqual(2, found.len);
    try testing.expectEqualStrings("https://example.com/feed.xml", found[0]);
    try testing.expectEqualStrings("https://other.example/atom", found[1]);
}

test "a blank line with Windows line endings separates paragraphs" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(2, (try textToBlocks(arena.allocator(), "one\r\n\r\ntwo")).len);
}
