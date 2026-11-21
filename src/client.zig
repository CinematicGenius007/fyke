//! The client side of the daemon's socket, shared by the CLI and the MCP server.

const std = @import("std");
const daemon = @import("daemon.zig");
const data_home = @import("data_home.zig");
const platform = @import("platform.zig");

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
        if (comptime platform.is_windows) return c.waitForReplyRacing();
        var fds = [_]std.c.pollfd{.{ .fd = c.stream.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
        while (true) {
            const ready = std.c.poll(&fds, fds.len, reply_timeout_ms);
            if (ready > 0) return;
            if (ready == 0) return error.DaemonTimeout;
            if (std.posix.errno(ready) != .INTR) return error.DaemonUnavailable;
        }
    }

    const Wait = union(enum) {
        ready: Io.Reader.Error!u8,
        expired: Io.Cancelable!void,
    };

    /// Windows cannot poll a socket the standard library opened, so the wait is a race:
    /// looking at the first byte of the reply against a timer. The loser is canceled.
    fn waitForReplyRacing(c: *Client) !void {
        var buffer: [2]Wait = undefined;
        var select: Io.Select(Wait) = .init(c.io, &buffer);
        try select.concurrent(.ready, Io.Reader.peekByte, .{&c.reader.interface});
        try select.concurrent(.expired, sleepFor, .{ c.io, Io.Duration.fromMilliseconds(reply_timeout_ms) });
        const first = try select.await();
        select.cancelDiscard();
        switch (first) {
            .ready => |byte| _ = byte catch return error.DaemonUnavailable,
            .expired => return error.DaemonTimeout,
        }
    }

    fn sleepFor(io: Io, duration: Io.Duration) Io.Cancelable!void {
        try io.sleep(duration, .awake);
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

    /// How a connection that finds nothing listening starts the daemon.
    pub const Start = enum {
        /// It does not, and fails with `error.DaemonNotRunning`.
        none,
        /// It starts the daemon itself, as every client does.
        daemon,
        /// It starts `fyke daemon --supervise`, which starts the daemon again after a
        /// crash (`supervise.zig`). Only `fyke service install` on Windows asks for this.
        supervised,
    };

    /// Connects, starting the daemon if nothing is listening and `autostart` is set.
    pub fn connect(k: Connector, client: *Client, autostart: bool) !void {
        return k.connectStarting(client, if (autostart) .daemon else .none);
    }

    pub fn connectStarting(k: Connector, client: *Client, start: Start) !void {
        const path = try std.fmt.allocPrint(k.arena, "{s}/{s}", .{ k.home_path, daemon.socket_name });
        const address = try Io.net.UnixAddress.init(path);

        const stream = address.connect(k.io) catch stream: {
            if (start == .none) return error.DaemonNotRunning;
            try k.startDaemon(start == .supervised);
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

    fn startDaemon(k: Connector, supervised: bool) !void {
        try data_home.ensure(k.io, k.home_path);

        const self = try std.process.executablePathAlloc(k.io, k.arena);
        // Its own process group, so that it outlives this client and any terminal. On
        // Windows it gets a console of its own that is never shown, and so does not
        // receive the Ctrl+C meant for this client.
        platform.keepStdHandlesFromChildren();
        _ = try std.process.spawn(k.io, .{
            .argv = if (supervised)
                &.{ self, "daemon", "--supervise", "--log", "--home", k.home_path }
            else
                &.{ self, "daemon", "--log" },
            .environ_map = k.environ,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = if (platform.is_windows) null else 0,
        });
    }

    /// Returns once the daemon has exited, so that what runs next starts a new one
    /// instead of reaching the one that is shutting down. The daemon's lock is the proof:
    /// the kernel releases it only when the process ends.
    pub fn waitForExit(k: Connector) !void {
        const path = try std.fmt.allocPrint(k.arena, "{s}/{s}", .{ k.home_path, daemon.lock_name });
        const lock_file = Io.Dir.cwd().openFile(k.io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer lock_file.close(k.io);
        for (0..1000) |_| {
            if (try lock_file.tryLock(k.io, .exclusive)) {
                lock_file.unlock(k.io);
                return;
            }
            try k.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.DaemonStillRunning;
    }
};
