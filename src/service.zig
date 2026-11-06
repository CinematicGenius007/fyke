//! The daemon's shared state, and the scheduler that polls feeds in the background.
//!
//! Concurrency rules:
//!   * SQLite connections are used by one thread at a time, so each has a mutex.
//!   * `writer` is the only connection that changes data. Parsing and HTML
//!     conversion happen before its lock is taken, so it is held only for commits.
//!   * Reads use their own connection. WAL mode lets them run during a write.

const std = @import("std");
const core = @import("core");
const fetch = @import("fetch.zig");
const pipeline = @import("pipeline.zig");
const store = @import("store.zig");

const Io = std.Io;

pub const Config = struct {
    /// Concurrent fetches.
    workers: usize = 16,
    per_host: usize = 2,
    /// When false, feeds are fetched only on request. Used by tests.
    auto_poll: bool = true,
    /// Fetch articles from their pages when a feed gives only a summary.
    full_text: bool = true,
    min_poll_seconds: i64 = 15 * 60,
    /// Bodies of read entries older than this are trimmed. Zero keeps them.
    remove_read_after_days: i64 = 0,
};

const housekeeping_interval_ms = 3600 * 1000;

const max_cutoff_days = 100 * 366;
/// Below this age a body can still be wanted for full-text work on the entry, and
/// reading it again is likely.
pub const min_trim_days = 30;

/// Any number of days gives a sane moment, whether from a request or config.json.
pub fn cutoffMillis(now: i64, days: i64) i64 {
    return now - std.math.clamp(days, 0, max_cutoff_days) * 24 * 3600 * 1000;
}

/// A feed body shorter than this is treated as a summary.
const short_text_length = 1500;
/// Older entries are fetched only on request, so that subscribing to a feed with a
/// long history does not turn into a crawl of the whole site.
const full_text_window_ms = 30 * 24 * 3600 * 1000;
const full_text_batch = 32;
/// Fetching one page at a time, with this gap, keeps the load on any site trivial.
const full_text_gap_ms = 1000;
const full_text_idle_ms = 5 * 60 * 1000;
const full_text_deadline_seconds = 15;
/// An extraction must beat the feed's text by this much to replace it.
const full_text_min_gain = 1.5;
/// Temporary failures allowed before an entry is given up on.
const full_text_max_attempts = 4;
/// A host that failed is left alone for this long, so that one bad site does not use
/// up the tries of everything else it published.
const full_text_host_pause_ms = 10 * 60 * 1000;
/// Connection failures on this many different hosts in a row mean our own network is
/// down, which says nothing about the pages.
const outage_host_count = 3;
const outage_first_pause_ms = 60 * 1000;
const outage_max_pause_ms = 5 * 60 * 1000;
const robots_ttl_ms = 24 * 3600 * 1000;
const robots_token = "rss_";
const page_accept = "text/html,application/xhtml+xml;q=0.9";
const raw_bodies_kept = 20;
/// Ticks are at most this often, since each finished fetch asks for one.
const min_tick_ms = 20;
const max_tick_ms = 60 * 1000;

const Job = struct { id: i64, host: []const u8 };
const RobotsEntry = struct { text: []const u8, fetched_at: i64 };

const Retry = struct {
    /// No server answered, as opposed to one answering with a temporary error.
    network: bool,
    after_seconds: ?u32 = null,
};

/// How one try at an article ended. Only `retry` says nothing about the page itself.
const Attempt = union(enum) { done, skipped, failed, retry: Retry };

/// Watches for failures that point at this machine's network, not at any one site.
const OutageDetector = struct {
    streak: usize = 0,
    last_host: [256]u8 = undefined,
    last_host_len: usize = 0,
    pause_ms: i64 = outage_first_pause_ms,

    /// Records a connection failure, and reports whether the network looks down.
    fn failed(d: *OutageDetector, host: []const u8) bool {
        const short = host[0..@min(host.len, d.last_host.len)];
        if (d.streak == 0 or !std.mem.eql(u8, short, d.last_host[0..d.last_host_len])) {
            @memcpy(d.last_host[0..short.len], short);
            d.last_host_len = short.len;
            d.streak += 1;
        }
        return d.streak >= outage_host_count;
    }

    fn recovered(d: *OutageDetector) void {
        d.streak = 0;
        d.pause_ms = outage_first_pause_ms;
    }

    fn nextPause(d: *OutageDetector) i64 {
        defer d.pause_ms = @min(d.pause_ms * 2, outage_max_pause_ms);
        return d.pause_ms;
    }
};

/// Waits an hour, then six, then a day, or longer if the site asked for that.
fn retryDelayMs(attempts: i64, after_seconds: ?u32) i64 {
    const hours: i64 = switch (attempts) {
        1 => 1,
        2 => 6,
        else => 24,
    };
    return @max(hours * 3600 * 1000, @as(i64, after_seconds orelse 0) * 1000);
}

/// Errors that a later try could not change are final. The rest are the network's.
fn fetchFailure(err: anyerror) !Attempt {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PrivateAddress, error.NotHttp, error.TooManyRedirects, error.RedirectWithoutLocation => .failed,
        else => .{ .retry = .{ .network = true } },
    };
}

fn statusOutcome(status: u16, after_seconds: ?u32) Attempt {
    if (status == 408 or status == 429 or status >= 500) return .{ .retry = .{ .network = false, .after_seconds = after_seconds } };
    return .failed;
}

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

    /// Held while `config.set` rewrites config.json.
    config_lock: Io.Mutex = .init,

    /// Set by `daemon.stop`. The connection that asked sets `stop` once its reply
    /// has been sent, since exiting first would leave the client with no answer.
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// Starts from `config.full_text`, and `config.set` changes it while running.
    full_text: std.atomic.Value(bool) = .init(true),
    /// Starts from `config.remove_read_after_days`, and follows config.json.
    remove_read_after_days: std.atomic.Value(i64) = .init(0),
    /// The main thread waits on this.
    stop: Io.Event = .unset,

    // Scheduler state, guarded by `claims_lock`.
    claims_lock: Io.Mutex = .init,
    in_flight: std.AutoHashMapUnmanaged(i64, void) = .empty,
    hosts: std.StringHashMapUnmanaged(usize) = .empty,
    /// Set by a refresh of everything, which runs even with `auto_poll` off.
    forced: bool = false,

    /// Cached robots.txt files by host, guarded by `robots_lock`.
    robots_lock: Io.Mutex = .init,
    robots: std.StringHashMapUnmanaged(RobotsEntry) = .empty,

    wake: Io.Event = .unset,
    /// Set when entries may have arrived, since the full text loop sleeps when idle.
    full_text_wake: Io.Event = .unset,
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
        s.full_text_wake.set(s.io);
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
            // Reached only when the feed could not be read or its failure recorded.
            // Without this, it would retry at once, forever.
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
    const feed = row orelse return;
    const started = s.now();
    _ = pipeline.refresh(s.context(), arena, feed) catch |err| {
        _ = try pipeline.failed(s.context(), feed, started, null, @errorName(err), null, null);
    };
}

pub fn readConfigFile(s: *Service, arena: std.mem.Allocator) ![]const u8 {
    s.config_lock.lockUncancelable(s.io);
    defer s.config_lock.unlock(s.io);
    return s.home.readFileAlloc(s.io, "config.json", arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "{}",
        else => return err,
    };
}

/// Takes up the settings that apply while running.
pub fn applyConfig(s: *Service, values: Config) void {
    if (s.full_text.swap(values.full_text, .monotonic) != values.full_text) s.full_text_wake.set(s.io);
    s.remove_read_after_days.store(values.remove_read_after_days, .monotonic);
}

/// A daemon can run for days with no client asking, so it reads the file itself.
fn followConfig(s: *Service, arena: std.mem.Allocator) void {
    const text = readConfigFile(s, arena) catch return;
    const values = std.json.parseFromSliceLeaky(Config, arena, text, .{ .ignore_unknown_fields = true }) catch return;
    applyConfig(s, values);
}

/// Keeps storage bounded: old raw bodies, events and fetch logs.
pub fn housekeep(s: *Service) !void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    followConfig(s, arena);

    const writer = s.lockWriter();
    const stale = stale: {
        defer s.unlockWriter();
        try writer.prune(s.now());
        const days = s.remove_read_after_days.load(.monotonic);
        if (days > 0) _ = try writer.trimEntries(cutoffMillis(s.now(), @max(days, min_trim_days)));
        break :stale try writer.takeStaleRaw(arena, raw_bodies_kept);
    };
    for (stale) |hash| deleteRaw(s, arena, hash);
}

pub fn deleteRaw(s: *Service, arena: std.mem.Allocator, hash: []const u8) void {
    const name = std.fmt.allocPrint(arena, "raw/{s}/{s}.gz", .{ hash[0..2], hash }) catch return;
    s.home.deleteFile(s.io, name) catch {};
}

/// Works through recent short entries, one page at a time, for as long as the
/// daemon runs. It has a loop of its own so that it can never delay feed polling.
pub fn fullTextLoop(s: *Service) Io.Cancelable!void {
    var outage: OutageDetector = .{};
    var host_pauses: std.StringHashMapUnmanaged(i64) = .empty;
    while (true) {
        var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const enabled = s.full_text.load(.monotonic);
        const since = s.now() - full_text_window_ms;
        if (enabled) settleLongEntries(s, since);
        const reader = s.lockReader();
        const jobs = if (enabled) reader.dueFullText(arena, since, short_text_length, full_text_batch, s.now()) catch &.{} else &.{};
        s.unlockReader();

        var network_down = false;
        for (jobs) |job| {
            const host = core.url.split(job.url).authority orelse "";
            if (host_pauses.get(host)) |until| {
                if (until > s.now()) {
                    postponeFullText(s, job.id, until);
                    continue;
                }
            }

            var job_arena: std.heap.ArenaAllocator = .init(s.gpa);
            defer job_arena.deinit();
            const attempt = attemptFullText(s, job_arena.allocator(), job) catch |err| blk: {
                std.debug.print("full text {d}: {s}\n", .{ job.id, @errorName(err) });
                break :blk Attempt.failed;
            };
            switch (attempt) {
                .retry => |retry| {
                    if (retry.network and outage.failed(host)) {
                        network_down = true;
                        break;
                    }
                    if (!retry.network) outage.recovered();
                    recordRetry(s, job, retry);
                    pauseHost(s, &host_pauses, host);
                },
                else => {
                    outage.recovered();
                    finishFullText(s, job.id, attempt);
                },
            }
            s.eventsChanged();
            try s.io.sleep(.fromMilliseconds(full_text_gap_ms), .awake);
        }
        if (network_down) {
            try s.io.sleep(.fromMilliseconds(outage.nextPause()), .awake);
        } else if (jobs.len == 0) {
            s.full_text_wake.waitTimeout(s.io, .{ .duration = .{ .raw = .fromMilliseconds(full_text_idle_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
            s.full_text_wake.reset();
        }
    }
}

/// Entries long enough to need no fetch would otherwise be read again on every wake.
fn settleLongEntries(s: *Service, since: i64) void {
    const writer = s.lockWriter();
    defer s.unlockWriter();
    writer.skipLongEntries(since, short_text_length, s.now()) catch {};
}

fn setFullStatus(s: *Service, id: i64, status: []const u8) void {
    const writer = s.lockWriter();
    defer s.unlockWriter();
    writer.markFullText(id, status, s.now()) catch {};
}

/// Stores a final outcome. A successful fetch has stored itself.
fn finishFullText(s: *Service, id: i64, attempt: Attempt) void {
    switch (attempt) {
        .skipped, .failed => setFullStatus(s, id, @tagName(attempt)),
        .done, .retry => {},
    }
}

fn recordRetry(s: *Service, job: store.FullTextJob, retry: Retry) void {
    const attempts = job.attempts + 1;
    if (attempts >= full_text_max_attempts) return setFullStatus(s, job.id, "failed");
    const now = s.now();
    const writer = s.lockWriter();
    defer s.unlockWriter();
    writer.retryFullText(job.id, attempts, now + retryDelayMs(attempts, retry.after_seconds), now) catch {};
}

fn postponeFullText(s: *Service, id: i64, retry_at: i64) void {
    const writer = s.lockWriter();
    defer s.unlockWriter();
    writer.postponeFullText(id, retry_at) catch {};
}

fn pauseHost(s: *Service, pauses: *std.StringHashMapUnmanaged(i64), host: []const u8) void {
    const slot = pauses.getOrPut(s.gpa, host) catch return;
    if (!slot.found_existing) {
        slot.key_ptr.* = s.gpa.dupe(u8, host) catch {
            pauses.removeByPtr(slot.key_ptr);
            return;
        };
    }
    slot.value_ptr.* = s.now() + full_text_host_pause_ms;
}

/// Fetches one article on request, ignoring any wait. Returns its status: `done` when
/// it replaced the entry's content, `skipped` or `failed`, or `later` when the site
/// could not be reached, which leaves the entry as it was.
pub fn fetchFullText(s: *Service, arena: std.mem.Allocator, job: store.FullTextJob) ![]const u8 {
    const attempt = attemptFullText(s, arena, job) catch Attempt.failed;
    finishFullText(s, job.id, attempt);
    return if (attempt == .retry) "later" else @tagName(attempt);
}

fn attemptFullText(s: *Service, arena: std.mem.Allocator, job: store.FullTextJob) !Attempt {
    if (!core.url.isHttp(job.url)) return .skipped;
    if (try robotsRefusal(s, arena, job)) |refusal| return refusal;

    const response = fetch.fetch(&s.client, arena, .{
        .url = job.url,
        .allow_private_network = job.allow_private_network,
        .deadline_seconds = full_text_deadline_seconds,
        .accept = page_accept,
    }) catch |err| return fetchFailure(err);
    if (response.status != 200) return statusOutcome(response.status, response.retry_after_seconds);
    const kind = response.content_type orelse "";
    if (std.ascii.findIgnoreCase(kind, "html") == null) return .skipped;

    const page = core.encoding.pageToUtf8(arena, response.body, kind) catch |err| switch (err) {
        error.UnsupportedEncoding => return .skipped,
        else => return err,
    };
    const found = (try core.extract.extract(arena, page, response.final_url)) orelse return .skipped;
    const nodes = withoutTitle(found, job.title);

    var text: Io.Writer.Allocating = .init(arena);
    try core.blocks.writeText(&text.writer, nodes);
    // `text_length` counts characters, so bytes would flatter text outside ASCII.
    const characters = std.unicode.utf8CountCodepoints(text.written()) catch text.written().len;
    const gain = @as(f64, @floatFromInt(characters)) / @as(f64, @floatFromInt(@max(job.text_length, 1)));
    if (gain < full_text_min_gain) return .skipped;

    var json: Io.Writer.Allocating = .init(arena);
    try core.blocks.writeJson(&json.writer, nodes);

    const writer = s.lockWriter();
    defer s.unlockWriter();
    try writer.saveFullText(job.id, json.written(), text.written(), s.now());
    return .done;
}

/// Readers show the title themselves, so a page's own copy of it is dropped.
fn withoutTitle(nodes: []const core.blocks.Node, title: ?[]const u8) []const core.blocks.Node {
    const wanted = title orelse return nodes;
    if (nodes.len == 0 or nodes[0].kind != .h or nodes[0].children.len != 1) return nodes;
    const first = nodes[0].children[0];
    if (first.kind == .text and std.ascii.eqlIgnoreCase(std.mem.trim(u8, first.value, " "), wanted)) return nodes[1..];
    return nodes;
}

/// Asks the site's robots.txt, caching it for a day, and returns null when the page
/// may be fetched. A missing file allows everything. A file that cannot be read means
/// not now, as RFC 9309 advises.
fn robotsRefusal(s: *Service, arena: std.mem.Allocator, job: store.FullTextJob) !?Attempt {
    const parts = core.url.split(job.url);
    const authority = parts.authority orelse return .skipped;
    const base_path = if (parts.path.len == 0) "/" else parts.path;
    // RFC 9309 matches rules against the path and the query together.
    const path = if (parts.query) |query| try std.fmt.allocPrint(arena, "{s}?{s}", .{ base_path, query }) else base_path;
    const now = s.now();

    // Another thread may replace and free the cached text, so it is read under the lock.
    {
        s.robots_lock.lockUncancelable(s.io);
        defer s.robots_lock.unlock(s.io);
        if (s.robots.get(authority)) |entry| {
            if (now - entry.fetched_at < robots_ttl_ms) return verdict(entry.text, path);
        }
    }

    const location = try std.fmt.allocPrint(arena, "{s}://{s}/robots.txt", .{ parts.scheme, authority });
    const response = fetch.fetch(&s.client, arena, .{
        .url = location,
        .allow_private_network = job.allow_private_network,
        .deadline_seconds = full_text_deadline_seconds,
        .accept = "text/plain",
    }) catch |err| return try fetchFailure(err);
    if (response.status == 429 or response.status >= 500) return statusOutcome(response.status, response.retry_after_seconds);
    const text = if (response.status == 200) response.body else "";

    s.robots_lock.lockUncancelable(s.io);
    defer s.robots_lock.unlock(s.io);
    const slot = try s.robots.getOrPut(s.gpa, authority);
    if (slot.found_existing) {
        s.gpa.free(slot.value_ptr.text);
    } else {
        slot.key_ptr.* = try s.gpa.dupe(u8, authority);
    }
    slot.value_ptr.* = .{ .text = try s.gpa.dupe(u8, text), .fetched_at = now };
    return verdict(text, path);
}

fn verdict(robots_text: []const u8, path: []const u8) ?Attempt {
    return if (core.robots.isAllowed(robots_text, robots_token, path)) null else .skipped;
}

test "retries wait longer each time, and respect the site" {
    const hour = 3600 * 1000;
    try std.testing.expectEqual(1 * hour, retryDelayMs(1, null));
    try std.testing.expectEqual(6 * hour, retryDelayMs(2, null));
    try std.testing.expectEqual(24 * hour, retryDelayMs(3, null));
    try std.testing.expectEqual(2 * hour, retryDelayMs(1, 7200));
}

test "only failures a later try could fix are retried" {
    try std.testing.expect((try fetchFailure(error.ConnectionRefused)) == .retry);
    try std.testing.expect((try fetchFailure(error.DeadlineExceeded)) == .retry);
    try std.testing.expect((try fetchFailure(error.PrivateAddress)) == .failed);
    try std.testing.expect(statusOutcome(503, null) == .retry);
    try std.testing.expect(statusOutcome(429, 60) == .retry);
    try std.testing.expect(statusOutcome(404, null) == .failed);
    try std.testing.expect(statusOutcome(410, null) == .failed);
}

test "an outage takes failures on several hosts, not one" {
    var outage: OutageDetector = .{};
    for (0..10) |_| try std.testing.expect(!outage.failed("a.example"));
    try std.testing.expect(!outage.failed("b.example"));
    try std.testing.expect(outage.failed("c.example"));
    try std.testing.expectEqual(outage_first_pause_ms, outage.nextPause());
    try std.testing.expectEqual(2 * outage_first_pause_ms, outage.nextPause());
    for (0..8) |_| _ = outage.nextPause();
    try std.testing.expectEqual(outage_max_pause_ms, outage.nextPause());
    outage.recovered();
    try std.testing.expect(!outage.failed("a.example"));
    try std.testing.expectEqual(outage_first_pause_ms, outage.nextPause());
}

test "the page's own title is dropped" {
    const Node = core.blocks.Node;
    const heading = [_]Node{.{ .kind = .text, .value = "Hello" }};
    const nodes = [_]Node{ .{ .kind = .h, .level = 1, .children = &heading }, .{ .kind = .hr } };
    try std.testing.expectEqual(1, withoutTitle(&nodes, "hello").len);
    try std.testing.expectEqual(2, withoutTitle(&nodes, "Other").len);
    try std.testing.expectEqual(2, withoutTitle(&nodes, null).len);
}
