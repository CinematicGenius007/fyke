//! The content model: every article body in the system is a tree of these nodes.
//! See docs/architecture.md ("Content model").
//!
//! HTML is converted to blocks once, at ingest. Every surface then renders blocks,
//! so no surface needs an HTML engine, and anything without a node kind simply
//! cannot reach a reader. Scripts are impossible by construction.

const std = @import("std");

pub const Kind = enum {
    // Blocks.
    p,
    h,
    code,
    img,
    quote,
    list,
    table,
    hr,
    embed,
    // Inlines. `code` above doubles as inline code when inside a paragraph.
    text,
    em,
    strong,
    link,
    br,
    // Structure, written as nested JSON arrays rather than as objects.
    item,
    row,
    cell,
};

pub const Node = struct {
    kind: Kind,
    /// Text of `text` and `code` nodes.
    value: []const u8 = "",
    /// Target of `link`, `img` and `embed` nodes.
    url: []const u8 = "",
    /// `alt` of `img`, `lang` of a code block.
    label: []const u8 = "",
    level: u8 = 0,
    ordered: bool = false,
    children: []const Node = &.{},
};

/// Writes the stored JSON form.
pub fn writeJson(w: *std.Io.Writer, nodes: []const Node) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (nodes, 0..) |node, i| {
        if (i != 0) try w.writeByte(',');
        try writeNode(w, node);
    }
    try w.writeByte(']');
}

/// Input should already be UTF-8, but the stored format must not depend on that:
/// std.json writes invalid text as an array of numbers, not a string.
pub fn writeString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(text)) return w.print("{f}", .{std.json.fmt(text, .{})});
    try w.writeByte('"');
    var i: usize = 0;
    while (i < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (length == 0 or i + length > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + length])) {
            try w.writeAll("\xEF\xBF\xBD");
            i += 1;
            continue;
        }
        const encoded = std.json.fmt(text[i .. i + length], .{});
        var buffer: [16]u8 = undefined;
        const quoted = std.fmt.bufPrint(&buffer, "{f}", .{encoded}) catch unreachable;
        try w.writeAll(quoted[1 .. quoted.len - 1]);
        i += length;
    }
    try w.writeByte('"');
}

fn writeNode(w: *std.Io.Writer, node: Node) std.Io.Writer.Error!void {
    if (node.kind == .item or node.kind == .row or node.kind == .cell) return writeJson(w, node.children);

    try w.print("{{\"t\":\"{s}\"", .{@tagName(node.kind)});
    switch (node.kind) {
        .text => {
            try w.writeAll(",\"v\":");
            try writeString(w, node.value);
        },
        .code => {
            try w.writeAll(",\"v\":");
            try writeString(w, node.value);
            if (node.label.len != 0) {
                try w.writeAll(",\"lang\":");
                try writeString(w, node.label);
            }
        },
        .img => {
            try w.writeAll(",\"src\":");
            try writeString(w, node.url);
            try w.writeAll(",\"alt\":");
            try writeString(w, node.label);
        },
        .link, .embed => {
            try w.writeAll(",\"href\":");
            try writeString(w, node.url);
        },
        .list => {
            try w.print(",\"ordered\":{},\"items\":", .{node.ordered});
            try writeJson(w, node.children);
        },
        .table => {
            try w.writeAll(",\"rows\":");
            try writeJson(w, node.children);
        },
        .h => try w.print(",\"level\":{d}", .{node.level}),
        else => {},
    }
    switch (node.kind) {
        .p, .h, .quote, .em, .strong, .link => {
            try w.writeAll(",\"c\":");
            try writeJson(w, node.children);
        },
        else => {},
    }
    try w.writeByte('}');
}

/// Reads the stored JSON form. Anything unrecognized is dropped.
pub fn parseJson(arena: std.mem.Allocator, json: []const u8) error{ OutOfMemory, InvalidBlocks }![]const Node {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidBlocks,
    };
    return nodesFromJson(arena, root);
}

fn nodesFromJson(arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}![]const Node {
    if (value != .array) return &.{};
    var nodes: std.ArrayList(Node) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name = stringField(item, "t");
        const kind = std.meta.stringToEnum(Kind, name) orelse continue;
        var node: Node = .{ .kind = kind };
        switch (kind) {
            .text => node.value = stringField(item, "v"),
            .code => {
                node.value = stringField(item, "v");
                node.label = stringField(item, "lang");
            },
            .img => {
                node.url = stringField(item, "src");
                node.label = stringField(item, "alt");
            },
            .link, .embed => node.url = stringField(item, "href"),
            .h => {
                const level = item.object.get("level");
                if (level != null and level.? == .integer) node.level = @intCast(std.math.clamp(level.?.integer, 1, 6));
            },
            .list => {
                const ordered = item.object.get("ordered");
                node.ordered = ordered != null and ordered.? == .bool and ordered.?.bool;
                node.children = try wrapped(arena, item.object.get("items"), .item, false);
            },
            .table => node.children = try wrapped(arena, item.object.get("rows"), .row, true),
            else => {},
        }
        if (item.object.get("c")) |children| node.children = try nodesFromJson(arena, children);
        try nodes.append(arena, node);
    }
    return nodes.items;
}

/// Reads the nested arrays of lists and tables back into structural nodes.
fn wrapped(arena: std.mem.Allocator, value: ?std.json.Value, kind: Kind, nested: bool) error{OutOfMemory}![]const Node {
    const list = value orelse return &.{};
    if (list != .array) return &.{};
    const out = try arena.alloc(Node, list.array.items.len);
    for (list.array.items, out) |entry, *node| {
        node.* = .{
            .kind = kind,
            .children = if (nested) try wrapped(arena, entry, .cell, false) else try nodesFromJson(arena, entry),
        };
    }
    return out;
}

fn stringField(value: std.json.Value, key: []const u8) []const u8 {
    const field = value.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

/// Plain text, for search and for agents that want no markup.
pub fn writeText(w: *std.Io.Writer, nodes: []const Node) std.Io.Writer.Error!void {
    var separate = false;
    for (nodes) |node| {
        if (separate and isBlock(node.kind)) try w.writeAll("\n\n");
        try writeTextNode(w, node);
        separate = true;
    }
}

fn isBlock(kind: Kind) bool {
    return switch (kind) {
        .p, .h, .quote, .list, .table, .img, .embed, .hr, .item, .row => true,
        else => false,
    };
}

fn writeTextNode(w: *std.Io.Writer, node: Node) std.Io.Writer.Error!void {
    switch (node.kind) {
        .text, .code => try w.writeAll(node.value),
        .br => try w.writeByte('\n'),
        .img => try w.writeAll(node.label),
        .hr, .embed => {},
        .cell => {
            try writeText(w, node.children);
            try w.writeByte(' ');
        },
        else => try writeText(w, node.children),
    }
}

/// Markdown, which is what models read best and what the CLI prints.
pub fn writeMarkdown(w: *std.Io.Writer, nodes: []const Node) std.Io.Writer.Error!void {
    for (nodes, 0..) |node, i| {
        if (i != 0) try w.writeAll("\n\n");
        try writeMarkdownBlock(w, node, 0);
    }
}

fn writeMarkdownBlock(w: *std.Io.Writer, node: Node, indent: usize) std.Io.Writer.Error!void {
    switch (node.kind) {
        .h => {
            for (0..@max(node.level, 1)) |_| try w.writeByte('#');
            try w.writeByte(' ');
            try writeInlines(w, node.children);
        },
        .code => {
            try w.print("```{s}\n{s}\n```", .{ node.label, node.value });
        },
        .img => try w.print("![{s}]({s})", .{ node.label, node.url }),
        .embed => try w.print("[Embedded media]({s})", .{node.url}),
        .hr => try w.writeAll("---"),
        .quote => {
            // Quoted blocks are rendered to a buffer so that each line gets its marker.
            var buffer: [16 * 1024]u8 = undefined;
            var quoted: std.Io.Writer = .fixed(&buffer);
            writeMarkdown(&quoted, node.children) catch {};
            var lines = std.mem.splitScalar(u8, quoted.buffered(), '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try w.writeByte('\n');
                first = false;
                try w.print("> {s}", .{line});
            }
        },
        .list => {
            for (node.children, 0..) |item, i| {
                if (i != 0) try w.writeByte('\n');
                for (0..indent) |_| try w.writeByte(' ');
                if (node.ordered) try w.print("{d}. ", .{i + 1}) else try w.writeAll("- ");
                for (item.children, 0..) |child, j| {
                    if (child.kind == .list) {
                        try w.writeByte('\n');
                        try writeMarkdownBlock(w, child, indent + 2);
                    } else {
                        if (j != 0) try w.writeByte(' ');
                        try writeMarkdownBlock(w, child, indent + 2);
                    }
                }
            }
        },
        .table => {
            for (node.children, 0..) |row, i| {
                try w.writeAll("|");
                for (row.children) |cell| {
                    try w.writeByte(' ');
                    try writeInlines(w, cell.children);
                    try w.writeAll(" |");
                }
                if (i == 0) {
                    try w.writeAll("\n|");
                    for (row.children) |_| try w.writeAll(" --- |");
                }
                if (i + 1 != node.children.len) try w.writeByte('\n');
            }
        },
        else => try writeInlines(w, node.children),
    }
}

fn writeInlines(w: *std.Io.Writer, nodes: []const Node) std.Io.Writer.Error!void {
    for (nodes) |node| {
        switch (node.kind) {
            .text => try w.writeAll(node.value),
            .code => try w.print("`{s}`", .{node.value}),
            .br => try w.writeAll("  \n"),
            .em => {
                try w.writeByte('*');
                try writeInlines(w, node.children);
                try w.writeByte('*');
            },
            .strong => {
                try w.writeAll("**");
                try writeInlines(w, node.children);
                try w.writeAll("**");
            },
            .link => {
                try w.writeByte('[');
                try writeInlines(w, node.children);
                try w.print("]({s})", .{node.url});
            },
            else => try writeInlines(w, node.children),
        }
    }
}

const testing = std.testing;

test "JSON matches the documented format and round-trips" {
    const nodes = [_]Node{
        .{ .kind = .h, .level = 2, .children = &.{.{ .kind = .text, .value = "Title" }} },
        .{ .kind = .p, .children = &.{
            .{ .kind = .text, .value = "a \"quoted\" " },
            .{ .kind = .link, .url = "https://example.com", .children = &.{.{ .kind = .text, .value = "link" }} },
        } },
        .{ .kind = .code, .value = "x", .label = "zig" },
        .{ .kind = .img, .url = "https://example.com/a.png", .label = "alt" },
        .{ .kind = .list, .ordered = true, .children = &.{.{ .kind = .item, .children = &.{.{ .kind = .p, .children = &.{.{ .kind = .text, .value = "one" }} }} }} },
        .{ .kind = .table, .children = &.{.{ .kind = .row, .children = &.{.{ .kind = .cell, .children = &.{.{ .kind = .text, .value = "c" }} }} }} },
        .{ .kind = .hr },
    };
    var buffer: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeJson(&w, &nodes);
    const json = w.buffered();
    try testing.expect(std.mem.startsWith(u8, json, "[{\"t\":\"h\",\"level\":2,\"c\":[{\"t\":\"text\",\"v\":\"Title\"}]}"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseJson(arena.allocator(), json);

    var again_buffer: [2048]u8 = undefined;
    var again: std.Io.Writer = .fixed(&again_buffer);
    try writeJson(&again, parsed);
    try testing.expectEqualStrings(json, again.buffered());
}

test "invalid UTF-8 cannot corrupt the stored format" {
    const nodes = [_]Node{.{ .kind = .text, .value = "a\xFFb\"\xC3\xA9" }};
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeJson(&w, &nodes);
    try testing.expectEqualStrings("[{\"t\":\"text\",\"v\":\"a\xEF\xBF\xBDb\\\"\xC3\xA9\"}]", w.buffered());
}

test "unknown node kinds are dropped on read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const parsed = try parseJson(arena.allocator(), "[{\"t\":\"script\",\"v\":\"x\"},{\"t\":\"hr\"}]");
    try testing.expectEqual(1, parsed.len);
    try testing.expectEqual(Kind.hr, parsed[0].kind);
}

test "Markdown" {
    const nodes = [_]Node{
        .{ .kind = .h, .level = 1, .children = &.{.{ .kind = .text, .value = "T" }} },
        .{ .kind = .p, .children = &.{
            .{ .kind = .strong, .children = &.{.{ .kind = .text, .value = "b" }} },
            .{ .kind = .text, .value = " " },
            .{ .kind = .link, .url = "u", .children = &.{.{ .kind = .text, .value = "l" }} },
        } },
    };
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeMarkdown(&w, &nodes);
    try testing.expectEqualStrings("# T\n\n**b** [l](u)", w.buffered());
}
