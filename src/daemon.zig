//! `fyke daemon`: owns the database and serves the operation registry on a Unix
//! socket, as newline-delimited JSON-RPC 2.0. See docs/api.md ("Socket protocol").

const std = @import("std");
const fetch = @import("fetch.zig");
const ops = @import("ops.zig");
const data_home = @import("data_home.zig");
const platform = @import("platform.zig");
const service = @import("service.zig");
const store = @import("store.zig");

const Io = std.Io;
const Service = service.Service;

/// Longest accepted request line.
const max_request = 1 << 20;
/// A subscriber with nothing new still checks this often, in case a signal raced.
const subscribe_poll_ms = 5000;

pub const socket_name = "fyked.sock";

pub const Options = struct {
    /// Log to `fyked.log` in place of stderr, for a daemon started in the background.
    log_to_file: bool = false,
};

const code_parse = -32700;
const code_invalid_request = -32600;
const code_unknown_method = -32601;
const code_invalid_params = -32602;
const code_failed = -32000;
const code_tier_denied = -32001;

/// Sends this process's stderr to `fyked.log`, emptied first. Only the lock holder
/// may do this, or a client that lost the race to start a daemon would erase the log.
fn redirectLog(io: Io, home: Io.Dir) !void {
    const log = try home.createFile(io, "fyked.log", .{});
    try platform.redirectStderr(log);
    // `dup2` copies the file, so the original can go. Windows makes the handle itself
    // the standard error, so it stays open until the process ends.
    if (!platform.is_windows) log.close(io);
}

pub fn run(gpa: std.mem.Allocator, io: Io, home_path: []const u8, arena: std.mem.Allocator, options: Options) !void {
    const cwd = Io.Dir.cwd();
    try data_home.ensure(io, home_path);
    // Feed choices, notes and API references are private, so the whole directory is.
    try platform.makePrivate(io, cwd, home_path, 0o700);
    var home = try cwd.openDir(io, home_path, .{});
    defer home.close(io);

    // The lock is what proves that no other daemon owns this database. The kernel
    // drops it if this process dies, so a stale lock is impossible.
    var lock_file = try home.createFile(io, "fyked.lock", .{ .truncate = false });
    defer lock_file.close(io);
    if (!try lock_file.tryLock(io, .exclusive)) return error.AlreadyRunning;
    if (options.log_to_file) try redirectLog(io, home);

    const socket_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home_path, socket_name });
    home.deleteFile(io, socket_name) catch {}; // Left behind by a crash.

    const db_path = try std.fmt.allocPrintSentinel(arena, "{s}/fyke.db", .{home_path}, 0);
    const config = try readConfig(arena, io, home);
    var s: Service = .{
        .gpa = gpa,
        .io = io,
        .home = home,
        .config = config,
        .started_at = Io.Clock.real.now(io).toMilliseconds(),
        .client = .{ .allocator = gpa, .io = fetch.withCancelableConnect(io) },
        .writer = try .open(db_path, .writer),
        .reader = try .open(db_path, .reader),
        .sandbox = try .open(db_path, .sandbox),
    };
    s.queue_buffer = try arena.alloc(@typeInfo(@TypeOf(s.queue_buffer)).pointer.child, s.config.workers * 2);
    s.queue = .init(s.queue_buffer);

    const address = try Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    try platform.makePrivate(io, home, socket_name, 0o600);

    var group: Io.Group = .init;
    for (0..s.config.workers) |_| try group.concurrent(io, service.workerLoop, .{&s});
    try group.concurrent(io, service.schedulerLoop, .{&s});
    s.full_text.store(s.config.full_text, .monotonic);
    s.remove_read_after_days.store(s.config.remove_read_after_days, .monotonic);
    if (s.config.auto_poll) try group.concurrent(io, service.fullTextLoop, .{&s});
    try group.concurrent(io, acceptLoop, .{ &s, &server });
    std.debug.print("fyked: listening on {s}\n", .{socket_path});

    s.stop.waitUncancelable(io);

    // Waiting for a commit in progress is all a clean exit needs. Any fetch still
    // running holds nothing that matters, and WAL recovers from anything worse.
    s.writer_lock.lockUncancelable(io);
    s.writer.close();
    home.deleteFile(io, socket_name) catch {};
    std.debug.print("fyked: stopped\n", .{});
    std.process.exit(0);
}

/// The file is edited by hand, so a typo must not stop the reader. Defaults apply, the
/// file stays as it is for the owner to fix, and `config.get` reports the problem.
fn readConfig(arena: std.mem.Allocator, io: Io, home: Io.Dir) !service.Config {
    const text = home.readFileAlloc(io, "config.json", arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(service.Config, arena, text, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("config.json: {s}, using defaults\n", .{@errorName(err)});
        return .{};
    };
}

fn acceptLoop(s: *Service, server: *Io.net.Server) Io.Cancelable!void {
    var connections: Io.Group = .init;
    while (true) {
        const stream = server.accept(s.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                std.debug.print("accept: {s}\n", .{@errorName(err)});
                continue;
            },
        };
        connections.concurrent(s.io, serve, .{ s, stream }) catch {
            stream.close(s.io);
        };
    }
}

fn serve(s: *Service, stream: Io.net.Stream) Io.Cancelable!void {
    defer stream.close(s.io);
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var reader = stream.reader(s.io, &in_buffer);
    var writer = stream.writer(s.io, &out_buffer);
    const in = &reader.interface;
    const out = &writer.interface;

    // A connection may lower its own tier, never raise it. Anything that can open
    // this socket is already the owner. Tiers exist to bound what an agent can do
    // through an adapter such as `fyke mcp`, which restricts itself first.
    var tier: ops.Tier = .manage;

    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var line: Io.Writer.Allocating = .init(arena);
        const length = in.streamDelimiterLimit(&line.writer, '\n', .limited(max_request)) catch return;
        // Without a newline, the stream ended or the request is too long.
        if ((in.peekByte() catch return) != '\n') return;
        in.toss(1);
        if (length == 0) continue;

        handle(s, arena, line.written(), out, &tier) catch return;
        const flushed = out.flush();
        if (s.stop_requested.load(.acquire)) s.stop.set(s.io);
        flushed catch return;
    }
}

fn handle(s: *Service, arena: std.mem.Allocator, line: []const u8, out: *Io.Writer, tier: *ops.Tier) !void {
    const request = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        return writeError(out, .null, code_parse, "ParseError");
    };
    if (request != .object) return writeError(out, .null, code_invalid_request, "InvalidRequest");
    const id = request.object.get("id") orelse .null;
    const method_value = request.object.get("method") orelse return writeError(out, id, code_invalid_request, "InvalidRequest");
    if (method_value != .string) return writeError(out, id, code_invalid_request, "InvalidRequest");
    const method = method_value.string;
    const params = request.object.get("params") orelse std.json.Value{ .object = .empty };

    if (std.mem.eql(u8, method, "connection.restrict")) return restrict(out, id, params, tier);
    if (std.mem.eql(u8, method, "events.subscribe")) {
        if (!tier.allows(.read)) return writeError(out, id, code_tier_denied, "TierDenied");
        return subscribe(s, out, id, params);
    }

    var result: Io.Writer.Allocating = .init(arena);
    ops.dispatch(s, arena, method, params, tier.*, &result.writer) catch |err| {
        const code: i32 = switch (err) {
            error.UnknownMethod => code_unknown_method,
            error.InvalidParams => code_invalid_params,
            error.TierDenied => code_tier_denied,
            else => code_failed,
        };
        return writeError(out, id, code, @errorName(err));
    };
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{s}}}\n", .{ std.json.fmt(id, .{}), result.written() });
}

fn restrict(out: *Io.Writer, id: std.json.Value, params: std.json.Value, tier: *ops.Tier) !void {
    const name = if (params == .object) params.object.get("tier") else null;
    const wanted = if (name != null and name.? == .string) std.meta.stringToEnum(ops.Tier, name.?.string) else null;
    if (wanted == null) return writeError(out, id, code_invalid_params, "InvalidParams");
    if (!tier.allows(wanted.?)) return writeError(out, id, code_tier_denied, "TierDenied");
    tier.* = wanted.?;
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"tier\":\"{s}\"}}}}\n", .{ std.json.fmt(id, .{}), @tagName(tier.*) });
}

fn writeError(out: *Io.Writer, id: std.json.Value, code: i32, kind: []const u8) !void {
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":\"{s}\",\"data\":{{\"kind\":\"{s}\"}}}}}}\n", .{ std.json.fmt(id, .{}), code, kind, kind });
}

/// Turns this connection into a one-way stream of events, starting after
/// `since_seq`. Clients use a second connection for requests, and reconnect from
/// their last seen sequence number, so they miss nothing.
fn subscribe(s: *Service, out: *Io.Writer, id: std.json.Value, params: std.json.Value) !void {
    var seq: i64 = 0;
    if (params == .object) {
        if (params.object.get("since_seq")) |value| {
            if (value == .integer) seq = value.integer;
        }
    }
    try out.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"result\":{{\"subscribed\":true}}}}\n", .{std.json.fmt(id, .{})});
    try out.flush();

    while (true) {
        var batch_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer batch_state.deinit();

        const reader = s.lockReader();
        const events = reader.eventsSince(batch_state.allocator(), seq, 500) catch |err| {
            s.unlockReader();
            return err;
        };
        s.unlockReader();

        for (events) |event| {
            try out.print("{{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{f}}}\n", .{std.json.fmt(event, .{})});
            seq = event.seq;
        }
        if (events.len != 0) {
            try out.flush();
            continue;
        }
        s.events_lock.lockUncancelable(s.io);
        defer s.events_lock.unlock(s.io);
        s.events_changed.waitTimeout(s.io, &s.events_lock, .{ .duration = .{ .raw = .fromMilliseconds(subscribe_poll_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}
