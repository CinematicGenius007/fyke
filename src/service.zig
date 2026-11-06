//! The daemon's shared state, and the scheduler that polls feeds in the background.
//!
//! Concurrency rules:
//!   * SQLite connections are used by one thread at a time, so each has a mutex.
//!   * `writer` is the only connection that changes data. Parsing and HTML
//!     conversion happen before its lock is taken, so it is held only for commits.
//!   * Reads use their own connection. WAL mode lets them run during a write.

const std = @import("std");
const core = @import("core");
const pipeline = @import("pipeline.zig");
const store = @import("store.zig");

const Io = std.Io;

pub const Config = struct {
    /// Concurrent fetches. A dead host can hold one for about 90 seconds, because
    /// Zig 0.17 cannot cancel a TCP connect, so this leaves room for that.
    workers: usize = 16,
    per_host: usize = 2,
    /// When false, feeds are fetched only on request. Used by tests.
    auto_poll: bool = true,
    min_poll_seconds: i64 = 15 * 60,
};

const housekeeping_interval_ms = 3600 * 1000;
const raw_bodies_kept = 20;
/// Ticks are at most this often, since each finished fetch asks for one.
const min_tick_ms = 20;
const max_tick_ms = 60 * 1000;

const Job = struct { id: i64, host: []const u8 };

pub const Service = struct {
    gpa: std.mem.Allocator,
    io: Io,
    home: Io.Dir,
    config: Config,
    started_at: i64,
    client: std.http.Client,

    writer: store.Db,
    writer_lock: Io.Mutex = .init,
    reader: store.Db,
    reader_lock: Io.Mutex = .init,
    sandbox: store.Db,
    sandbox_lock: Io.Mutex = .init,

    /// Signaled after events are written, for `events.subscribe`.
    events_lock: Io.Mutex = .init,
    events_changed: Io.Condition = .init,

    /// Set by `daemon.stop`. The connection that asked sets `stop` once its reply
    /// has been sent, since exiting first would leave the client with no answer.
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// The main thread waits on this.
    stop: Io.Event = .unset,

    // Scheduler state, guarded by `claims_lock`.
    claims_lock: Io.Mutex = .init,
    in_flight: std.AutoHashMapUnmanaged(i64, void) = .empty,
    hosts: std.StringHashMapUnmanaged(usize) = .empty,
    /// Set by a refresh of everything, which runs even with `auto_poll` off.
    forced: bool = false,

    wake: Io.Event = .unset,
    queue: Io.Queue(Job) = undefined,
    queue_buffer: []Job = &.{},

    pub fn now(s: *const Service) i64 {
        return Io.Clock.real.now(s.io).toMilliseconds();
    }

    pub fn context(s: *Service) pipeline.Context {
        return .{
            .gpa = s.gpa,
            .io = s.io,
            .db = &s.writer,
            .db_lock = &s.writer_lock,
            .client = &s.client,
            .home = s.home,
            .min_poll_seconds = s.config.min_poll_seconds,
        };
    }

    pub fn lockReader(s: *Service) *store.Db {
        s.reader_lock.lockUncancelable(s.io);
        return &s.reader;
    }

    pub fn unlockReader(s: *Service) void {
        s.reader_lock.unlock(s.io);
    }

    pub fn lockWriter(s: *Service) *store.Db {
        s.writer_lock.lockUncancelable(s.io);
        return &s.writer;
    }

    pub fn unlockWriter(s: *Service) void {
        s.writer_lock.unlock(s.io);
    }

    pub fn eventsChanged(s: *Service) void {
        s.events_lock.lockUncancelable(s.io);
        defer s.events_lock.unlock(s.io);
        s.events_changed.broadcast(s.io);
    }

    pub fn inFlight(s: *Service) usize {
        s.claims_lock.lockUncancelable(s.io);
        defer s.claims_lock.unlock(s.io);
        return s.in_flight.count();
    }

    /// Reserves a feed for fetching. Fails if it is already being fetched, or if
    /// its host is at its limit. The returned host is owned by the claim.
    pub fn claim(s: *Service, id: i64, url: []const u8) !?[]const u8 {
        const authority = core.url.split(url).authority orelse "";
        s.claims_lock.lockUncancelable(s.io);
        defer s.claims_lock.unlock(s.io);
        if (s.in_flight.contains(id)) return null;
        const count = s.hosts.getPtr(authority);
        if (count) |value| {
            if (value.* >= s.config.per_host) return null;
        }
        try s.in_flight.put(s.gpa, id, {});
        if (count) |value| {
            value.* += 1;
            return s.hosts.getKey(authority).?;
        }
        const host = try s.gpa.dupe(u8, authority);
        try s.hosts.put(s.gpa, host, 1);
        return host;
    }

    pub fn release(s: *Service, id: i64, host: []const u8) void {
        s.claims_lock.lockUncancelable(s.io);
        defer s.claims_lock.unlock(s.io);
        _ = s.in_flight.remove(id);
        const count = s.hosts.getPtr(host).?;
        count.* -= 1;
        if (count.* == 0) {
            const key = s.hosts.getKey(host).?;
            _ = s.hosts.remove(host);
            s.gpa.free(key);
        }
    }

    pub fn force(s: *Service) void {
        s.claims_lock.lockUncancelable(s.io);
        s.forced = true;
        s.claims_lock.unlock(s.io);
        s.wake.set(s.io);
    }

    fn shouldPoll(s: *Service) bool {
        s.claims_lock.lockUncancelable(s.io);
        defer s.claims_lock.unlock(s.io);
        return s.config.auto_poll or s.forced;
    }

    fn clearForced(s: *Service) void {
        s.claims_lock.lockUncancelable(s.io);
        defer s.claims_lock.unlock(s.io);
        s.forced = false;
    }
};

/// Finds due feeds and hands them to workers, then sleeps until the next one is
/// due or a worker finishes. With nothing due it wakes about once a minute.
pub fn schedulerLoop(s: *Service) Io.Cancelable!void {
    var last_housekeeping: i64 = s.now();
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();

        var wait_ms = tick(s, arena_state.allocator()) catch |err| blk: {
            std.debug.print("scheduler: {s}\n", .{@errorName(err)});
            break :blk @as(i64, 1000);
        };
        wait_ms = std.math.clamp(wait_ms, min_tick_ms, max_tick_ms);

        s.wake.waitTimeout(s.io, .{ .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
        s.wake.reset();
        try s.io.sleep(.fromMilliseconds(min_tick_ms), .awake);

        const now = s.now();
        if (now - last_housekeeping >= housekeeping_interval_ms) {
            last_housekeeping = now;
            housekeep(s) catch |err| std.debug.print("housekeeping: {s}\n", .{@errorName(err)});
        }
    }
}

/// Dispatches everything it can, and returns how long to sleep.
fn tick(s: *Service, arena: std.mem.Allocator) !i64 {
    if (!s.shouldPoll()) return max_tick_ms;

    const now = s.now();
    const reader = s.lockReader();
    const due = reader.dueFeeds(arena, now) catch |err| {
        s.unlockReader();
        return err;
    };
    const next = reader.nextDueAt() catch null;
    s.unlockReader();

    if (due.len == 0) {
        s.clearForced();
        return if (next) |at| at - now else max_tick_ms;
    }
    for (due) |feed| {
        const host = (try s.claim(feed.id, feed.url)) orelse continue;
        s.queue.putOne(s.io, .{ .id = feed.id, .host = host }) catch return max_tick_ms;
    }
    // Due feeds remain until their fetch finishes, and each finish wakes this loop.
    return max_tick_ms;
}

pub fn workerLoop(s: *Service) Io.Cancelable!void {
    while (true) {
        const job = s.queue.getOne(s.io) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
        fetchJob(s, job.id) catch |err| {
            std.debug.print("feed {d}: {s}\n", .{ job.id, @errorName(err) });
            // Without this, a failure before any bookkeeping would retry at once, forever.
            const writer = s.lockWriter();
            defer s.unlockWriter();
            const later = s.now() + 3600 * 1000;
            writer.updateFeed(.{ .id = job.id, .next_fetch_at = later, .last_fetch_at = s.now(), .error_count = 1, .last_error = @errorName(err) }) catch {};
        };
        s.release(job.id, job.host);
        s.eventsChanged();
        s.wake.set(s.io);
    }
}

fn fetchJob(s: *Service, id: i64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reader = s.lockReader();
    const row = reader.getFeed(arena, id) catch |err| {
        s.unlockReader();
        return err;
    };
    s.unlockReader();
    _ = try pipeline.refresh(s.context(), arena, row orelse return);
}

/// Keeps storage bounded: old raw bodies, events and fetch logs.
pub fn housekeep(s: *Service) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const writer = s.lockWriter();
    const stale = stale: {
        defer s.unlockWriter();
        try writer.prune(s.now());
        break :stale try writer.takeStaleRaw(arena, raw_bodies_kept);
    };
    for (stale) |hash| {
        const name = try std.fmt.allocPrint(arena, "raw/{s}/{s}.gz", .{ hash[0..2], hash });
        s.home.deleteFile(s.io, name) catch {};
    }
}
