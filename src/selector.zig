//! Validated article selections. This module has no database or clock access.
const std = @import("std");
const url = @import("url.zig");
pub const State = enum { any, unread, starred, later };
pub const Rule = struct {
    feeds: []const i64 = &.{},
    folders: []const i64 = &.{},
    state: State = .any,
    words: ?[]const u8 = null,
    any_words: bool = false,
    host: ?[]const u8 = null,
    subdomains: bool = false,
    path_prefix: ?[]const u8 = null,
    exclude_path_prefix: []const []const u8 = &.{},
    within_days: ?i64 = null,
};
pub const Name = struct { id: i64, name: []const u8 };
pub fn parse(a: std.mem.Allocator, text: []const u8) !Rule {
    if (text.len > 16384) return error.InvalidRule;
    var r = std.json.parseFromSliceLeaky(Rule, a, text, .{}) catch return error.InvalidRule;
    for ([_][]const i64{ r.feeds, r.folders }) |ids| {
        if (ids.len > 64) return error.InvalidRule;
        for (ids) |id| if (id <= 0) return error.InvalidRule;
    }
    if (r.words) |w| if (std.mem.trim(u8, w, " \t\n\r").len == 0 or w.len > 200) return error.InvalidRule;
    if (r.within_days) |days| if (days < 1 or days > 3650) return error.InvalidRule;
    if (r.host) |host| {
        if (host.len == 0 or host.len > 253) return error.InvalidRule;
        for (host) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return error.InvalidRule;
        if (host[0] == '.' or host[host.len - 1] == '.' or std.mem.indexOf(u8, host, "..") != null) return error.InvalidRule;
        const lower = try a.dupe(u8, host);
        for (lower) |*c| c.* = std.ascii.toLower(c.*);
        r.host = lower;
    }
    if (r.path_prefix) |p| r.path_prefix = try path(a, p);
    if (r.exclude_path_prefix.len > 64) return error.InvalidRule;
    const excluded = try a.alloc([]const u8, r.exclude_path_prefix.len);
    for (r.exclude_path_prefix, 0..) |p, i| excluded[i] = try path(a, p);
    r.exclude_path_prefix = excluded;
    return r;
}
fn path(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len == 0 or p.len > 2048 or p[0] != '/' or std.mem.indexOfAny(u8, p, "?#\r\n\x00") != null or std.mem.startsWith(u8, p, "//")) return error.InvalidRule;
    const normalized = url.split(try url.resolve(a, "https://selector.invalid/", p)).path;
    return if (normalized.len > 1) std.mem.trimEnd(u8, normalized, "/") else "/";
}
pub fn pathMatches(p: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, prefix, "/") or (std.mem.startsWith(u8, p, prefix) and (p.len == prefix.len or p[prefix.len] == '/'));
}
pub fn addressMatches(a: std.mem.Allocator, r: Rule, address: ?[]const u8) !bool {
    if (r.host == null and r.path_prefix == null and r.exclude_path_prefix.len == 0) return true;
    const value = address orelse return false;
    if (!url.isHttp(value)) return false;
    const parts = url.split(try url.resolve(a, value, url.split(value).path));
    var host = parts.authority orelse return false;
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (r.host) |wanted| {
        const exact = std.ascii.eqlIgnoreCase(host, wanted);
        const sub = r.subdomains and host.len > wanted.len and host[host.len - wanted.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - wanted.len ..], wanted);
        if (!exact and !sub) return false;
    }
    const p = if (parts.path.len == 0) "/" else parts.path;
    if (r.path_prefix) |prefix| if (!pathMatches(p, prefix)) return false;
    for (r.exclude_path_prefix) |prefix| if (pathMatches(p, prefix)) return false;
    return true;
}
/// Each word is a quoted FTS phrase. Punctuation cannot become an operator.
pub fn fts(a: std.mem.Allocator, r: Rule) !?[]const u8 {
    const words = r.words orelse return null;
    var out: std.Io.Writer.Allocating = .init(a);
    var tokens = std.mem.tokenizeAny(u8, words, " \t\r\n");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try out.writer.writeAll(if (r.any_words) " OR " else " AND ");
        first = false;
        try out.writer.writeByte('"');
        for (token) |c| {
            try out.writer.writeByte(c);
            if (c == '"') try out.writer.writeByte(c);
        }
        try out.writer.writeByte('"');
    }
    return out.written();
}
pub fn sentence(a: std.mem.Allocator, r: Rule, feeds: []const Name, folders: []const Name) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll(switch (r.state) {
        .any => "Articles",
        .unread => "Unread",
        .starred => "Starred",
        .later => "Later",
    });
    var first = true;
    for ([_][]const i64{ r.feeds, r.folders }, [_][]const Name{ feeds, folders }) |ids, names| for (ids) |id| {
        try out.writer.writeAll(if (first) " from " else ", ");
        first = false;
        const name = for (names) |n| {
            if (n.id == id) break n.name;
        } else "Deleted source";
        try out.writer.writeAll(name);
    };
    if (r.words) |w| try out.writer.print(" about {s}{s}", .{ w, if (r.any_words) " (any word)" else "" });
    if (r.host) |h| try out.writer.print(" on {s}{s}", .{ h, if (r.subdomains) " and subdomains" else "" });
    if (r.path_prefix) |p| try out.writer.print(" under {s}", .{p});
    for (r.exclude_path_prefix) |p| try out.writer.print(" excluding {s}", .{p});
    if (r.within_days) |d| try out.writer.print(", last {d} days", .{d});
    try out.writer.writeByte('.');
    return out.written();
}
test "rules reject hostile and unbounded fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "null", "[]", "{\"x\":1}", "{\"feeds\":[0]}", "{\"state\":\"bad\"}", "{\"within_days\":0}", "{\"words\":\" \"}", "{\"host\":\"a/b\"}", "{\"path_prefix\":\"//evil\"}" }) |bad| try std.testing.expectError(error.InvalidRule, parse(a, bad));
    const r = try parse(a, "{\"host\":\"Example.COM\",\"subdomains\":true,\"path_prefix\":\"/a/../blog/\",\"exclude_path_prefix\":[\"/blog/jobs/\"]}");
    try std.testing.expect(try addressMatches(a, r, "https://x.example.com/blog/post?q=1"));
    for ([_]?[]const u8{ null, "https://evil-example.com/blog", "https://example.com/blogger", "https://example.com/blog/jobs/x" }) |v| try std.testing.expect(!try addressMatches(a, r, v));
    try std.testing.expectEqualStrings("Unread from Engineering about storage engine, last 7 days.", try sentence(a, try parse(a, "{\"state\":\"unread\",\"folders\":[2],\"words\":\"storage engine\",\"within_days\":7}"), &.{}, &.{.{ .id = 2, .name = "Engineering" }}));
    try std.testing.expectEqualStrings("\"a\" AND \"OR\" AND \"b*\" AND \"\"\"x\"\"\"", (try fts(a, .{ .words = "a OR b* \"x\"" })).?);
}
