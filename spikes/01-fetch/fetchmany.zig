//! Spike: what the daemon needs. One process, one shared http.Client, a worker
//! pool, and a hard deadline per feed enforced by Io cancelation.
//! Usage: fetchmany <urls-file> <workers> <deadline-seconds>
const std = @import("std");
const Io = std.Io;

const max_body = 32 * 1024 * 1024;

const Shared = struct {
    io: Io,
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    urls: []const []const u8,
    next: std.atomic.Value(usize) = .init(0),
    deadline: Io.Duration,
    mutex: Io.Mutex = .init,
    out: *Io.Writer,
};

const Fetched = struct { status: u16, bytes: usize };

fn fetchBody(s: *Shared, arena: std.mem.Allocator, url: []const u8) anyerror!Fetched {
    const uri = try std.Uri.parse(url);
    var req = try s.client.request(.GET, uri, .{
        .redirect_behavior = .init(5),
        .headers = .{ .user_agent = .{ .override = "rss_-spike/0.1 (feed reader prototype)" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    const redirect_buffer = try arena.alloc(u8, 8192);
    var response = try req.receiveHead(redirect_buffer);
    const status = @intFromEnum(response.head.status);
    if (response.head.status == .not_modified) return .{ .status = status, .bytes = 0 };

    const decompress_buffer = try arena.alloc(u8, @max(std.compress.flate.max_window_len, std.compress.zstd.default_window_len));
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const body = reader.allocRemaining(arena, .limited(max_body)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.BodyDecodeFailed,
        else => |e| return e,
    };
    return .{ .status = status, .bytes = body.len };
}

fn timer(io: Io, duration: Io.Duration) Io.Cancelable!void {
    try io.sleep(duration, .awake);
}

const Race = union(enum) {
    fetched: anyerror!Fetched,
    expired: Io.Cancelable!void,
};

fn worker(s: *Shared) Io.Cancelable!void {
    const io = s.io;
    while (true) {
        const i = s.next.fetchAdd(1, .monotonic);
        if (i >= s.urls.len) return;
        const url = s.urls[i];

        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();

        const started = Io.Clock.awake.now(io);
        var buffer: [2]Race = undefined;
        var select: Io.Select(Race) = .init(io, &buffer);
        select.concurrent(.fetched, fetchBody, .{ s, arena_state.allocator(), url }) catch |e| @panic(@errorName(e));
        select.concurrent(.expired, timer, .{ io, s.deadline }) catch |e| @panic(@errorName(e));
        const first = try select.await();
        select.cancelDiscard();
        const ms = started.durationTo(Io.Clock.awake.now(io)).toMilliseconds();

        try s.mutex.lock(io);
        defer s.mutex.unlock(io);
        switch (first) {
            .expired => s.out.print("DEADLINE {d}ms {s}\n", .{ ms, url }) catch {},
            .fetched => |r| if (r) |f|
                s.out.print("{d} {d}b {d}ms {s}\n", .{ f.status, f.bytes, ms, url }) catch {}
            else |e|
                s.out.print("ERR {s} {d}ms {s}\n", .{ @errorName(e), ms, url }) catch {},
        }
        s.out.flush() catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const text = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    const workers = try std.fmt.parseInt(usize, args[2], 10);
    const seconds = try std.fmt.parseInt(i64, args[3], 10);

    var urls: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |l| try urls.append(arena, l);

    var client: std.http.Client = .{ .allocator = init.gpa, .io = io };
    defer client.deinit();

    var out_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &out_buf);

    var shared: Shared = .{
        .io = io,
        .gpa = init.gpa,
        .client = &client,
        .urls = urls.items,
        .deadline = .fromSeconds(seconds),
        .out = &out.interface,
    };

    var group: Io.Group = .init;
    for (0..workers) |_| try group.concurrent(io, worker, .{&shared});
    try group.await(io);
}
