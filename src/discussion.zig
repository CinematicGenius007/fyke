//! Comment threads that live beside an entry. Hacker News is the one source read in
//! full: its threads come from the Algolia API as one JSON tree, which this file turns
//! into a flat list in reading order, each comment's HTML converted to blocks.

const std = @import("std");
const blocks = @import("blocks.zig");
const html = @import("html.zig");
const url = @import("url.zig");

pub const hacker_news_host = "news.ycombinator.com";

/// Threads larger than this are cut, and the result says so.
pub const max_comments = 2000;

/// Deeper replies are kept, and shown at this depth.
pub const max_depth = 32;

/// The item number of a Hacker News discussion page, as in
/// `https://news.ycombinator.com/item?id=123`.
pub fn hackerNewsId(address: []const u8) ?u64 {
    if (!url.isHttp(address)) return null;
    const parts = url.split(address);
    if (!std.ascii.eqlIgnoreCase(parts.authority orelse return null, hacker_news_host)) return null;
    if (!std.mem.eql(u8, parts.path, "/item")) return null;
    var pairs = std.mem.splitScalar(u8, parts.query orelse return null, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "id=")) return std.fmt.parseInt(u64, pair[3..], 10) catch null;
    }
    return null;
}

/// The first link in `nodes` to a Hacker News discussion. Its feed puts the thread
/// in the body as a "Comments" link, which entries stored before the address was
/// kept still carry.
pub fn findHackerNewsLink(nodes: []const blocks.Node) ?[]const u8 {
    for (nodes) |node| {
        if (node.kind == .link and hackerNewsId(node.url) != null) return node.url;
        if (findHackerNewsLink(node.children)) |found| return found;
    }
    return null;
}

pub const Comment = struct {
    id: u64,
    /// Null for a comment that was deleted, which stays so its replies keep their place.
    author: ?[]const u8,
    /// Milliseconds since the epoch.
    at: ?i64,
    depth: u16,
    blocks_json: []const u8,
};

pub const Thread = struct {
    comments: []const Comment,
    truncated: bool,
};

const Walk = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(Comment) = .empty,
    truncated: bool = false,

    fn children(w: *Walk, item: std.json.Value, depth: u16) error{OutOfMemory}!void {
        if (item != .object) return;
        const list = item.object.get("children") orelse return;
        if (list != .array) return;
        for (list.array.items) |child| {
            if (w.out.items.len == max_comments) {
                w.truncated = true;
                return;
            }
            try w.comment(child, depth);
        }
    }

    fn comment(w: *Walk, item: std.json.Value, depth: u16) error{OutOfMemory}!void {
        if (item != .object) return;
        const fields = item.object;
        // Polls list their options as children, which are not replies.
        if (string(fields.get("type"))) |kind| if (!std.mem.eql(u8, kind, "comment")) return;
        const id = integer(fields.get("id")) orelse return;
        const text = string(fields.get("text")) orelse "";
        var json: std.Io.Writer.Allocating = .init(w.arena);
        const nodes = try html.toBlocks(w.arena, text, .{ .base = "https://" ++ hacker_news_host ++ "/" });
        blocks.writeJson(&json.writer, nodes) catch return error.OutOfMemory;
        try w.out.append(w.arena, .{
            .id = @intCast(@max(id, 0)),
            .author = string(fields.get("author")),
            .at = if (integer(fields.get("created_at_i"))) |seconds| seconds *| 1000 else null,
            .depth = depth,
            .blocks_json = json.written(),
        });
        try w.children(item, @min(depth + 1, max_depth));
    }

    fn string(value: ?std.json.Value) ?[]const u8 {
        const v = value orelse return null;
        return if (v == .string) v.string else null;
    }

    fn integer(value: ?std.json.Value) ?i64 {
        const v = value orelse return null;
        return if (v == .integer) v.integer else null;
    }
};

/// Reads an Algolia item: the story, whose children are the top-level comments.
pub fn parseHackerNews(arena: std.mem.Allocator, json: []const u8) error{ OutOfMemory, InvalidThread }!Thread {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidThread,
    };
    if (root != .object) return error.InvalidThread;
    var walk: Walk = .{ .arena = arena };
    try walk.children(root, 0);
    return .{ .comments = walk.out.items, .truncated = walk.truncated };
}

const testing = std.testing;

test "Hacker News addresses" {
    try testing.expectEqual(46_001, hackerNewsId("https://news.ycombinator.com/item?id=46001").?);
    try testing.expectEqual(7, hackerNewsId("http://NEWS.ycombinator.com/item?p=2&id=7").?);
    try testing.expectEqual(null, hackerNewsId("https://news.ycombinator.com/user?id=pg"));
    try testing.expectEqual(null, hackerNewsId("https://news.ycombinator.com.evil.example/item?id=1"));
    try testing.expectEqual(null, hackerNewsId("https://news.ycombinator.com/item?id=x"));
    try testing.expectEqual(null, hackerNewsId("javascript:news.ycombinator.com/item?id=1"));
}

test "the comments link in a body" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const nodes = try html.toBlocks(arena.allocator(), "<p>Article URL: <a href=\"https://example.com/\">x</a></p><a href=\"https://news.ycombinator.com/item?id=9\">Comments</a>", .{});
    try testing.expectEqualStrings("https://news.ycombinator.com/item?id=9", findHackerNewsLink(nodes).?);
    try testing.expectEqual(null, findHackerNewsLink(try html.toBlocks(arena.allocator(), "<p>None</p>", .{})));
}

test "a thread in reading order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const thread = try parseHackerNews(arena.allocator(),
        \\{"id":1,"type":"story","text":null,"children":[
        \\  {"id":2,"type":"comment","author":"ann","created_at_i":1700000000,"text":"<p>First <a href=\"item?id=3\">link</a>","children":[
        \\    {"id":3,"type":"comment","author":null,"text":null,"children":[
        \\      {"id":4,"type":"comment","author":"bo","text":"<i>reply</i>","children":[]}]}]},
        \\  {"id":5,"type":"pollopt","text":"Yes","children":[]},
        \\  {"id":6,"type":"comment","author":"cy","text":"Second","children":[]}]}
    );
    try testing.expect(!thread.truncated);
    try testing.expectEqual(4, thread.comments.len);
    const ids = [_]u64{ 2, 3, 4, 6 };
    const depths = [_]u16{ 0, 1, 2, 0 };
    for (thread.comments, ids, depths) |comment, id, depth| {
        try testing.expectEqual(id, comment.id);
        try testing.expectEqual(depth, comment.depth);
    }
    try testing.expectEqualStrings("ann", thread.comments[0].author.?);
    try testing.expectEqual(1_700_000_000_000, thread.comments[0].at.?);
    try testing.expect(std.mem.indexOf(u8, thread.comments[0].blocks_json, "https://news.ycombinator.com/item?id=3") != null);
    try testing.expectEqual(null, thread.comments[1].author);
    try testing.expectEqualStrings("[]", thread.comments[1].blocks_json);
    try testing.expectError(error.InvalidThread, parseHackerNews(arena.allocator(), "[1]"));
    try testing.expectError(error.InvalidThread, parseHackerNews(arena.allocator(), "not json"));
}
