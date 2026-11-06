//! Ingest: from a feed URL to committed rows. See docs/architecture.md.
//! The body is saved before it is parsed, so that parsing can always be replayed.

const std = @import("std");
const core = @import("core");
const fetch = @import("fetch.zig");
const store = @import("store.zig");

const Io = std.Io;
const feed = core.feed;
const url = core.url;
const blocks = core.blocks;

const max_backoff_seconds = 24 * 3600;
const min_poll_seconds = 15 * 60;
const max_poll_seconds = 24 * 3600;

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The writer connection. Every use must hold `db_lock`.
    db: *store.Db,
    db_lock: *Io.Mutex,
    client: *std.http.Client,
    /// Directory that holds `raw/`.
    home: Io.Dir,
    min_poll_seconds: i64 = min_poll_seconds,

    fn now(c: Context) i64 {
        return Io.Clock.real.now(c.io).toMilliseconds();
    }

    fn lock(c: Context) void {
        c.db_lock.lockUncancelable(c.io);
    }

    fn unlock(c: Context) void {
        c.db_lock.unlock(c.io);
    }
};

pub const Outcome = struct {
    status: enum { updated, not_modified, unchanged_body, failed, gone },
    new: usize = 0,
    updated: usize = 0,
    message: ?[]const u8 = null,
};

/// What the user chose while subscribing. Null keeps the feed's own values.
pub const Details = struct {
    title: ?[]const u8 = null,
    folder: ?[]const u8 = null,
};

/// Finds the feed behind `input`, subscribes to it, and fetches it once.
pub fn subscribe(c: Context, arena: std.mem.Allocator, input: []const u8, allow_private_network: bool, details: Details) !struct { id: i64, outcome: Outcome } {
    const start = try normalizeInput(arena, input);
    const found = try discover(c, arena, start, allow_private_network);

    c.lock();
    const id = addWithDetails(c, found.url, allow_private_network, details) catch |err| {
        c.unlock();
        return err;
    };
    const maybe_row = c.db.getFeed(arena, id) catch |err| {
        c.unlock();
        return err;
    };
    c.unlock();
    const row = maybe_row orelse return error.FeedMissing;
    return .{ .id = id, .outcome = try apply(c, arena, row, found.response, 0) };
}

fn addWithDetails(c: Context, feed_url: []const u8, allow_private_network: bool, details: Details) !i64 {
    const id = try c.db.addFeed(feed_url, allow_private_network, c.now());
    const folder_id = if (details.folder) |name| try c.db.ensureFolder(null, name) else null;
    try c.db.setFeedDetails(id, details.title, folder_id);
    return id;
}

/// One feed that a site offers, described well enough to choose it.
pub const Candidate = struct {
    url: []const u8,
    title: ?[]const u8,
    site_url: ?[]const u8,
    format: []const u8,
    /// Titles of its first few entries.
    latest: []const []const u8,
};

const max_candidates = 8;
/// No new page is tried past this, so that finding a feed on a slow site ends within
/// the client's reply timeout, given the deadline of the fetch already running.
pub const discovery_budget_ms = 60 * 1000;
const preview_entries = 3;

/// Finds every feed behind `input` without subscribing. Each advertised feed
/// costs one request, so the list is capped. Well-known paths are only tried
/// when a page advertises nothing, as in `discover`.
pub fn preview(c: Context, arena: std.mem.Allocator, input: []const u8, allow_private_network: bool) ![]const Candidate {
    const started = c.now();
    const start = try normalizeInput(arena, input);
    const first = try fetch.fetch(c.client, arena, .{ .url = start, .allow_private_network = allow_private_network });
    if (first.status != 200) return error.HttpError;

    var list: std.ArrayList(Candidate) = .empty;
    if (try describe(arena, first.final_url, first.body)) |one| {
        try list.append(arena, one);
        return list.items;
    }
    for (try core.html.discoverFeeds(arena, first.body, first.final_url)) |link| {
        if (list.items.len == max_candidates or outOfTime(c, started)) break;
        try appendCandidate(c, arena, &list, link, allow_private_network);
    }
    if (list.items.len != 0) return list.items;

    const paths = [_][]const u8{ "/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/index.xml", "/feed.json" };
    for (paths) |path| {
        if (outOfTime(c, started)) break;
        try appendCandidate(c, arena, &list, try url.resolve(arena, first.final_url, path), allow_private_network);
        if (list.items.len != 0) break;
    }
    return list.items;
}

fn outOfTime(c: Context, started: i64) bool {
    return c.now() - started > discovery_budget_ms;
}

fn appendCandidate(c: Context, arena: std.mem.Allocator, list: *std.ArrayList(Candidate), link: []const u8, allow_private_network: bool) !void {
    const found = try tryFeed(c, arena, link, allow_private_network) orelse return;
    for (list.items) |known| if (std.mem.eql(u8, known.url, found.url)) return;
    if (try describe(arena, found.url, found.response.body)) |one| try list.append(arena, one);
}

fn describe(arena: std.mem.Allocator, feed_url: []const u8, body: []const u8) !?Candidate {
    const parsed = feed.parse(arena, body) catch return null;
    var latest: std.ArrayList([]const u8) = .empty;
    for (parsed.entries) |entry| {
        if (latest.items.len == preview_entries) break;
        if (entry.title) |title| try latest.append(arena, title);
    }
    return .{
        .url = feed_url,
        .title = parsed.title,
        .site_url = parsed.site_url,
        .format = @tagName(parsed.format),
        .latest = latest.items,
    };
}

fn normalizeInput(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (url.split(trimmed).scheme.len == 0) return std.fmt.allocPrint(arena, "https://{s}", .{trimmed});
    if (!url.isHttp(trimmed)) return error.NotHttp;
    return trimmed;
}

const Found = struct { url: []const u8, response: fetch.Response };

/// The order is from docs/rss-primer.md: the URL itself, what the page advertises,
/// then well-known paths.
fn discover(c: Context, arena: std.mem.Allocator, start: []const u8, allow_private_network: bool) !Found {
    const started = c.now();
    const first = try fetch.fetch(c.client, arena, .{ .url = start, .allow_private_network = allow_private_network });
    if (first.status != 200) return error.HttpError;
    if (isFeed(arena, first.body)) return .{ .url = first.final_url, .response = first };

    for (try core.html.discoverFeeds(arena, first.body, first.final_url)) |candidate| {
        if (outOfTime(c, started)) return error.NoFeedFound;
        if (try tryFeed(c, arena, candidate, allow_private_network)) |found| return found;
    }
    const paths = [_][]const u8{ "/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/index.xml", "/feed.json" };
    for (paths) |path| {
        if (outOfTime(c, started)) return error.NoFeedFound;
        if (try tryFeed(c, arena, try url.resolve(arena, first.final_url, path), allow_private_network)) |found| return found;
    }
    return error.NoFeedFound;
}

fn tryFeed(c: Context, arena: std.mem.Allocator, candidate: []const u8, allow_private_network: bool) !?Found {
    if (!url.isHttp(candidate)) return null;
    const response = fetch.fetch(c.client, arena, .{ .url = candidate, .allow_private_network = allow_private_network }) catch return null;
    if (response.status != 200 or !isFeed(arena, response.body)) return null;
    return .{ .url = response.final_url, .response = response };
}

fn isFeed(arena: std.mem.Allocator, body: []const u8) bool {
    _ = feed.parse(arena, body) catch return false;
    return true;
}

/// Fetches one subscription and stores the result. A failure here is an outcome,
/// not an error: one broken feed must never stop the others.
pub fn refresh(c: Context, arena: std.mem.Allocator, row: store.Feed) !Outcome {
    const started = c.now();
    const response = fetch.fetch(c.client, arena, .{
        .url = row.url,
        .etag = row.etag,
        .last_modified = row.last_modified,
        .allow_private_network = row.allow_private_network,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return failed(c, row, started, null, @errorName(err), null, null);
    };
    return apply(c, arena, row, response, started);
}

/// `raw_sha256` names a body already saved for this attempt, so that housekeeping
/// can find it. Without that, each bad body would stay on disk forever.
pub fn failed(c: Context, row: store.Feed, started: i64, status: ?u16, message: []const u8, retry_after: ?u32, raw_sha256: ?[]const u8) !Outcome {
    const now = c.now();
    const count = row.error_count + 1;
    c.lock();
    defer c.unlock();
    try c.db.updateFeed(.{
        .id = row.id,
        .next_fetch_at = now + nextDelaySeconds(row.poll_seconds, count, retry_after, now) * 1000,
        .last_fetch_at = now,
        .error_count = count,
        .last_error = message,
    });
    try c.db.logFetch(.{ .feed_id = row.id, .started_at = started, .duration_ms = now - started, .http_status = status, .raw_sha256 = raw_sha256, .err = message });
    return .{ .status = .failed, .message = message };
}

/// Seconds until the next poll. Failures double the wait, up to a day. A server's
/// Retry-After wins whenever it asks for longer. Jitter stops polls from aligning.
pub fn nextDelaySeconds(poll_seconds: i64, error_count: i64, retry_after: ?u32, seed: i64) i64 {
    const shift: u6 = @intCast(@min(error_count, 10));
    const base = @min(poll_seconds << shift, @max(poll_seconds, max_backoff_seconds));
    const wait = @max(base, @as(i64, retry_after orelse 0));
    const spread = @divTrunc(wait, 10);
    if (spread == 0) return wait;
    return wait + @mod(seed, spread);
}

/// Chooses how often to poll. A quarter of the typical gap between posts finds
/// most posts soon after they appear, without polling a monthly blog every hour.
/// A publisher's hint is a floor, and the result stays between the limits.
pub fn adaptPollSeconds(posting_gap: ?i64, hint: ?u32, min_seconds: i64, current: i64) i64 {
    const wanted = if (posting_gap) |gap| @divTrunc(gap, 4) else current;
    const floor = @max(min_seconds, @as(i64, hint orelse 0));
    return std.math.clamp(wanted, @min(floor, max_poll_seconds), max_poll_seconds);
}

/// When to poll next after a success, outside the times the publisher asked us to skip.
fn nextPollAt(now: i64, poll_seconds: i64, skip_hours: i64, skip_days: i64) i64 {
    return afterSkipped(now + nextDelaySeconds(poll_seconds, 0, null, now) * 1000, skip_hours, skip_days);
}

/// Moves `at` forward to the start of the first UTC hour that `<skipHours>` and
/// `<skipDays>` allow. Bit n of `skip_hours` is hour n, and bit n of `skip_days` is
/// weekday n, counting from Sunday. A feed that skips everything keeps `at`, since
/// polling it rarely is better than never.
pub fn afterSkipped(at: i64, skip_hours: i64, skip_days: i64) i64 {
    const hour_ms = 3600 * 1000;
    var hour_index = @divFloor(at, hour_ms);
    for (0..24 * 7) |step| {
        const hour: u6 = @intCast(@mod(hour_index, 24));
        // The first day of Unix time was a Thursday.
        const weekday: u6 = @intCast(@mod(@divFloor(hour_index, 24) + 4, 7));
        const skipped = (skip_hours >> hour) & 1 != 0 or (skip_days >> weekday) & 1 != 0;
        if (!skipped) return if (step == 0) at else hour_index * hour_ms;
        hour_index += 1;
    }
    return at;
}

fn apply(c: Context, arena: std.mem.Allocator, row: store.Feed, response: fetch.Response, started_in: i64) !Outcome {
    const now = c.now();
    const started = if (started_in == 0) now else started_in;
    const duration = now - started;

    switch (response.status) {
        200 => {},
        304 => {
            c.lock();
            defer c.unlock();
            try c.db.updateFeed(.{
                .id = row.id,
                .url = if (response.moved_permanently) response.final_url else null,
                .etag = response.etag,
                .last_modified = response.last_modified,
                .next_fetch_at = nextPollAt(now, row.poll_seconds, row.skip_hours, row.skip_days),
                .last_fetch_at = now,
                .last_success_at = now,
                .error_count = 0,
            });
            try c.db.logFetch(.{ .feed_id = row.id, .started_at = started, .duration_ms = duration, .http_status = 304 });
            return .{ .status = .not_modified };
        },
        410 => {
            c.lock();
            defer c.unlock();
            try c.db.updateFeed(.{ .id = row.id, .status = "gone", .next_fetch_at = now, .last_fetch_at = now, .error_count = row.error_count + 1, .last_error = "HTTP 410 Gone" });
            try c.db.logFetch(.{ .feed_id = row.id, .started_at = started, .duration_ms = duration, .http_status = 410, .err = "gone" });
            return .{ .status = .gone, .message = "HTTP 410 Gone" };
        },
        else => {
            const message = try std.fmt.allocPrint(arena, "HTTP {d}", .{response.status});
            return failed(c, row, started, response.status, message, response.retry_after_seconds, null);
        },
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(response.body, &digest, .{});
    const hash = std.fmt.bytesToHex(digest, .lower);

    // About 10% of servers ignore validators, so an identical body is common.
    c.lock();
    const last_hash = c.db.lastRawHash(arena, row.id) catch |err| {
        c.unlock();
        return err;
    };
    c.unlock();
    const unchanged = if (last_hash) |last| std.mem.eql(u8, last, &hash) else false;
    if (unchanged) {
        c.lock();
        defer c.unlock();
        try c.db.updateFeed(.{
            .id = row.id,
            .url = if (response.moved_permanently) response.final_url else null,
            .etag = response.etag,
            .last_modified = response.last_modified,
            .next_fetch_at = nextPollAt(now, row.poll_seconds, row.skip_hours, row.skip_days),
            .last_fetch_at = now,
            .last_success_at = now,
            .error_count = 0,
        });
        try c.db.logFetch(.{ .feed_id = row.id, .started_at = started, .duration_ms = duration, .http_status = 200, .bytes = response.body.len, .raw_sha256 = &hash });
        return .{ .status = .unchanged_body };
    }

    try saveRaw(c, &hash, response.body);

    return commit(c, arena, row, response, started, &hash) catch |err| {
        return failed(c, row, started, 200, @errorName(err), null, &hash);
    };
}

/// Parses a saved body and stores what it holds.
fn commit(c: Context, arena: std.mem.Allocator, row: store.Feed, response: fetch.Response, started: i64, hash: []const u8) !Outcome {
    const now = c.now();
    const parsed = try feed.parse(arena, response.body);

    // Parsing and conversion ran with no lock held. Only this part is serialized.
    const entries = try prepareEntries(arena, parsed, response.final_url);
    c.lock();
    defer c.unlock();
    const result = try c.db.ingest(row.id, entries, now);

    const poll = adaptPollSeconds(try c.db.postingGapSeconds(row.id), parsed.poll_seconds_hint, c.min_poll_seconds, row.poll_seconds);
    try c.db.updateFeed(.{
        .id = row.id,
        .url = if (response.moved_permanently) response.final_url else null,
        .site_url = cleanLine(arena, parsed.site_url),
        .title = cleanLine(arena, parsed.title),
        .description = cleanLine(arena, parsed.description),
        .format = @tagName(parsed.format),
        .etag = response.etag,
        .last_modified = response.last_modified,
        .poll_seconds = poll,
        .skip_hours = parsed.skip_hours,
        .skip_days = parsed.skip_days,
        .next_fetch_at = nextPollAt(now, poll, parsed.skip_hours, parsed.skip_days),
        .last_fetch_at = now,
        .last_success_at = now,
        .error_count = 0,
    });
    try c.db.logFetch(.{
        .feed_id = row.id,
        .started_at = started,
        .duration_ms = now - started,
        .http_status = 200,
        .bytes = response.body.len,
        .raw_sha256 = hash,
        .new_entries = result.new,
        .updated_entries = result.updated,
    });
    return .{ .status = .updated, .new = result.new, .updated = result.updated };
}

/// Turns parsed entries into rows: links resolved, HTML converted, text cleaned.
pub fn prepareEntries(arena: std.mem.Allocator, parsed: feed.Feed, feed_url: []const u8) ![]const store.NewEntry {
    const feed_base = if (parsed.base) |base| try url.resolve(arena, feed_url, base) else feed_url;

    // Links are resolved first, because identity falls back to the link.
    const resolved = try arena.alloc(feed.Entry, parsed.entries.len);
    for (parsed.entries, resolved) |entry, *out| {
        out.* = entry;
        if (entry.url) |value| out.url = try url.resolve(arena, entry.base orelse feed_base, value);
    }
    const identities = try feed.identities(arena, resolved);

    const rows = try arena.alloc(store.NewEntry, resolved.len);
    for (resolved, identities, rows) |entry, identity, *row| {
        const base = if (entry.base) |value| try url.resolve(arena, feed_base, value) else entry.url orelse feed_base;
        const body = entry.content orelse entry.summary;
        const nodes: []const blocks.Node = if (body) |b| switch (b.kind) {
            .html => try core.html.toBlocks(arena, b.value, .{ .base = base }),
            .text => try core.html.textToBlocks(arena, b.value),
        } else &.{};

        var json: Io.Writer.Allocating = .init(arena);
        try blocks.writeJson(&json.writer, nodes);
        var text: Io.Writer.Allocating = .init(arena);
        try blocks.writeText(&text.writer, nodes);

        const title = cleanLine(arena, entry.title);
        const link = if (entry.url) |value| (if (url.isSafeLink(value)) cleanLine(arena, value) else null) else null;

        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        hash.update(title orelse "");
        hash.update("\x00");
        hash.update(link orelse "");
        hash.update("\x00");
        hash.update(json.written());
        const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);

        const enclosures = try arena.alloc(store.NewEnclosure, entry.enclosures.len);
        var enclosure_count: usize = 0;
        for (entry.enclosures) |enclosure| {
            const target = try url.resolve(arena, base, enclosure.url);
            if (!url.isHttp(target)) continue;
            enclosures[enclosure_count] = .{ .url = target, .mime_type = enclosure.mime_type, .bytes = enclosure.bytes };
            enclosure_count += 1;
        }

        row.* = .{
            .identity = identity,
            .url = link,
            .canonical_url = if (link) |value| try url.canonical(arena, value) else null,
            .title = title,
            .author = cleanLine(arena, entry.author),
            .published_at = entry.published_at,
            .updated_at = entry.updated_at,
            .content_blocks_json = json.written(),
            .content_text = text.written(),
            .content_hash = try arena.dupe(u8, &digest),
            .enclosures = enclosures[0..enclosure_count],
        };
    }
    return rows;
}

/// Removes control characters from a one-line field. Feed text ends up on
/// terminals, where an escape sequence is an attack.
fn cleanLine(arena: std.mem.Allocator, text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    const out = arena.alloc(u8, value.len) catch return null;
    var length: usize = 0;
    for (value) |c| {
        if (c == '\n' or c == '\t' or c == '\r') {
            out[length] = ' ';
            length += 1;
        } else if (c >= 0x20 and c != 0x7F) {
            out[length] = c;
            length += 1;
        }
    }
    const result = std.mem.trim(u8, out[0..length], " ");
    return if (result.len == 0) null else result;
}

/// Saves the body as raw/ab/abcd....gz. Writing to a temporary name first means
/// a crash cannot leave a half-written file under the final name.
fn saveRaw(c: Context, hash: []const u8, body: []const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, "raw/{s}", .{hash[0..2]});
    try c.home.createDirPath(c.io, directory);

    var name_buffer: [160]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "raw/{s}/{s}.gz", .{ hash[0..2], hash });
    var temp_buffer: [168]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buffer, "{s}.tmp", .{name});

    var out: Io.Writer.Allocating = try .initCapacity(c.gpa, 64 * 1024);
    defer out.deinit();
    const window = try c.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer c.gpa.free(window);
    var compress: std.compress.flate.Compress = try .init(&out.writer, window, .gzip, .default);
    try compress.writer.writeAll(body);
    try compress.finish();

    try c.home.writeFile(c.io, .{ .sub_path = temp, .data = out.written() });
    try c.home.rename(temp, c.home, name, c.io);
}

const testing = std.testing;

test "backoff doubles, is capped, and respects Retry-After" {
    try testing.expectEqual(3600, nextDelaySeconds(3600, 0, null, 0));
    try testing.expectEqual(7200, nextDelaySeconds(3600, 1, null, 0));
    try testing.expectEqual(14400, nextDelaySeconds(3600, 2, null, 0));
    try testing.expectEqual(86400, nextDelaySeconds(3600, 50, null, 0));
    try testing.expectEqual(90000, nextDelaySeconds(3600, 1, 90000, 0));
}

test "polling adapts to posting rate, within limits" {
    const quarter_hour = 900;
    try testing.expectEqual(quarter_hour, adaptPollSeconds(60, null, quarter_hour, 3600));
    try testing.expectEqual(3600, adaptPollSeconds(14400, null, quarter_hour, 3600));
    try testing.expectEqual(86400, adaptPollSeconds(30 * 86400, null, quarter_hour, 3600));
    try testing.expectEqual(3600, adaptPollSeconds(null, null, quarter_hour, 3600));
    try testing.expectEqual(7200, adaptPollSeconds(60, 7200, quarter_hour, 3600));
    try testing.expectEqual(86400, adaptPollSeconds(60, 999999, quarter_hour, 3600));
}

test "polls move out of skipped hours and days" {
    const thursday_midnight = 0;
    const hour = 3600 * 1000;
    try testing.expectEqual(5, afterSkipped(5, 0, 0));
    // Hours 0 and 1 are skipped, so the first free moment is 02:00.
    try testing.expectEqual(2 * hour, afterSkipped(thursday_midnight + 5, 0b11, 0));
    // Thursday is skipped, so the first free moment is Friday at 00:00.
    try testing.expectEqual(24 * hour, afterSkipped(thursday_midnight + 5, 0, 1 << 4));
    // Every hour is skipped, so the time stands.
    try testing.expectEqual(5, afterSkipped(5, (1 << 24) - 1, 0));
}

test "jitter stays within a tenth" {
    for (0..1000) |seed| {
        const delay = nextDelaySeconds(3600, 0, null, @intCast(seed * 7919));
        try testing.expect(delay >= 3600 and delay < 3960);
    }
}

test "entries are cleaned for storage" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try feed.parse(a,
        \\<rss><channel><item>
        \\<title>Bad&#27;[2J title</title>
        \\<link>/posts/1?utm_source=rss</link>
        \\<description>&lt;p&gt;See &lt;a href="two"&gt;this&lt;/a&gt;&lt;script&gt;x()&lt;/script&gt;&lt;/p&gt;</description>
        \\<enclosure url="a.mp3" type="audio/mpeg" length="9"/>
        \\</item></channel></rss>
    );
    const rows = try prepareEntries(a, parsed, "https://example.com/blog/feed.xml");
    const row = rows[0];
    try testing.expectEqualStrings("Bad[2J title", row.title.?);
    try testing.expectEqualStrings("https://example.com/posts/1?utm_source=rss", row.url.?);
    try testing.expectEqualStrings("https://example.com/posts/1", row.canonical_url.?);
    try testing.expectEqualStrings(row.url.?, row.identity);
    try testing.expectEqualStrings("See this", row.content_text);
    try testing.expect(std.mem.indexOf(u8, row.content_blocks_json, "https://example.com/posts/two") != null);
    try testing.expect(std.mem.indexOf(u8, row.content_blocks_json, "x()") == null);
    try testing.expectEqualStrings("https://example.com/posts/a.mp3", row.enclosures[0].url);
}

test "a javascript link is not stored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try feed.parse(a, "<rss><channel><item><title>t</title><link>javascript:alert(1)</link></item></channel></rss>");
    const rows = try prepareEntries(a, parsed, "https://example.com/feed");
    try testing.expectEqual(null, rows[0].url);
}

test "editing an entry changes its hash, and only then" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try feed.parse(a, "<rss><channel><item><guid>g</guid><description>a</description></item></channel></rss>");
    const same = try feed.parse(a, "<rss><channel><item><guid>g</guid><description>a</description></item></channel></rss>");
    const edit = try feed.parse(a, "<rss><channel><item><guid>g</guid><description>b</description></item></channel></rss>");
    const base = "https://example.com/";
    const hash = (try prepareEntries(a, one, base))[0].content_hash;
    try testing.expectEqualStrings(hash, (try prepareEntries(a, same, base))[0].content_hash);
    try testing.expect(!std.mem.eql(u8, hash, (try prepareEntries(a, edit, base))[0].content_hash));
}
