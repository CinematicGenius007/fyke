//! HTTP for feeds: conditional requests, redirects with their permanence
//! recorded, hard deadlines and the guard against reaching private addresses.
//!
//! Redirects are followed here rather than by the client, so that every hop goes
//! through the same address check and so that 301 and 302 can be told apart.

const std = @import("std");
const core = @import("core");

const Io = std.Io;
const http = std.http;
const url = core.url;

const max_redirects = 5;
const max_body = 32 * 1024 * 1024;

/// Sent with every request. Publishers read this to see who is polling them.
pub const user_agent = "rss_/0.1 (feed reader)";

pub const Request = struct {
    url: []const u8,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    allow_private_network: bool = false,
    deadline_seconds: i64 = 30,
};

pub const Response = struct {
    status: u16,
    /// URL after redirects, and whether every hop to it was permanent.
    final_url: []const u8,
    moved_permanently: bool = false,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    retry_after_seconds: ?u32 = null,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const Error = error{ DeadlineExceeded, PrivateAddress, NotHttp, TooManyRedirects } || anyerror;

const Race = union(enum) {
    fetched: anyerror!Response,
    expired: Io.Cancelable!void,
};

/// Fetches with a hard deadline. TCP connect cannot yet be canceled in Zig 0.17,
/// so a host that never answers can hold this call until the OS gives up.
pub fn fetch(client: *http.Client, arena: std.mem.Allocator, request: Request) Error!Response {
    const io = client.io;
    var buffer: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buffer);
    try select.concurrent(.fetched, fetchHops, .{ client, arena, request });
    try select.concurrent(.expired, sleep, .{ io, Io.Duration.fromSeconds(request.deadline_seconds) });
    const first = try select.await();
    select.cancelDiscard();
    return switch (first) {
        .fetched => |result| result,
        .expired => error.DeadlineExceeded,
    };
}

fn sleep(io: Io, duration: Io.Duration) Io.Cancelable!void {
    try io.sleep(duration, .awake);
}

fn fetchHops(client: *http.Client, arena: std.mem.Allocator, request: Request) anyerror!Response {
    var current = request.url;
    var permanent = true;
    var hops: u8 = 0;
    while (true) {
        if (!url.isHttp(current)) return error.NotHttp;
        const uri = try std.Uri.parse(current);
        const protocol = http.Client.Protocol.fromUri(uri) orelse return error.NotHttp;

        var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
        const host = try Io.net.HostName.fromUri(uri, &host_buffer);
        const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
        if (protocol == .tls) try loadCertificates(client);
        const connection = try client.connect(host, port, protocol);

        // Checking the connected socket, rather than a DNS answer, means a name
        // cannot resolve to something public for the check and private for the
        // connection. Nothing has been sent yet at this point.
        if (!request.allow_private_network and !isPublicPeer(connection)) {
            connection.closing = true;
            client.connection_pool.release(connection, client.io);
            return error.PrivateAddress;
        }

        var extra: [3]http.Header = undefined;
        var extra_len: usize = 0;
        extra[extra_len] = .{ .name = "accept", .value = "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.8" };
        extra_len += 1;
        if (hops == 0) {
            if (request.etag) |value| {
                extra[extra_len] = .{ .name = "if-none-match", .value = value };
                extra_len += 1;
            }
            if (request.last_modified) |value| {
                extra[extra_len] = .{ .name = "if-modified-since", .value = value };
                extra_len += 1;
            }
        }

        var req = try client.request(.GET, uri, .{
            .connection = connection,
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .user_agent = .{ .override = user_agent } },
            .extra_headers = extra[0..extra_len],
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        const status = response.head.status;

        if (status.class() == .redirect and status != .not_modified) {
            if (hops == max_redirects) return error.TooManyRedirects;
            hops += 1;
            if (status != .moved_permanently and status != .permanent_redirect) permanent = false;
            const location = response.head.location orelse return error.RedirectWithoutLocation;
            current = try url.resolve(arena, current, try arena.dupe(u8, location));
            continue;
        }

        var result: Response = .{
            .status = @backingInt(status),
            .final_url = current,
            .moved_permanently = hops > 0 and permanent,
        };
        var headers = response.head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                result.etag = try arena.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                result.last_modified = try arena.dupe(u8, header.value);
            } else if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                result.retry_after_seconds = std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " "), 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                result.content_type = try arena.dupe(u8, header.value);
            }
        }

        // A 304 has no body even when it claims content-encoding: gzip, and error
        // pages are of no use.
        if (status != .ok) return result;

        const window = @max(std.compress.flate.max_window_len, std.compress.zstd.default_window_len);
        const decompress_buffer = try arena.alloc(u8, window);
        var transfer_buffer: [4096]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        result.body = reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.BodyDecodeFailed,
            else => |e| return e,
        };
        return result;
    }
}

/// `client.request` loads the system's certificates itself, but connecting first,
/// which the address check needs, skips that step. Certificates must be present
/// before any TLS handshake.
fn loadCertificates(client: *http.Client) !void {
    const io = client.io;
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    if (client.now != null) return;
    const now = Io.Clock.real.now(io);
    try client.ca_bundle.rescan(client.allocator, io, now);
    client.now = now;
}

fn isPublicPeer(connection: *http.Client.Connection) bool {
    const fd = connection.stream_reader.stream.socket.handle;
    var storage: [128]u8 align(8) = undefined;
    var length: std.posix.socklen_t = storage.len;
    const address: *std.posix.sockaddr = @ptrCast(&storage);
    std.posix.getpeername(fd, address, &length) catch return false;
    return switch (address.family) {
        std.posix.AF.INET => {
            const ip4: *const std.posix.sockaddr.in = @ptrCast(&storage);
            return url.isPublicIp4(std.mem.asBytes(&ip4.addr).*);
        },
        std.posix.AF.INET6 => {
            const ip6: *const std.posix.sockaddr.in6 = @ptrCast(&storage);
            return url.isPublicIp6(ip6.addr);
        },
        else => false,
    };
}
