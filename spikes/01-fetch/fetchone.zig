//! Spike: one conditional GET with std.http.Client, printed as one JSON line.
//! Usage: fetchone <url> [etag] [last-modified]    (pass "" to skip a validator)
const std = @import("std");

const max_redirects = 5;
const max_body = 32 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingUrl;

    var headers: std.ArrayList(std.http.Header) = .empty;
    if (args.len > 2 and args[2].len > 0) try headers.append(arena, .{ .name = "if-none-match", .value = args[2] });
    if (args.len > 3 and args[3].len > 0) try headers.append(arena, .{ .name = "if-modified-since", .value = args[3] });

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;

    var uri = try std.Uri.parse(args[1]);
    var hops: u8 = 0;
    var permanent = true; // true only when every hop was 301 or 308
    while (true) {
        var req = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = "rss_-spike/0.1 (feed reader prototype)" } },
            .extra_headers = headers.items,
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});

        if (response.head.status.class() == .redirect and response.head.status != .not_modified) {
            if (hops == max_redirects) return error.TooManyRedirects;
            hops += 1;
            if (response.head.status != .moved_permanently and response.head.status != .permanent_redirect) permanent = false;
            const location = response.head.location orelse return error.RedirectWithoutLocation;
            const aux = try arena.alloc(u8, location.len + 8192);
            @memcpy(aux[0..location.len], location);
            var rest = aux;
            uri = try uri.resolveInPlace(location.len, &rest);
            continue;
        }

        var etag: []const u8 = "";
        var last_modified: []const u8 = "";
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "etag")) etag = try arena.dupe(u8, h.value);
            if (std.ascii.eqlIgnoreCase(h.name, "last-modified")) last_modified = try arena.dupe(u8, h.value);
        }
        const status = @intFromEnum(response.head.status);
        const encoding = @tagName(response.head.content_encoding);

        // A 304 has no body, but may still claim content-encoding: gzip.
        if (response.head.status == .not_modified) {
            try w.print("{f}\n", .{std.json.fmt(.{ .status = status, .hops = hops, .permanent = hops > 0 and permanent, .encoding = encoding, .etag = etag, .last_modified = last_modified, .bytes = 0 }, .{})});
            try w.flush();
            return;
        }

        const decompress_buffer = try arena.alloc(u8, @max(std.compress.flate.max_window_len, std.compress.zstd.default_window_len));
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        const body = reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.BodyDecodeFailed,
            else => |e| return e,
        };

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
        try w.print("{f}\n", .{std.json.fmt(.{
            .status = status,
            .hops = hops,
            .permanent = hops > 0 and permanent,
            .encoding = encoding,
            .etag = etag,
            .last_modified = last_modified,
            .bytes = body.len,
            .sha256 = std.fmt.bytesToHex(hash, .lower),
            .head = body[0..@min(body.len, 48)],
        }, .{})});
        try w.flush();
        return;
    }
}
