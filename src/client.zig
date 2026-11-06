//! The client side of the daemon's socket, shared by the CLI and the MCP server.

const std = @import("std");
const daemon = @import("daemon.zig");
const data_home = @import("data_home.zig");

const Io = std.Io;

/// How long a call waits for the daemon's first byte. The slowest operations wait
/// on the network, and `pipeline.discovery_budget_ms` keeps them well within this.
const reply_timeout_ms = 120 * 1000;

/// One connection to the daemon.
pub const Client = struct {
    io: Io,
    arena: std.mem.Allocator,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    /// Why the last call returned error.Reported.
    last_error: []const u8 = "",
    in_buffer: [64 * 1024]u8 = undefined,
    out_buffer: [16 * 1024]u8 = undefined,

    /// Sends a request and returns the raw response line.
    pub fn send(c: *Client, method: []const u8, params: anytype) ![]const u8 {
        const out = &c.writer.interface;
        try out.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{f}}}\n", .{ method, std.json.fmt(params, .{}) });
        try out.flush();

        var line: Io.Writer.Allocating = .init(c.arena);
        const in = &c.reader.interface;
        if (in.bufferedLen() == 0) try c.waitForReply();
        _ = try in.streamDelimiter(&line.writer, '\n');
        in.toss(1);
        return line.written();
    }

    /// A daemon that stopped answering must surface as an error, not as a hang.
    fn waitForReply(c: *Client) !void {
        var fds = [_]std.c.pollfd{.{ .fd = c.stream.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
        while (true) {
            const ready = std.c.poll(&fds, fds.len, reply_timeout_ms);
            if (ready > 0) return;
            if (ready == 0) return error.DaemonTimeout;
            if (std.posix.errno(ready) != .INTR) return error.DaemonUnavailable;
        }
    }

    /// Calls an operation and returns its typed result.
    pub fn call(c: *Client, comptime Op: type, params: Op.Params) !Op.Result {
        const line = try c.send(Op.name, params);
        const Response = struct { result: ?Op.Result = null, @"error": ?RpcError = null };
        const response = try std.json.parseFromSliceLeaky(Response, c.arena, line, .{ .ignore_unknown_fields = true });
        if (response.@"error") |failure| return c.fail(failure);
        return response.result orelse error.BadResponse;
    }

    /// Calls an operation and returns just its `result`, as JSON text.
    pub fn callRaw(c: *Client, comptime Op: type, params: Op.Params) ![]const u8 {
        const line = try c.send(Op.name, params);
        const response = try std.json.parseFromSliceLeaky(std.json.Value, c.arena, line, .{});
        if (response.object.get("error")) |failure| {
            return c.fail(try std.json.parseFromValueLeaky(RpcError, c.arena, failure, .{ .ignore_unknown_fields = true }));
        }
        return std.fmt.allocPrint(c.arena, "{f}", .{std.json.fmt(response.object.get("result") orelse .null, .{})});
    }

    fn fail(c: *Client, failure: RpcError) anyerror {
        c.last_error = failure.message;
        return error.Reported;
    }
};

pub const RpcError = struct { code: i64, message: []const u8 };

/// How to reach the daemon, kept so that a dropped connection can be reopened.
pub const Connector = struct {
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    home_path: []const u8,

    /// Connects, starting the daemon if nothing is listening and `autostart` is set.
    pub fn connect(k: Connector, client: *Client, autostart: bool) !void {
        const path = try std.fmt.allocPrint(k.arena, "{s}/{s}", .{ k.home_path, daemon.socket_name });
        const address = try Io.net.UnixAddress.init(path);

        const stream = address.connect(k.io) catch stream: {
            if (!autostart) return error.DaemonNotRunning;
            try k.startDaemon();
            var attempts: usize = 0;
            while (true) : (attempts += 1) {
                break :stream address.connect(k.io) catch |err| {
                    if (attempts == 300) return err;
                    try k.io.sleep(.fromMilliseconds(10), .awake);
                    continue;
                };
            }
        };
        client.* = .{ .io = k.io, .arena = k.arena, .stream = stream, .reader = undefined, .writer = undefined };
        client.reader = stream.reader(k.io, &client.in_buffer);
        client.writer = stream.writer(k.io, &client.out_buffer);
    }

    fn startDaemon(k: Connector) !void {
        try data_home.ensure(k.io, k.home_path);

        const self = try std.process.executablePathAlloc(k.io, k.arena);
        // Its own process group, so that it outlives this client and any terminal.
        _ = try std.process.spawn(k.io, .{
            .argv = &.{ self, "daemon", "--log" },
            .environ_map = k.environ,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
    }
};
