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
    accept: []const u8 = feed_accept,
};

const feed_accept = "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, */*;q=0.8";

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

/// Fetches with a hard deadline. The client must use `withCancelableConnect`, or a
/// host that never answers holds this call until the OS gives up.
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

var connect_vtable: Io.VTable = undefined;

/// How often a connect in progress checks whether it was canceled.
const connect_poll_ms = 200;

/// Returns `io` with a TCP connect that can be canceled. The standard library's
/// blocks in `connect(2)`, and `http.Client` offers no way to supply a socket, so
/// the replacement goes in through the `Io` interface. Call this once, at startup.
pub fn withCancelableConnect(io: Io) Io {
    connect_vtable = io.vtable.*;
    connect_vtable.netConnectIp = connectIp;
    return .{ .userdata = io.userdata, .vtable = &connect_vtable };
}

fn connectIp(userdata: ?*anyopaque, address: *const Io.net.IpAddress, _: Io.net.IpAddress.ConnectOptions) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const io: Io = .{ .userdata = userdata, .vtable = &connect_vtable };
    const c = std.c;
    var storage: extern union { any: c.sockaddr, in: c.sockaddr.in, in6: c.sockaddr.in6 } = undefined;
    var length: c.socklen_t = undefined;
    switch (address.*) {
        .ip4 => |ip| {
            storage = .{ .in = .{ .port = std.mem.nativeToBig(u16, ip.port), .addr = @bitCast(ip.bytes) } };
            length = @sizeOf(c.sockaddr.in);
        },
        .ip6 => |ip| {
            storage = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, ip.port), .flowinfo = ip.flow, .addr = ip.bytes, .scope_id = ip.interface.index } };
            length = @sizeOf(c.sockaddr.in6);
        },
    }

    const fd = c.socket(storage.any.family, c.SOCK.STREAM, 0);
    if (fd < 0) return connectError(std.posix.errno(fd));
    errdefer _ = c.close(fd);
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const blocking = c.fcntl(fd, c.F.GETFL);
    _ = c.fcntl(fd, c.F.SETFL, blocking | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));

    const result = c.connect(fd, &storage.any, length);
    if (result != 0) {
        const code = std.posix.errno(result);
        if (code != .INPROGRESS) return connectError(code);
        try waitConnected(io, fd);
    }
    _ = c.fcntl(fd, c.F.SETFL, blocking);
    return .{ .handle = fd, .address = address.* };
}

fn waitConnected(io: Io, fd: std.c.fd_t) Io.net.IpAddress.ConnectError!void {
    const c = std.c;
    while (true) {
        try io.checkCancel();
        var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.OUT, .revents = 0 }};
        const ready = c.poll(&fds, fds.len, connect_poll_ms);
        if (ready > 0) break;
        if (ready < 0 and std.posix.errno(ready) != .INTR) return error.Unexpected;
    }
    var failure: c_int = 0;
    var size: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, &failure, &size) != 0) return error.Unexpected;
    if (failure != 0) return connectError(@fromBackingInt(@intCast(failure)));
}

fn connectError(code: std.posix.E) Io.net.IpAddress.ConnectError {
    return switch (code) {
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .AFNOSUPPORT => error.AddressFamilyUnsupported,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .NETDOWN => error.NetworkDown,
        else => error.Unexpected,
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
        extra[extra_len] = .{ .name = "accept", .value = request.accept };
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
        repairHead(req.reader.in);
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

/// Reads the whole response head into the buffer and repairs it there, ahead of the
/// standard library's parser. Read errors are left for that parser to report.
fn repairHead(in: *Io.Reader) void {
    while (true) {
        const bytes = in.buffered();
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse std.mem.indexOf(u8, bytes, "\n\n");
        if (end) |length| return maskFalseEncoding(bytes[0..length]);
        if (bytes.len == in.buffer.len) return;
        in.fillMore() catch return;
    }
}

/// `content-encoding: none` is not a real coding, but servers do send it, and the
/// standard library then rejects the whole response. It means no coding at all, so
/// the header is renamed to one that nothing reads.
fn maskFalseEncoding(head: []u8) void {
    const name = "content-encoding:";
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        if (line.len < name.len or !std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        const value = std.mem.trim(u8, line[name.len..], " \t\r");
        if (!std.ascii.eqlIgnoreCase(value, "none")) continue;
        const start = @intFromPtr(line.ptr) - @intFromPtr(head.ptr);
        head[start] = 'x';
    }
}

test "a false content-encoding is masked, and a real one kept" {
    var head = "HTTP/1.1 200 OK\r\nContent-Encoding: none\r\nX: y".*;
    maskFalseEncoding(&head);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\nxontent-Encoding: none\r\nX: y", &head);

    var real = "HTTP/1.1 200 OK\r\ncontent-encoding: gzip".*;
    maskFalseEncoding(&real);
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\ncontent-encoding: gzip", &real);
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
