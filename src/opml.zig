//! Reads OPML subscription lists, so that adopting this reader is one import.

const std = @import("std");
const xml = @import("xml.zig");

pub const Error = error{ OutOfMemory, NotOpml, TooDeep };

/// Folders link to their parents, so deep nesting costs one node per folder
/// rather than a copied path per subscription.
pub const Folder = struct {
    name: []const u8,
    parent: ?*const Folder,
};

pub const Subscription = struct {
    url: []const u8,
    title: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    folder: ?*const Folder = null,
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) Error![]const Subscription {
    var p: xml.Parser = .init(text);
    var subscriptions: std.ArrayList(Subscription) = .empty;
    var seen_root = false;

    // folders[d] is the folder in effect at element depth d.
    var folders: [xml.max_depth + 1]?*const Folder = @splat(null);

    while (true) {
        switch (try p.next()) {
            .eof => break,
            .start => |start| {
                if (!seen_root) {
                    if (!std.ascii.eqlIgnoreCase(start.name.local, "opml")) return error.NotOpml;
                    seen_root = true;
                    continue;
                }
                const parent = folders[p.depth - 1];
                folders[p.depth] = parent;
                if (!std.ascii.eqlIgnoreCase(start.name.local, "outline")) continue;

                const title = try attr(arena, start, "title") orelse try attr(arena, start, "text");
                if (try attr(arena, start, "xmlUrl") orelse try attr(arena, start, "xmlurl")) |url| {
                    try subscriptions.append(arena, .{
                        .url = url,
                        .title = title,
                        .site_url = try attr(arena, start, "htmlUrl"),
                        .folder = parent,
                    });
                } else if (title) |name| {
                    const folder = try arena.create(Folder);
                    folder.* = .{ .name = name, .parent = parent };
                    folders[p.depth] = folder;
                }
            },
            else => {},
        }
    }
    if (!seen_root) return error.NotOpml;
    return subscriptions.items;
}

fn attr(arena: std.mem.Allocator, start: xml.Start, name: []const u8) error{OutOfMemory}!?[]const u8 {
    const raw = start.attribute(name) orelse return null;
    const value = std.mem.trim(u8, try xml.decodeText(arena, raw), " \t\r\n");
    return if (value.len == 0) null else value;
}

pub const Outline = struct {
    title: []const u8,
    /// Empty for a folder.
    url: []const u8 = "",
    site_url: ?[]const u8 = null,
    children: []const Outline = &.{},
};

/// Writes an OPML 2.0 document.
pub fn write(w: *std.Io.Writer, title: []const u8, outlines: []const Outline) std.Io.Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n<head><title>");
    try writeEscaped(w, title);
    try w.writeAll("</title></head>\n<body>\n");
    try writeOutlines(w, outlines, 1);
    try w.writeAll("</body>\n</opml>\n");
}

fn writeOutlines(w: *std.Io.Writer, outlines: []const Outline, depth: usize) std.Io.Writer.Error!void {
    for (outlines) |outline| {
        for (0..depth) |_| try w.writeAll("  ");
        try w.writeAll("<outline text=\"");
        try writeEscaped(w, outline.title);
        try w.writeByte('"');
        if (outline.url.len != 0) {
            try w.writeAll(" type=\"rss\" xmlUrl=\"");
            try writeEscaped(w, outline.url);
            try w.writeByte('"');
            if (outline.site_url) |site| {
                try w.writeAll(" htmlUrl=\"");
                try writeEscaped(w, site);
                try w.writeByte('"');
            }
        }
        if (outline.children.len == 0) {
            try w.writeAll("/>\n");
            continue;
        }
        try w.writeAll(">\n");
        try writeOutlines(w, outline.children, depth + 1);
        for (0..depth) |_| try w.writeAll("  ");
        try w.writeAll("</outline>\n");
    }
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => if (c >= 0x20) try w.writeByte(c),
        }
    }
}

const testing = std.testing;

test "subscriptions and nested folders" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<opml version="2.0"><head><title>Mine</title></head><body>
        \\  <outline text="Tech">
        \\    <outline text="Zig">
        \\      <outline text="News" type="rss" xmlUrl="https://example.com/a?x=1&amp;y=2" htmlUrl="https://example.com/"/>
        \\    </outline>
        \\    <outline title="Other" xmlUrl="https://example.com/b"/>
        \\  </outline>
        \\  <outline text="Top" xmlUrl="https://example.com/c"/>
        \\</body></opml>
    );
    try testing.expectEqual(3, list.len);
    try testing.expectEqualStrings("https://example.com/a?x=1&y=2", list[0].url);
    try testing.expectEqualStrings("News", list[0].title.?);
    try testing.expectEqualStrings("Zig", list[0].folder.?.name);
    try testing.expectEqualStrings("Tech", list[0].folder.?.parent.?.name);
    try testing.expectEqualStrings("Tech", list[1].folder.?.name);
    try testing.expectEqual(null, list[2].folder);
}

test "other documents are refused" {
    try testing.expectError(error.NotOpml, parse(testing.allocator, "<rss/>"));
    try testing.expectError(error.NotOpml, parse(testing.allocator, ""));
}

test "written documents read back the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inner = [_]Outline{.{ .title = "A & \"B\" <c>", .url = "https://example.com/a?x=1&y=2", .site_url = "https://example.com/" }};
    const outlines = [_]Outline{
        .{ .title = "Tech", .children = &inner },
        .{ .title = "Top", .url = "https://example.com/b" },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    try write(&out.writer, "Mine", &outlines);

    const list = try parse(a, out.written());
    try testing.expectEqual(2, list.len);
    try testing.expectEqualStrings("A & \"B\" <c>", list[0].title.?);
    try testing.expectEqualStrings("https://example.com/a?x=1&y=2", list[0].url);
    try testing.expectEqualStrings("https://example.com/", list[0].site_url.?);
    try testing.expectEqualStrings("Tech", list[0].folder.?.name);
    try testing.expectEqual(null, list[1].folder);
}
