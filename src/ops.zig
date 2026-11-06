//! The operation registry: the one API of the system. See docs/api.md.
//!
//! Each operation is one struct. The socket dispatches on `name`, the CLI reuses
//! `Params` and `Result` as its wire types, and the MCP server generates its tools
//! from the same declarations, so that the surfaces cannot drift apart.

const std = @import("std");
const core = @import("core");
const pipeline = @import("pipeline.zig");
const service = @import("service.zig");
const store = @import("store.zig");

const Io = std.Io;
const Service = service.Service;
const blocks = core.blocks;

pub const Tier = enum(u8) {
    read,
    annotate,
    manage,

    pub fn allows(granted: Tier, required: Tier) bool {
        return @backingInt(granted) >= @backingInt(required);
    }
};

/// JSON that was already serialized, passed through without being parsed.
pub const RawJson = struct {
    json: []const u8,

    pub fn jsonStringify(self: RawJson, w: anytype) !void {
        try w.print("{s}", .{self.json});
    }
};

const Ok = struct { ok: bool = true };

/// Longer than any feed has existed, and small enough that the arithmetic cannot overflow.
const max_since_days = 100 * 366;

fn sinceMillis(s: *const Service, days: ?i64) ?i64 {
    return cutoffMillis(s.now(), days orelse return null);
}

fn cutoffMillis(now: i64, days: i64) i64 {
    return now - std.math.clamp(days, 0, max_since_days) * 24 * 3600 * 1000;
}

pub const FeedsList = struct {
    pub const name = "feeds.list";
    pub const tier: Tier = .read;
    pub const description = "List subscriptions, with health and unread counts.";
    pub const Params = struct {};
    pub const Result = struct { items: []const store.Feed };

    pub fn run(s: *Service, arena: std.mem.Allocator, _: Params) !Result {
        const reader = s.lockReader();
        defer s.unlockReader();
        return .{ .items = try reader.feeds(arena) };
    }
};

pub const FeedsAdd = struct {
    pub const name = "feeds.add";
    pub const tier: Tier = .manage;
    pub const description = "Subscribe to a feed or a site, and fetch it once.";
    pub const docs = .{
        .url = "Feed URL, or a site URL to search for a feed.",
        .allow_private_network = "Permit private addresses. Leave false unless the user asked.",
        .title = "Name to show instead of the feed's own title.",
        .folder = "Name of a top-level folder, created if missing.",
    };
    pub const Params = struct {
        url: []const u8,
        allow_private_network: bool = false,
        title: ?[]const u8 = null,
        folder: ?[]const u8 = null,
    };
    pub const Result = RefreshResult;

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const added = try pipeline.subscribe(s.context(), arena, p.url, p.allow_private_network, .{ .title = p.title, .folder = p.folder });
        s.eventsChanged();
        s.wake.set(s.io);
        return .from(added.id, added.outcome);
    }
};

pub const FeedsPreview = struct {
    pub const name = "feeds.preview";
    // It subscribes to nothing, but it does fetch any address it is given.
    pub const tier: Tier = .manage;
    pub const description = "Find the feeds behind a site or feed URL, with their latest titles, without subscribing.";
    pub const docs = .{
        .url = "Feed URL, or a site URL to search for feeds.",
        .allow_private_network = "Permit private addresses. Leave false unless the user asked.",
    };
    pub const Params = struct { url: []const u8, allow_private_network: bool = false };
    pub const Result = struct { items: []const pipeline.Candidate };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        return .{ .items = try pipeline.preview(s.context(), arena, p.url, p.allow_private_network) };
    }
};

pub const ConfigGet = struct {
    pub const name = "config.get";
    pub const tier: Tier = .read;
    pub const description = "Read the settings a client can change.";
    pub const agent_visible = false;
    pub const Params = struct {};
    pub const Result = struct { full_text: bool };

    pub fn run(s: *Service, _: std.mem.Allocator, _: Params) !Result {
        return .{ .full_text = s.full_text.load(.monotonic) };
    }
};

pub const ConfigSet = struct {
    pub const name = "config.set";
    pub const tier: Tier = .manage;
    pub const description = "Change a setting, now and for later runs.";
    pub const agent_visible = false;
    pub const Params = struct { full_text: ?bool = null };
    pub const Result = Ok;

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const enabled = p.full_text orelse return .{};
        try saveSetting(s, arena, "full_text", .{ .bool = enabled });
        s.full_text.store(enabled, .monotonic);
        s.full_text_wake.set(s.io);
        return .{};
    }

    /// Other keys in the file are the owner's, so they survive untouched.
    fn saveSetting(s: *Service, arena: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
        s.config_lock.lockUncancelable(s.io);
        defer s.config_lock.unlock(s.io);
        const text = s.home.readFileAlloc(s.io, "config.json", arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => "{}",
            else => return err,
        };
        var root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        if (root != .object) return error.InvalidConfig;
        try root.object.put(arena, key, value);
        const out = try std.fmt.allocPrint(arena, "{f}\n", .{std.json.fmt(root, .{ .whitespace = .indent_2 })});
        try s.home.writeFile(s.io, .{ .sub_path = "config.json.tmp", .data = out });
        try s.home.rename("config.json.tmp", s.home, "config.json", s.io);
    }
};

pub const FoldersList = struct {
    pub const name = "folders.list";
    pub const tier: Tier = .read;
    pub const description = "List folders.";
    pub const Params = struct {};
    pub const Result = struct { items: []const store.FolderRow };

    pub fn run(s: *Service, arena: std.mem.Allocator, _: Params) !Result {
        const reader = s.lockReader();
        defer s.unlockReader();
        return .{ .items = try reader.folders(arena) };
    }
};

pub const RefreshResult = struct {
    id: i64,
    status: []const u8,
    new: usize = 0,
    updated: usize = 0,
    message: ?[]const u8 = null,

    fn from(id: i64, outcome: pipeline.Outcome) RefreshResult {
        return .{ .id = id, .status = @tagName(outcome.status), .new = outcome.new, .updated = outcome.updated, .message = outcome.message };
    }
};

pub const FeedsRefresh = struct {
    pub const name = "feeds.refresh";
    pub const tier: Tier = .manage;
    pub const description = "Fetch one feed now and report the outcome.";
    pub const docs = .{ .id = "Feed id." };
    pub const Params = struct { id: i64 };
    pub const Result = RefreshResult;

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const reader = s.lockReader();
        const row = reader.getFeed(arena, p.id) catch |err| {
            s.unlockReader();
            return err;
        };
        s.unlockReader();
        const feed = row orelse return error.NoSuchFeed;

        const host = (try s.claim(feed.id, feed.url)) orelse return .{ .id = p.id, .status = "busy" };
        defer s.release(feed.id, host);
        const outcome = try pipeline.refresh(s.context(), arena, feed);
        s.eventsChanged();
        return .from(p.id, outcome);
    }
};

pub const FeedsRefreshAll = struct {
    pub const name = "feeds.refresh_all";
    pub const tier: Tier = .manage;
    pub const description = "Make every active feed due now. Returns without waiting.";
    pub const Params = struct {};
    pub const Result = struct { queued: usize };

    pub fn run(s: *Service, _: std.mem.Allocator, _: Params) !Result {
        const writer = s.lockWriter();
        const queued = writer.markAllDue() catch |err| {
            s.unlockWriter();
            return err;
        };
        s.unlockWriter();
        s.force();
        return .{ .queued = queued };
    }
};

pub const FeedsQueue = struct {
    pub const name = "feeds.queue";
    pub const tier: Tier = .manage;
    pub const description = "Make one feed due now. Returns without waiting.";
    pub const docs = .{ .id = "Feed id." };
    pub const Params = struct { id: i64 };
    pub const Result = Ok;

    pub fn run(s: *Service, _: std.mem.Allocator, p: Params) !Result {
        const writer = s.lockWriter();
        const found = writer.markDue(p.id) catch |err| {
            s.unlockWriter();
            return err;
        };
        s.unlockWriter();
        if (!found) return error.NoSuchFeed;
        s.force();
        return .{};
    }
};

pub const FeedsRemove = struct {
    pub const name = "feeds.remove";
    pub const tier: Tier = .manage;
    pub const description = "Unsubscribe, deleting the feed's entries.";
    pub const docs = .{ .id = "Feed id." };
    pub const Params = struct { id: i64 };
    pub const Result = Ok;

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const writer = s.lockWriter();
        const hashes = removed: {
            defer s.unlockWriter();
            const hashes = try writer.rawHashesOnlyFor(arena, p.id);
            if (!try writer.removeFeed(p.id)) return error.NoSuchFeed;
            break :removed hashes;
        };
        for (hashes) |hash| service.deleteRaw(s, arena, hash);
        return .{};
    }
};

pub const EntriesList = struct {
    pub const name = "entries.list";
    pub const tier: Tier = .read;
    pub const description = "List entries, newest first, with their titles and links but not their bodies. Use entries_get for a body.";
    pub const docs = .{
        .feed_id = "Only this feed.",
        .unread_only = "Only entries not yet read.",
        .starred_only = "Only starred entries.",
        .since_days = "Only entries from the last N days.",
        .limit = "Page size, up to 1000.",
        .before = "The next_cursor from a previous page.",
        .with_summary = "Include the start of each entry's text.",
    };
    pub const Params = struct {
        feed_id: ?i64 = null,
        unread_only: bool = false,
        starred_only: bool = false,
        since_days: ?i64 = null,
        limit: i64 = 50,
        before: ?[]const u8 = null,
        with_summary: bool = false,
    };
    pub const Result = struct { items: []const store.EntrySummary, next_cursor: ?[]const u8 };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const limit = std.math.clamp(p.limit, 1, 1000);
        const reader = s.lockReader();
        defer s.unlockReader();
        const rows = try reader.listEntries(arena, .{
            .feed_id = p.feed_id,
            .unread_only = p.unread_only,
            .starred_only = p.starred_only,
            .limit = limit,
            .since = sinceMillis(s, p.since_days),
            .before = if (p.before) |text| try parseCursor(text) else null,
            .with_summary = p.with_summary,
        });
        var cursor: ?[]const u8 = null;
        if (rows.len == limit) {
            const last = rows[rows.len - 1];
            cursor = try std.fmt.allocPrint(arena, "{d}:{d}", .{ last.sort_at, last.id });
        }
        return .{ .items = rows, .next_cursor = cursor };
    }

    fn parseCursor(text: []const u8) !store.Cursor {
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.InvalidCursor;
        return .{
            .sort_at = std.fmt.parseInt(i64, text[0..colon], 10) catch return error.InvalidCursor,
            .id = std.fmt.parseInt(i64, text[colon + 1 ..], 10) catch return error.InvalidCursor,
        };
    }
};

pub const EntriesGet = struct {
    pub const name = "entries.get";
    pub const tier: Tier = .read;
    pub const description = "Read one entry in full.";
    pub const docs = .{
        .id = "Entry id.",
        .format = "One of markdown, text or blocks.",
    };
    pub const Params = struct { id: i64, format: []const u8 = "markdown" };
    pub const Result = struct {
        id: i64,
        feed_id: i64,
        feed_title: ?[]const u8,
        title: ?[]const u8,
        url: ?[]const u8,
        author: ?[]const u8,
        published_at: ?i64,
        first_seen_at: i64,
        read: bool,
        starred: bool,
        format: []const u8,
        body: []const u8,
        /// Feed text may contain instructions aimed at whoever reads it.
        trust: []const u8 = "untrusted-feed-content",
    };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const reader = s.lockReader();
        const row = reader.getEntry(arena, p.id) catch |err| {
            s.unlockReader();
            return err;
        };
        s.unlockReader();
        const entry = row orelse return error.NoSuchEntry;

        var body: []const u8 = undefined;
        if (std.mem.eql(u8, p.format, "blocks")) {
            body = entry.content_blocks_json;
        } else if (std.mem.eql(u8, p.format, "text")) {
            body = entry.content_text;
        } else if (std.mem.eql(u8, p.format, "markdown")) {
            var out: Io.Writer.Allocating = .init(arena);
            try blocks.writeMarkdown(&out.writer, try blocks.parseJson(arena, entry.content_blocks_json));
            body = out.written();
        } else return error.InvalidFormat;

        return .{
            .id = entry.id,
            .feed_id = entry.feed_id,
            .feed_title = entry.feed_title,
            .title = entry.title,
            .url = entry.url,
            .author = entry.author,
            .published_at = entry.published_at,
            .first_seen_at = entry.first_seen_at,
            .read = entry.read,
            .starred = entry.starred,
            .format = p.format,
            .body = body,
        };
    }
};

pub const EntriesSearch = struct {
    pub const name = "entries.search";
    pub const tier: Tier = .read;
    pub const description = "Search entries by words, newest first, with a snippet of each text match. All words must match the entry text or the name of its feed. Absence of results does not prove absence of news: try related words. Try this before db_query.";
    pub const docs = .{
        .query = "Words to find.",
        .limit = "Most results to return, up to 1000.",
        .unread_only = "Only entries not yet read.",
        .since_days = "Only entries from the last N days.",
    };
    pub const Params = struct { query: []const u8, limit: i64 = 30, unread_only: bool = false, since_days: ?i64 = null };
    pub const Result = struct { items: []const store.EntrySummary };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const reader = s.lockReader();
        defer s.unlockReader();
        return .{ .items = try reader.search(arena, p.query, .{
            .limit = std.math.clamp(p.limit, 1, 1000),
            .unread_only = p.unread_only,
            .since = sinceMillis(s, p.since_days),
        }) };
    }
};

pub const EntriesMark = struct {
    pub const name = "entries.mark";
    pub const tier: Tier = .annotate;
    pub const description = "Set or clear the read, starred and hidden state of an entry. Hidden entries leave lists and search.";
    pub const docs = .{
        .id = "Entry id.",
        .read = "True for read, false for unread.",
        .starred = "True to star, false to unstar.",
        .hidden = "True to hide, false to show again.",
    };
    pub const Params = struct { id: i64, read: ?bool = null, starred: ?bool = null, hidden: ?bool = null };
    pub const Result = Ok;

    pub fn run(s: *Service, _: std.mem.Allocator, p: Params) !Result {
        const writer = s.lockWriter();
        defer s.unlockWriter();
        if (!try writer.mark(p.id, .{ .read = p.read, .starred = p.starred, .hidden = p.hidden }, s.now())) return error.NoSuchEntry;
        return .{};
    }
};

pub const EntriesFetchFull = struct {
    pub const name = "entries.fetch_full";
    pub const tier: Tier = .annotate;
    pub const description = "Fetch an entry's article from its web page, replacing a short feed summary. This happens by itself for recent entries. Status is done, skipped, failed, or later when the site could not be reached.";
    pub const docs = .{ .id = "Entry id." };
    pub const Params = struct { id: i64 };
    pub const Result = struct { status: []const u8 };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const reader = s.lockReader();
        const row = reader.fullTextJob(arena, p.id) catch |err| {
            s.unlockReader();
            return err;
        };
        s.unlockReader();
        const job = row orelse return error.NoSuchEntry;
        const status = try service.fetchFullText(s, arena, job);
        s.eventsChanged();
        return .{ .status = status };
    }
};

pub const OpmlImport = struct {
    pub const name = "opml.import";
    pub const tier: Tier = .manage;
    pub const description = "Subscribe to everything in an OPML file. Feeds are fetched in the background.";
    /// Takes a path, which should not be open to agents.
    pub const agent_visible = false;
    pub const Params = struct { path: []const u8, allow_private_network: bool = false };
    pub const Result = struct { added: usize, existing: usize };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const bytes = try Io.Dir.cwd().readFileAlloc(s.io, p.path, arena, .limited(64 << 20));
        const text = try core.encoding.toUtf8(arena, bytes);
        const subscriptions = try core.opml.parse(arena, text);

        var folder_ids: std.AutoHashMapUnmanaged(*const core.opml.Folder, i64) = .empty;
        var result: Result = .{ .added = 0, .existing = 0 };
        const writer = s.lockWriter();
        defer s.unlockWriter();
        try writer.begin();
        errdefer writer.rollback();
        for (subscriptions) |subscription| {
            if (!core.url.isHttp(subscription.url)) continue;
            const folder_id = try folderId(arena, writer, &folder_ids, subscription.folder);
            if (try writer.importFeed(subscription.url, subscription.title, subscription.site_url, folder_id, p.allow_private_network, s.now())) {
                result.added += 1;
            } else {
                result.existing += 1;
            }
        }
        try writer.commit();
        s.wake.set(s.io);
        return result;
    }

    fn folderId(arena: std.mem.Allocator, writer: *store.Db, ids: *std.AutoHashMapUnmanaged(*const core.opml.Folder, i64), folder: ?*const core.opml.Folder) !?i64 {
        const current = folder orelse return null;
        if (ids.get(current)) |id| return id;
        const parent = try folderId(arena, writer, ids, current.parent);
        const id = try writer.ensureFolder(parent, current.name);
        try ids.put(arena, current, id);
        return id;
    }
};

pub const OpmlExport = struct {
    pub const name = "opml.export";
    pub const tier: Tier = .read;
    pub const description = "All subscriptions as an OPML document.";
    pub const Params = struct {};
    pub const Result = struct { opml: []const u8 };

    pub fn run(s: *Service, arena: std.mem.Allocator, _: Params) !Result {
        const reader = s.lockReader();
        const rows = rows: {
            defer s.unlockReader();
            break :rows .{ try reader.folders(arena), try reader.exportFeeds(arena) };
        };
        var out: Io.Writer.Allocating = .init(arena);
        try core.opml.write(&out.writer, "rss_ subscriptions", try outlines(arena, rows[0], rows[1], null, 0));
        return .{ .opml = out.written() };
    }

    fn outlines(arena: std.mem.Allocator, folders: []const store.FolderRow, feeds: []const store.ExportFeed, parent: ?i64, depth: usize) !([]const core.opml.Outline) {
        var list: std.ArrayList(core.opml.Outline) = .empty;
        if (depth < core.xml.max_depth) {
            for (folders) |folder| {
                if (folder.parent_id != parent) continue;
                const children = try outlines(arena, folders, feeds, folder.id, depth + 1);
                if (children.len != 0) try list.append(arena, .{ .title = folder.name, .children = children });
            }
        }
        for (feeds) |feed| {
            if (feed.folder_id != parent) continue;
            try list.append(arena, .{ .title = feed.title orelse feed.url, .url = feed.url, .site_url = feed.site_url });
        }
        return list.items;
    }
};

pub const StatsGet = struct {
    pub const name = "stats.get";
    pub const tier: Tier = .read;
    pub const description = "Counts, queue depth and daemon uptime.";
    pub const Params = struct {};
    pub const Result = struct {
        feeds: i64,
        entries: i64,
        unread: i64,
        due: i64,
        failing: i64,
        last_event_seq: i64,
        in_flight: usize,
        uptime_seconds: i64,
    };

    pub fn run(s: *Service, _: std.mem.Allocator, _: Params) !Result {
        const now = s.now();
        const reader = s.lockReader();
        const stats = reader.stats(now) catch |err| {
            s.unlockReader();
            return err;
        };
        s.unlockReader();
        return .{
            .feeds = stats.feeds,
            .entries = stats.entries,
            .unread = stats.unread,
            .due = stats.due,
            .failing = stats.failing,
            .last_event_seq = stats.last_event_seq,
            .in_flight = s.inFlight(),
            .uptime_seconds = @divTrunc(now - s.started_at, 1000),
        };
    }
};

pub const SchemaDescribe = struct {
    pub const name = "schema.describe";
    pub const tier: Tier = .read;
    pub const description = "The annotated database schema.";
    pub const Params = struct {};
    pub const Result = struct { schema: []const u8 };

    pub fn run(_: *Service, _: std.mem.Allocator, _: Params) !Result {
        return .{ .schema = @embedFile("schema") ++ "\n" ++ @embedFile("schema2") ++ "\n" ++ @embedFile("schema3") ++ "\n" ++ @embedFile("schema4") ++ "\n" ++ @embedFile("schema5") };
    }
};

pub const DbQuery = struct {
    pub const name = "db.query";
    pub const tier: Tier = .read;
    pub const description = "Run one read-only SQL statement. Read the rss://schema resource or call schema_describe first. Use this for questions the other tools cannot answer.";
    pub const docs = .{
        .sql = "One SELECT statement.",
        .limit = "Most rows to return, up to 10000.",
    };
    pub const Params = struct { sql: []const u8, limit: usize = 1000 };
    pub const Result = RawJson;

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        s.sandbox_lock.lockUncancelable(s.io);
        defer s.sandbox_lock.unlock(s.io);
        return .{ .json = try s.sandbox.query(arena, p.sql, @min(p.limit, 10_000)) };
    }
};

pub const EventsSince = struct {
    pub const name = "events.since";
    pub const tier: Tier = .read;
    pub const description = "Changes after a sequence number.";
    pub const docs = .{
        .seq = "Return events after this sequence number.",
        .limit = "Most events to return, up to 5000.",
    };
    pub const Params = struct { seq: i64 = 0, limit: i64 = 500 };
    pub const Result = struct { items: []const store.Event };

    pub fn run(s: *Service, arena: std.mem.Allocator, p: Params) !Result {
        const reader = s.lockReader();
        defer s.unlockReader();
        return .{ .items = try reader.eventsSince(arena, p.seq, std.math.clamp(p.limit, 1, 5000)) };
    }
};

pub const OpsList = struct {
    pub const name = "ops.list";
    pub const tier: Tier = .read;
    pub const description = "Every operation, with its tier.";
    pub const agent_visible = false;
    pub const Params = struct {};
    const Item = struct { name: []const u8, tier: []const u8, description: []const u8 };
    pub const Result = struct { items: []const Item };

    pub fn run(_: *Service, arena: std.mem.Allocator, _: Params) !Result {
        const items = try arena.alloc(Item, all.len);
        inline for (all, 0..) |op, i| {
            items[i] = .{ .name = op.name, .tier = @tagName(op.tier), .description = op.description };
        }
        return .{ .items = items };
    }
};

pub const DaemonStop = struct {
    pub const name = "daemon.stop";
    pub const tier: Tier = .manage;
    pub const description = "Shut the daemon down.";
    pub const agent_visible = false;
    pub const Params = struct {};
    pub const Result = Ok;

    pub fn run(s: *Service, _: std.mem.Allocator, _: Params) !Result {
        s.stop_requested.store(true, .release);
        return .{};
    }
};

pub const DaemonHousekeep = struct {
    pub const name = "daemon.housekeep";
    pub const tier: Tier = .manage;
    pub const description = "Trim old raw bodies and logs now. This also runs hourly.";
    pub const agent_visible = false;
    pub const Params = struct {};
    pub const Result = Ok;

    pub fn run(s: *Service, _: std.mem.Allocator, _: Params) !Result {
        try service.housekeep(s);
        return .{};
    }
};

pub const all = .{
    FeedsPreview,  FoldersList, ConfigGet,        ConfigSet,
    FeedsList,     FeedsAdd,    FeedsRefresh,     FeedsRefreshAll,
    FeedsQueue,    FeedsRemove, EntriesList,      EntriesGet,
    EntriesSearch, EntriesMark, EntriesFetchFull, OpmlImport,
    OpmlExport,    StatsGet,    SchemaDescribe,   DbQuery,
    EventsSince,   OpsList,     DaemonStop,       DaemonHousekeep,
};

pub const DispatchError = error{ UnknownMethod, TierDenied, InvalidParams };

/// Runs `method`, writing its result as JSON. Tiers are enforced here, on every
/// call, so that no adapter can forget to.
pub fn dispatch(s: *Service, arena: std.mem.Allocator, method: []const u8, params: std.json.Value, granted: Tier, w: *Io.Writer) !void {
    inline for (all) |op| {
        if (std.mem.eql(u8, method, op.name)) {
            if (!granted.allows(op.tier)) return error.TierDenied;
            const parsed = std.json.parseFromValueLeaky(op.Params, arena, params, .{ .ignore_unknown_fields = true }) catch return error.InvalidParams;
            const result = try op.run(s, arena, parsed);
            return w.print("{f}", .{std.json.fmt(result, .{})});
        }
    }
    return error.UnknownMethod;
}

test "any age parameter gives a sane cutoff" {
    const now = 1_800_000_000_000;
    try std.testing.expectEqual(now - 24 * 3600 * 1000, cutoffMillis(now, 1));
    try std.testing.expectEqual(now, cutoffMillis(now, std.math.minInt(i64)));
    try std.testing.expectEqual(cutoffMillis(now, max_since_days), cutoffMillis(now, std.math.maxInt(i64)));
}

test "tiers are ordered" {
    try std.testing.expect(Tier.manage.allows(.read));
    try std.testing.expect(Tier.annotate.allows(.annotate));
    try std.testing.expect(!Tier.read.allows(.annotate));
    try std.testing.expect(!Tier.annotate.allows(.manage));
}

test "the agent-facing read tier cannot change anything" {
    inline for (all) |op| {
        const writes = comptime std.mem.endsWith(u8, op.name, ".add") or std.mem.endsWith(u8, op.name, ".remove") or
            std.mem.endsWith(u8, op.name, ".mark") or std.mem.endsWith(u8, op.name, ".import") or
            std.mem.endsWith(u8, op.name, ".stop") or std.mem.endsWith(u8, op.name, ".housekeep") or std.mem.indexOf(u8, op.name, "refresh") != null;
        try std.testing.expect(!writes or op.tier != .read);
    }
}
