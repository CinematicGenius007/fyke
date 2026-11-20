//! The only file that contains SQL. See schema/0001_init.sql for the data model.

const std = @import("std");
const core = @import("core");
const blocks = core.blocks;

const Handle = opaque {};
const Stmt = opaque {};
extern fn sqlite3_open(path: [*:0]const u8, db: *?*Handle) c_int;
extern fn sqlite3_close(db: *Handle) c_int;
extern fn sqlite3_exec(db: *Handle, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*anyopaque) c_int;
extern fn sqlite3_errmsg(db: *Handle) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: *Handle, sql: [*:0]const u8, len: c_int, stmt: *?*Stmt, tail: ?*anyopaque) c_int;
extern fn sqlite3_finalize(stmt: *Stmt) c_int;
extern fn sqlite3_reset(stmt: *Stmt) c_int;
extern fn sqlite3_step(stmt: *Stmt) c_int;
extern fn sqlite3_bind_int64(stmt: *Stmt, i: c_int, v: i64) c_int;
extern fn sqlite3_bind_null(stmt: *Stmt, i: c_int) c_int;
extern fn sqlite3_bind_text(stmt: *Stmt, i: c_int, s: [*]const u8, n: c_int, destructor: ?*anyopaque) c_int;
extern fn sqlite3_column_int64(stmt: *Stmt, i: c_int) i64;
extern fn sqlite3_column_type(stmt: *Stmt, i: c_int) c_int;
extern fn sqlite3_column_text(stmt: *Stmt, i: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *Stmt, i: c_int) c_int;
extern fn sqlite3_last_insert_rowid(db: *Handle) i64;
extern fn sqlite3_changes(db: *Handle) c_int;
extern fn sqlite3_column_count(stmt: *Stmt) c_int;
extern fn sqlite3_column_name(stmt: *Stmt, i: c_int) [*:0]const u8;
extern fn sqlite3_column_double(stmt: *Stmt, i: c_int) f64;
extern fn sqlite3_stmt_readonly(stmt: *Stmt) c_int;
extern fn sqlite3_set_authorizer(db: *Handle, callback: *const AuthorizerFn, arg: ?*anyopaque) c_int;
extern fn sqlite3_progress_handler(db: *Handle, ops: c_int, callback: ?*const ProgressFn, arg: ?*anyopaque) void;
extern fn sqlite3_limit(db: *Handle, id: c_int, value: c_int) c_int;

const AuthorizerFn = fn (?*anyopaque, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int;
const ProgressFn = fn (?*anyopaque) callconv(.c) c_int;

const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_INTEGER = 1;
const SQLITE_FLOAT = 2;
const SQLITE_TEXT = 3;
const SQLITE_NULL = 5;
const SQLITE_DENY = 1;
const SQLITE_PRAGMA = 19;
const SQLITE_ATTACH = 24;
const SQLITE_LIMIT_LENGTH = 0;
const SQLITE_DETACH = 25;

pub const Error = error{ OutOfMemory, Sqlite };

const migrations = [_][*:0]const u8{
    @embedFile("schema"),
    @embedFile("schema2"),
    @embedFile("schema3"),
    @embedFile("schema4"),
    @embedFile("schema5"),
    @embedFile("schema6"),
    @embedFile("schema7"),
    @embedFile("schema8"),
};

pub const Feed = struct {
    id: i64,
    url: []const u8,
    site_url: ?[]const u8,
    title: ?[]const u8,
    format: ?[]const u8,
    status: []const u8,
    allow_private_network: bool,
    etag: ?[]const u8,
    last_modified: ?[]const u8,
    poll_seconds: i64,
    next_fetch_at: i64,
    last_success_at: ?i64,
    error_count: i64,
    last_error: ?[]const u8,
    unread: i64,
    entries: i64,
    folder_id: ?i64,
    skip_hours: i64,
    skip_days: i64,
    starred: i64,
};

pub const EntrySummary = struct {
    id: i64,
    feed_id: i64,
    feed_title: ?[]const u8,
    title: ?[]const u8,
    url: ?[]const u8,
    sort_at: i64,
    /// `sort_at` as RFC 3339, for readers that are not programs.
    date: []const u8,
    read: bool,
    starred: bool,
    later: bool = false,

    /// Matching text, from search only.
    snippet: ?[]const u8 = null,
    /// The start of the entry's text, for lists that show one.
    summary: ?[]const u8 = null,
};

pub const SearchOptions = struct {
    limit: i64 = 30,
    unread_only: bool = false,
    since: ?i64 = null,
};

pub const Entry = struct {
    id: i64,
    feed_id: i64,
    feed_title: ?[]const u8,
    title: ?[]const u8,
    url: ?[]const u8,
    author: ?[]const u8,
    published_at: ?i64,
    first_seen_at: i64,
    sort_at: i64,
    content_blocks_json: []const u8,
    content_text: []const u8,
    revision: i64,
    later: bool,
    read: bool,
    starred: bool,
    discussion_url: ?[]const u8 = null,
};

pub const NewEnclosure = struct {
    url: []const u8,
    mime_type: ?[]const u8,
    bytes: ?u64,
};

/// One entry, ready to store. Everything here has been cleaned by the pipeline.
pub const NewEntry = struct {
    identity: []const u8,
    url: ?[]const u8,
    canonical_url: ?[]const u8,
    /// Where readers discuss the entry, when the feed names a page for that.
    discussion_url: ?[]const u8 = null,
    title: ?[]const u8,
    author: ?[]const u8,
    published_at: ?i64,
    updated_at: ?i64,
    content_blocks_json: []const u8,
    content_text: []const u8,
    content_hash: []const u8,
    enclosures: []const NewEnclosure,
};

pub const FetchLog = struct {
    feed_id: i64,
    started_at: i64,
    duration_ms: i64,
    http_status: ?u16 = null,
    bytes: usize = 0,
    raw_sha256: ?[]const u8 = null,
    new_entries: usize = 0,
    updated_entries: usize = 0,
    err: ?[]const u8 = null,
};

/// The feed fields that a fetch can change. Null means leave as it is.
pub const FeedUpdate = struct {
    id: i64,
    url: ?[]const u8 = null,
    site_url: ?[]const u8 = null,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    format: ?[]const u8 = null,
    status: ?[]const u8 = null,
    etag: ?[]const u8 = null,
    last_modified: ?[]const u8 = null,
    poll_seconds: ?i64 = null,
    skip_hours: ?i64 = null,
    skip_days: ?i64 = null,
    next_fetch_at: i64,
    last_fetch_at: i64,
    last_success_at: ?i64 = null,
    error_count: i64,
    last_error: ?[]const u8 = null,
};

pub const Filter = struct {
    feed_id: ?i64 = null,
    /// This folder and every folder inside it.
    folder_id: ?i64 = null,
    unread_only: bool = false,
    starred_only: bool = false,
    limit: i64 = 50,
    /// Only entries at or after this time.
    since: ?i64 = null,
    /// Keyset cursor: return entries older than this (sort_at, id) position.
    before: ?Cursor = null,
    /// Include the start of each entry's text.
    with_summary: bool = false,
};

pub const Cursor = struct { sort_at: i64, id: i64 };

/// An entry whose article should be fetched from its page.
pub const FullTextJob = struct {
    id: i64,
    url: []const u8,
    title: ?[]const u8,
    text_length: i64,
    allow_private_network: bool,
    /// Tries so far that ended in a temporary failure.
    attempts: i64,
};

pub const DueFeed = struct { id: i64, url: []const u8 };

pub const Stats = struct {
    feeds: i64,
    entries: i64,
    unread: i64,
    due: i64,
    failing: i64,
    last_event_seq: i64,
};

pub const Event = struct {
    seq: i64,
    at: i64,
    type: []const u8,
    subject_id: ?i64,
};

pub const FolderRow = struct { id: i64, parent_id: ?i64, name: []const u8 };

pub const ExportFeed = struct {
    folder_id: ?i64,
    url: []const u8,
    site_url: ?[]const u8,
    title: ?[]const u8,
};

/// How a connection will be used. Only the writer may change the database, and
/// `.sandbox` is for SQL written by someone else.
pub const Role = enum { writer, reader, sandbox };

pub const Marks = struct {
    read: ?bool = null,
    starred: ?bool = null,
    hidden: ?bool = null,
    later: ?bool = null,
};

/// Binds a Zig value to a statement parameter. Text is not copied, so it must
/// outlive the step that uses it. Integers beyond SQLite's range saturate, since
/// some come straight from feeds.
fn bindValue(stmt: *Stmt, index: c_int, value: anytype) c_int {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => return if (value) |inner| bindValue(stmt, index, inner) else sqlite3_bind_null(stmt, index),
        .null => return sqlite3_bind_null(stmt, index),
        .bool => return sqlite3_bind_int64(stmt, index, @intFromBool(value)),
        .int, .comptime_int => return sqlite3_bind_int64(stmt, index, std.math.cast(i64, value) orelse std.math.maxInt(i64)),
        else => {
            const text: []const u8 = value;
            return sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null);
        },
    }
}

fn columnText(stmt: *Stmt, index: c_int, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    const pointer = sqlite3_column_text(stmt, index) orelse return "";
    return arena.dupe(u8, pointer[0..@intCast(sqlite3_column_bytes(stmt, index))]);
}

fn columnOptionalText(stmt: *Stmt, index: c_int, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    if (sqlite3_column_type(stmt, index) == SQLITE_NULL) return null;
    return try columnText(stmt, index, arena);
}

fn columnOptionalInt(stmt: *Stmt, index: c_int) ?i64 {
    if (sqlite3_column_type(stmt, index) == SQLITE_NULL) return null;
    return sqlite3_column_int64(stmt, index);
}

/// True if every word of a query starts a word in a feed's title or host names.
/// Prefixes let "zig" find "ziglang.org". Words under 3 letters never count.
fn feedMatches(query: []const u8, title: []const u8, site_host: []const u8, feed_host: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var any = false;
    while (words.next()) |word| {
        if (word.len < 3) return false;
        const sources = [_][]const u8{ title, site_host, feed_host };
        const found = for (sources) |source| {
            if (hasWordPrefix(source, word)) break true;
        } else false;
        if (!found) return false;
        any = true;
    }
    return any;
}

fn hasWordPrefix(text: []const u8, prefix: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
        if (i + prefix.len <= text.len and std.ascii.eqlIgnoreCase(text[i .. i + prefix.len], prefix)) return true;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
    }
    return false;
}

pub const Db = struct {
    handle: *Handle,

    /// Bounded by VM steps rather than by a clock, so results do not vary with load.
    const query_budget_callbacks = 200_000;
    /// A query returns no more than this many bytes of values.
    const query_max_bytes = 4 << 20;
    /// The longest string or blob a sandboxed statement may build. VM steps do not
    /// bound memory: one call such as `hex(zeroblob(n))` allocates in a single step.
    const query_max_value = 16 << 20;

    fn denyDangerous(_: ?*anyopaque, action: c_int, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8) callconv(.c) c_int {
        return switch (action) {
            SQLITE_PRAGMA, SQLITE_ATTACH, SQLITE_DETACH => SQLITE_DENY,
            else => 0,
        };
    }

    fn countProgress(arg: ?*anyopaque) callconv(.c) c_int {
        const count: *u32 = @ptrCast(@alignCast(arg.?));
        count.* += 1;
        return @intFromBool(count.* > query_budget_callbacks);
    }

    pub fn open(path: [:0]const u8, role: Role) Error!Db {
        var handle: ?*Handle = null;
        if (sqlite3_open(path, &handle) != 0) {
            if (handle) |h| _ = sqlite3_close(h);
            return error.Sqlite;
        }
        var db: Db = .{ .handle = handle.? };
        errdefer db.close();
        if (sqlite3_create_function_v2(
            db.handle,
            "article_host",
            1,
            1 | 0x800,
            null,
            articleHost,
            null,
            null,
            null,
        ) != 0) return error.Sqlite;
        if (sqlite3_create_function_v2(
            db.handle,
            "article_path",
            1,
            1 | 0x800,
            null,
            articlePath,
            null,
            null,
            null,
        ) != 0) return error.Sqlite;
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;");
        switch (role) {
            .writer => try db.migrate(),
            .reader => try db.exec("PRAGMA query_only=ON"),
            .sandbox => {
                try db.exec("PRAGMA query_only=ON");
                _ = sqlite3_limit(db.handle, SQLITE_LIMIT_LENGTH, query_max_value);
                // Pragmas are refused from here on, so query_only cannot be undone.
                if (sqlite3_set_authorizer(db.handle, denyDangerous, null) != 0) return error.Sqlite;
            },
        }
        return db;
    }

    pub fn close(db: *Db) void {
        _ = sqlite3_close(db.handle);
    }

    pub fn errorMessage(db: *const Db) []const u8 {
        return std.mem.span(sqlite3_errmsg(db.handle));
    }

    fn exec(db: *Db, sql: [*:0]const u8) Error!void {
        if (sqlite3_exec(db.handle, sql, null, null, null) != 0) return db.fail(sql);
    }

    fn migrate(db: *Db) Error!void {
        const stmt = try db.prepare("PRAGMA user_version", .{});
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_step(stmt);
        const version = sqlite3_column_int64(stmt, 0);
        for (migrations[@intCast(@min(version, migrations.len))..]) |sql| {
            try db.exec("BEGIN");
            errdefer db.exec("ROLLBACK") catch {};
            try db.exec(sql);
            try db.exec("COMMIT");
        }
    }

    fn prepare(db: *Db, sql: [*:0]const u8, args: anytype) Error!*Stmt {
        var stmt: ?*Stmt = null;
        if (sqlite3_prepare_v2(db.handle, sql, -1, &stmt, null) != 0) return db.fail(sql);
        inline for (args, 1..) |arg, index| {
            if (bindValue(stmt.?, index, arg) != 0) {
                _ = sqlite3_finalize(stmt.?);
                return error.Sqlite;
            }
        }
        return stmt.?;
    }

    /// Runs a statement that returns no rows.
    fn run(db: *Db, sql: [*:0]const u8, args: anytype) Error!void {
        const stmt = try db.prepare(sql, args);
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_DONE) return db.fail(sql);
    }

    /// Leaves SQLite's message in the log, since the error that reaches a client carries
    /// none. Only the first line of the statement is logged, never its values.
    fn fail(db: *Db, sql: [*:0]const u8) error{Sqlite} {
        const text = std.mem.span(sql);
        const head = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        std.debug.print("sqlite: {s}: {s}\n", .{ std.mem.span(sqlite3_errmsg(db.handle)), head });
        return error.Sqlite;
    }

    pub fn addFeed(db: *Db, url: []const u8, allow_private_network: bool, now: i64) Error!i64 {
        try db.run(
            \\INSERT INTO feeds (url, allow_private_network, created_at) VALUES (?1, ?2, ?3)
            \\ON CONFLICT (url) DO UPDATE SET status = CASE status WHEN 'gone' THEN 'active' ELSE status END
        , .{ url, allow_private_network, now });
        const stmt = try db.prepare("SELECT id FROM feeds WHERE url = ?1", .{url});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.Sqlite;
        return sqlite3_column_int64(stmt, 0);
    }

    const feed_columns =
        \\SELECT f.id, f.url, f.site_url, COALESCE(f.title_override, f.title), f.format, f.status,
        \\  f.allow_private_network, f.etag, f.last_modified, f.poll_seconds, f.next_fetch_at,
        \\  f.last_success_at, f.error_count, f.last_error,
        \\  (SELECT count(*) FROM entries e LEFT JOIN entry_state s ON s.entry_id = e.id
        \\     WHERE e.feed_id = f.id AND s.read_at IS NULL AND s.hidden_at IS NULL),
        \\  (SELECT count(*) FROM entries e WHERE e.feed_id = f.id),
        \\  f.folder_id, f.skip_hours, f.skip_days,
        \\  (SELECT count(*) FROM entry_state s JOIN entries e ON e.id = s.entry_id
        \\     WHERE s.starred_at IS NOT NULL AND e.feed_id = f.id)
        \\FROM feeds f
    ;

    fn readFeed(stmt: *Stmt, arena: std.mem.Allocator) error{OutOfMemory}!Feed {
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .url = try columnText(stmt, 1, arena),
            .site_url = try columnOptionalText(stmt, 2, arena),
            .title = try columnOptionalText(stmt, 3, arena),
            .format = try columnOptionalText(stmt, 4, arena),
            .status = try columnText(stmt, 5, arena),
            .allow_private_network = sqlite3_column_int64(stmt, 6) != 0,
            .etag = try columnOptionalText(stmt, 7, arena),
            .last_modified = try columnOptionalText(stmt, 8, arena),
            .poll_seconds = sqlite3_column_int64(stmt, 9),
            .next_fetch_at = sqlite3_column_int64(stmt, 10),
            .last_success_at = columnOptionalInt(stmt, 11),
            .error_count = sqlite3_column_int64(stmt, 12),
            .last_error = try columnOptionalText(stmt, 13, arena),
            .unread = sqlite3_column_int64(stmt, 14),
            .entries = sqlite3_column_int64(stmt, 15),
            .folder_id = columnOptionalInt(stmt, 16),
            .skip_hours = sqlite3_column_int64(stmt, 17),
            .skip_days = sqlite3_column_int64(stmt, 18),
            .starred = sqlite3_column_int64(stmt, 19),
        };
    }

    pub fn feeds(db: *Db, arena: std.mem.Allocator) Error![]const Feed {
        const stmt = try db.prepare(feed_columns ++ " ORDER BY f.id", .{});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(Feed) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) try rows.append(arena, try readFeed(stmt, arena));
        return rows.items;
    }

    pub fn getFeed(db: *Db, arena: std.mem.Allocator, id: i64) Error!?Feed {
        const stmt = try db.prepare(feed_columns ++ " WHERE f.id = ?1", .{id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return try readFeed(stmt, arena);
    }

    fn readFullTextJob(stmt: *Stmt, arena: std.mem.Allocator) error{OutOfMemory}!FullTextJob {
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .url = try columnText(stmt, 1, arena),
            .title = try columnOptionalText(stmt, 2, arena),
            .text_length = sqlite3_column_int64(stmt, 3),
            .allow_private_network = sqlite3_column_int64(stmt, 4) != 0,
            .attempts = sqlite3_column_int64(stmt, 5),
        };
    }

    /// Recent entries with little text that are waiting for a try, newest first.
    pub fn dueFullText(db: *Db, arena: std.mem.Allocator, since: i64, short_text: i64, limit: i64, now: i64) Error![]const FullTextJob {
        const stmt = try db.prepare(
            \\SELECT e.id, e.url, e.title, length(e.content_text), f.allow_private_network, e.full_attempts
            \\FROM entries e JOIN feeds f ON f.id = e.feed_id
            \\WHERE e.full_status IS NULL AND e.url IS NOT NULL AND e.sort_at >= ?1
            \\  AND length(e.content_text) < ?2 AND (e.full_retry_at IS NULL OR e.full_retry_at <= ?4)
            \\ORDER BY e.sort_at DESC LIMIT ?3
        , .{ since, short_text, limit, now });
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(FullTextJob) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) try rows.append(arena, try readFullTextJob(stmt, arena));
        return rows.items;
    }

    pub fn fullTextJob(db: *Db, arena: std.mem.Allocator, id: i64) Error!?FullTextJob {
        const stmt = try db.prepare(
            \\SELECT e.id, e.url, e.title, length(e.content_text), f.allow_private_network, e.full_attempts
            \\FROM entries e JOIN feeds f ON f.id = e.feed_id WHERE e.id = ?1 AND e.url IS NOT NULL
        , .{id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return try readFullTextJob(stmt, arena);
    }

    /// Replaces an entry's content with its extracted article.
    pub fn saveFullText(db: *Db, id: i64, blocks_json: []const u8, text: []const u8, now: i64) Error!void {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\UPDATE entries SET content_blocks_json = ?2, content_text = ?3, full_status = 'done',
            \\  full_attempted_at = ?4 WHERE id = ?1
        , .{ id, blocks_json, text, now });
        try db.run("INSERT INTO events (at, type, subject_id) VALUES (?1, 'entry.updated', ?2)", .{ now, id });
        try db.commit();
    }

    /// Settles recent entries that already have enough text, so that `dueFullText`
    /// reads only those still waiting. A publisher's edit clears the status again.
    pub fn skipLongEntries(db: *Db, since: i64, short_text: i64, now: i64) Error!void {
        try db.run(
            \\UPDATE entries SET full_status = 'skipped', full_attempted_at = ?3
            \\WHERE full_status IS NULL AND sort_at >= ?1 AND length(content_text) >= ?2
        , .{ since, short_text, now });
    }

    pub fn markFullText(db: *Db, id: i64, status: []const u8, now: i64) Error!void {
        try db.run("UPDATE entries SET full_status = ?2, full_attempted_at = ?3, full_retry_at = NULL WHERE id = ?1", .{ id, status, now });
    }

    /// Records a temporary failure, and when to try again.
    pub fn retryFullText(db: *Db, id: i64, attempts: i64, retry_at: i64, now: i64) Error!void {
        try db.run("UPDATE entries SET full_attempts = ?2, full_retry_at = ?3, full_attempted_at = ?4 WHERE id = ?1", .{ id, attempts, retry_at, now });
    }

    /// Moves an entry back in the queue without counting a try.
    pub fn postponeFullText(db: *Db, id: i64, retry_at: i64) Error!void {
        try db.run("UPDATE entries SET full_retry_at = ?2 WHERE id = ?1", .{ id, retry_at });
    }

    /// Feeds whose poll is due, oldest first.
    pub fn dueFeeds(db: *Db, arena: std.mem.Allocator, now: i64) Error![]const DueFeed {
        const stmt = try db.prepare(
            \\SELECT id, url FROM feeds WHERE status = 'active' AND next_fetch_at <= ?1
            \\ORDER BY next_fetch_at
        , .{now});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(DueFeed) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try rows.append(arena, .{ .id = sqlite3_column_int64(stmt, 0), .url = try columnText(stmt, 1, arena) });
        }
        return rows.items;
    }

    /// When the next poll falls due, if any feed is active.
    pub fn nextDueAt(db: *Db) Error!?i64 {
        const stmt = try db.prepare("SELECT min(next_fetch_at) FROM feeds WHERE status = 'active'", .{});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return columnOptionalInt(stmt, 0);
    }

    /// Makes every active feed due now, and returns how many.
    pub fn markAllDue(db: *Db) Error!usize {
        try db.run("UPDATE feeds SET next_fetch_at = 0 WHERE status = 'active'", .{});
        return @intCast(sqlite3_changes(db.handle));
    }

    /// Makes one feed due now. Returns false when no such active feed exists.
    pub fn markDue(db: *Db, id: i64) Error!bool {
        try db.run("UPDATE feeds SET next_fetch_at = 0 WHERE id = ?1 AND status = 'active'", .{id});
        return sqlite3_changes(db.handle) != 0;
    }

    /// Hashes of raw bodies that only this feed uses, for deleting with it.
    pub fn rawHashesOnlyFor(db: *Db, arena: std.mem.Allocator, id: i64) Error![]const []const u8 {
        const stmt = try db.prepare(
            \\SELECT DISTINCT raw_sha256 FROM fetch_log a WHERE feed_id = ?1 AND raw_sha256 IS NOT NULL
            \\  AND NOT EXISTS (SELECT 1 FROM fetch_log b WHERE b.raw_sha256 = a.raw_sha256 AND b.feed_id != ?1)
        , .{id});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList([]const u8) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) try rows.append(arena, try columnText(stmt, 0, arena));
        return rows.items;
    }

    /// Returns false when no such feed exists.
    pub fn removeFeed(db: *Db, id: i64) Error!bool {
        try db.run("DELETE FROM feeds WHERE id = ?1", .{id});
        return sqlite3_changes(db.handle) != 0;
    }

    /// Average seconds between the feed's last 10 entries, if it has at least 3.
    pub fn postingGapSeconds(db: *Db, feed_id: i64) Error!?i64 {
        const stmt = try db.prepare(
            \\SELECT count(*), max(sort_at) - min(sort_at) FROM
            \\  (SELECT sort_at FROM entries WHERE feed_id = ?1 ORDER BY sort_at DESC LIMIT 10)
        , .{feed_id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        const count = sqlite3_column_int64(stmt, 0);
        if (count < 3) return null;
        return @divTrunc(sqlite3_column_int64(stmt, 1), (count - 1) * 1000);
    }

    pub fn stats(db: *Db, now: i64) Error!Stats {
        const stmt = try db.prepare(
            \\SELECT (SELECT count(*) FROM feeds),
            \\  (SELECT count(*) FROM entries),
            \\  (SELECT count(*) FROM entries) - (SELECT count(*) FROM entry_state WHERE read_at IS NOT NULL OR hidden_at IS NOT NULL),
            \\  (SELECT count(*) FROM feeds WHERE status = 'active' AND next_fetch_at <= ?1),
            \\  (SELECT count(*) FROM feeds WHERE error_count > 0),
            \\  (SELECT COALESCE(max(seq), 0) FROM events)
        , .{now});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.Sqlite;
        return .{
            .feeds = sqlite3_column_int64(stmt, 0),
            .entries = sqlite3_column_int64(stmt, 1),
            .unread = sqlite3_column_int64(stmt, 2),
            .due = sqlite3_column_int64(stmt, 3),
            .failing = sqlite3_column_int64(stmt, 4),
            .last_event_seq = sqlite3_column_int64(stmt, 5),
        };
    }

    pub fn eventsSince(db: *Db, arena: std.mem.Allocator, seq: i64, limit: i64) Error![]const Event {
        const stmt = try db.prepare("SELECT seq, at, type, subject_id FROM events WHERE seq > ?1 ORDER BY seq LIMIT ?2", .{ seq, limit });
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(Event) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try rows.append(arena, .{
                .seq = sqlite3_column_int64(stmt, 0),
                .at = sqlite3_column_int64(stmt, 1),
                .type = try columnText(stmt, 2, arena),
                .subject_id = columnOptionalInt(stmt, 3),
            });
        }
        return rows.items;
    }

    /// Whether a sibling already uses this name. The constraint cannot answer this at
    /// the top level, because SQL's UNIQUE treats NULL parents as different.
    pub fn folderNameTaken(db: *Db, parent_id: ?i64, name: []const u8, except: ?i64) Error!bool {
        const stmt = try db.prepare("SELECT 1 FROM folders WHERE parent_id IS ?1 AND name = ?2 AND id IS NOT ?3", .{ parent_id, name, except });
        defer _ = sqlite3_finalize(stmt);
        return sqlite3_step(stmt) == SQLITE_ROW;
    }

    pub const FolderInfo = struct { parent_id: ?i64, name: []const u8 };

    pub fn folderInfo(db: *Db, arena: std.mem.Allocator, id: i64) Error!?FolderInfo {
        const stmt = try db.prepare("SELECT parent_id, name FROM folders WHERE id = ?1", .{id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return .{ .parent_id = columnOptionalInt(stmt, 0), .name = try columnText(stmt, 1, arena) };
    }

    pub fn renameFolder(db: *Db, id: i64, name: []const u8) Error!void {
        try db.run("UPDATE folders SET name = ?2 WHERE id = ?1", .{ id, name });
    }

    pub fn moveFolder(db: *Db, id: i64, parent_id: ?i64) Error!void {
        try db.run("UPDATE folders SET parent_id = ?2 WHERE id = ?1", .{ id, parent_id });
    }

    /// True when `id` is `ancestor` or sits anywhere inside it.
    pub fn folderIsWithin(db: *Db, id: i64, ancestor: i64) Error!bool {
        const stmt = try db.prepare(comptime folderTree("?1") ++ " WHERE id = ?2", .{ ancestor, id });
        defer _ = sqlite3_finalize(stmt);
        return sqlite3_step(stmt) == SQLITE_ROW;
    }

    /// Names of the folders that would clash if this folder's children moved up.
    pub fn folderChildClashes(db: *Db, id: i64, parent_id: ?i64) Error!bool {
        const stmt = try db.prepare(
            \\SELECT 1 FROM folders child JOIN folders sibling ON sibling.name = child.name
            \\WHERE child.parent_id = ?1 AND sibling.parent_id IS ?2 AND sibling.id != ?1
        , .{ id, parent_id });
        defer _ = sqlite3_finalize(stmt);
        return sqlite3_step(stmt) == SQLITE_ROW;
    }

    /// Deletes one folder and hands what it held to its parent.
    pub fn dissolveFolder(db: *Db, id: i64, parent_id: ?i64) Error!void {
        try db.begin();
        errdefer db.rollback();
        // A child may share this folder's name, and moves up beside it before it goes.
        try db.run("UPDATE folders SET name = 'removing ' || id || ' ' || name WHERE id = ?1", .{id});
        try db.run("UPDATE feeds SET folder_id = ?2 WHERE folder_id = ?1", .{ id, parent_id });
        try db.run("UPDATE folders SET parent_id = ?2 WHERE parent_id = ?1", .{ id, parent_id });
        try db.run("DELETE FROM folders WHERE id = ?1", .{id});
        try db.commit();
    }

    /// Subfolders go with it through the foreign key.
    pub fn deleteFolder(db: *Db, id: i64) Error!void {
        try db.run("DELETE FROM folders WHERE id = ?1", .{id});
    }

    /// Feeds in a folder and in every folder inside it.
    pub fn feedsInFolder(db: *Db, arena: std.mem.Allocator, id: i64) Error![]const i64 {
        const stmt = try db.prepare("SELECT id FROM feeds WHERE folder_id IN (" ++ comptime folderTree("?1") ++ ")", .{id});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(i64) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) try rows.append(arena, sqlite3_column_int64(stmt, 0));
        return rows.items;
    }

    /// An empty title goes back to the one the feed gives.
    pub fn setFeedTitle(db: *Db, id: i64, title: []const u8) Error!bool {
        try db.run("UPDATE feeds SET title_override = NULLIF(?2, '') WHERE id = ?1", .{ id, title });
        return sqlite3_changes(db.handle) != 0;
    }

    pub fn setFeedFolder(db: *Db, id: i64, folder_id: ?i64) Error!bool {
        try db.run("UPDATE feeds SET folder_id = ?2 WHERE id = ?1", .{ id, folder_id });
        return sqlite3_changes(db.handle) != 0;
    }

    /// Marks read everything in one feed, one folder tree, or, with neither, all feeds.
    pub fn markAllRead(db: *Db, feed_id: ?i64, folder_id: ?i64, now: i64) Error!usize {
        try db.run(
            \\INSERT INTO entry_state (entry_id, read_at)
            \\SELECT e.id, ?3 FROM entries e JOIN feeds f ON f.id = e.feed_id
            \\WHERE (?1 IS NULL OR e.feed_id = ?1) AND (?2 IS NULL OR f.folder_id IN (
        ++ comptime folderTree("?2") ++
            \\))
            \\ON CONFLICT (entry_id) DO UPDATE SET read_at = COALESCE(read_at, excluded.read_at)
        , .{ feed_id, folder_id, now });
        return @intCast(sqlite3_changes(db.handle));
    }

    pub const ArticleUse = struct {
        entries: i64,
        feeds: i64,
        text_bytes: i64,
        search_bytes: i64,
        other_bytes: i64,
        removable: i64,
        removable_bytes: i64,
    };

    /// What the database holds, by table, from SQLite's own page accounting. Reads
    /// every page, so this runs on request, never on a timer.
    pub fn articleUse(db: *Db, before: i64) Error!ArticleUse {
        const pages = try db.prepare(
            \\SELECT COALESCE(sum(CASE WHEN name = 'entries' THEN pgsize END), 0),
            \\  COALESCE(sum(CASE WHEN name LIKE 'entries_fts%' THEN pgsize END), 0),
            \\  COALESCE(sum(pgsize), 0)
            \\FROM dbstat
        , .{});
        defer _ = sqlite3_finalize(pages);
        if (sqlite3_step(pages) != SQLITE_ROW) return error.Sqlite;
        const text = sqlite3_column_int64(pages, 0);
        const search_bytes = sqlite3_column_int64(pages, 1);
        const total = sqlite3_column_int64(pages, 2);

        const stmt = try db.prepare("SELECT (SELECT count(*) FROM entries), (SELECT count(*) FROM feeds), " ++
            "count(*), COALESCE(sum(length(e.content_blocks_json) + length(e.content_text)), 0) " ++
            trimmable_entries, .{before});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.Sqlite;
        return .{
            .entries = sqlite3_column_int64(stmt, 0),
            .feeds = sqlite3_column_int64(stmt, 1),
            .text_bytes = text,
            .search_bytes = search_bytes,
            .other_bytes = total - text - search_bytes,
            .removable = sqlite3_column_int64(stmt, 2),
            .removable_bytes = sqlite3_column_int64(stmt, 3),
        };
    }

    const trimmable_entries =
        \\FROM entries e JOIN entry_state s ON s.entry_id = e.id
        \\WHERE s.read_at < ?1 AND e.first_seen_at < ?1 AND s.starred_at IS NULL AND e.content_text != ''
    ;

    /// Empties the bodies of entries read long ago and not starred. Age counts from
    /// reading and from first sight, never from publishing, so an old post read today
    /// is safe. The row and its content_hash stay, so a feed still listing the entry sees nothing new and it
    /// cannot come back as unread.
    pub fn trimEntries(db: *Db, before: i64) Error!usize {
        try db.run("UPDATE entries SET content_blocks_json = '[]', content_text = '' WHERE id IN (SELECT e.id " ++
            trimmable_entries ++ ")", .{before});
        return @intCast(sqlite3_changes(db.handle));
    }

    /// Returns the file space of deleted pages to the disk.
    pub fn compact(db: *Db) Error!void {
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM; PRAGMA wal_checkpoint(TRUNCATE);");
    }

    /// Finds or creates a folder. SQL's UNIQUE treats NULL parents as different,
    /// so this looks first rather than relying on the constraint.
    pub fn ensureFolder(db: *Db, parent_id: ?i64, name: []const u8) Error!i64 {
        const stmt = try db.prepare("SELECT id FROM folders WHERE parent_id IS ?1 AND name = ?2", .{ parent_id, name });
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) == SQLITE_ROW) return sqlite3_column_int64(stmt, 0);
        try db.run("INSERT INTO folders (parent_id, name) VALUES (?1, ?2)", .{ parent_id, name });
        return sqlite3_last_insert_rowid(db.handle);
    }

    /// Details chosen by the user when subscribing. Null leaves a value as it is.
    pub fn setFeedDetails(db: *Db, id: i64, title: ?[]const u8, folder_id: ?i64) Error!void {
        if (title) |text| try db.run("UPDATE feeds SET title_override = ?2 WHERE id = ?1", .{ id, text });
        if (folder_id) |folder| try db.run("UPDATE feeds SET folder_id = ?2 WHERE id = ?1", .{ id, folder });
    }

    /// Adds an imported subscription, due at once. Returns false if it already existed.
    pub fn importFeed(db: *Db, url: []const u8, title: ?[]const u8, site_url: ?[]const u8, folder_id: ?i64, allow_private_network: bool, now: i64) Error!bool {
        try db.run(
            \\INSERT OR IGNORE INTO feeds (url, title, site_url, folder_id, allow_private_network, created_at)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        , .{ url, title, site_url, folder_id, allow_private_network, now });
        return sqlite3_changes(db.handle) != 0;
    }

    pub fn begin(db: *Db) Error!void {
        try db.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(db: *Db) Error!void {
        try db.exec("COMMIT");
    }

    pub fn rollback(db: *Db) void {
        db.exec("ROLLBACK") catch {};
    }

    pub fn folders(db: *Db, arena: std.mem.Allocator) Error![]const FolderRow {
        const stmt = try db.prepare("SELECT id, parent_id, name FROM folders ORDER BY position, name", .{});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(FolderRow) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try rows.append(arena, .{
                .id = sqlite3_column_int64(stmt, 0),
                .parent_id = columnOptionalInt(stmt, 1),
                .name = try columnText(stmt, 2, arena),
            });
        }
        return rows.items;
    }

    pub fn exportFeeds(db: *Db, arena: std.mem.Allocator) Error![]const ExportFeed {
        const stmt = try db.prepare("SELECT folder_id, url, site_url, COALESCE(title_override, title) FROM feeds WHERE status != 'gone' ORDER BY id", .{});
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(ExportFeed) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try rows.append(arena, .{
                .folder_id = columnOptionalInt(stmt, 0),
                .url = try columnText(stmt, 1, arena),
                .site_url = try columnOptionalText(stmt, 2, arena),
                .title = try columnOptionalText(stmt, 3, arena),
            });
        }
        return rows.items;
    }

    /// Hashes of stored bodies past the newest `keep` for each feed, after clearing
    /// them from the log. Feeds can share a body, so a hash is returned only once
    /// no feed refers to it. The caller deletes the files.
    pub fn takeStaleRaw(db: *Db, arena: std.mem.Allocator, keep: i64) Error![]const []const u8 {
        var pairs: std.ArrayList(struct { feed_id: i64, hash: []const u8 }) = .empty;
        const stmt = try db.prepare(
            \\SELECT feed_id, raw_sha256 FROM (
            \\  SELECT feed_id, raw_sha256, row_number() OVER (PARTITION BY feed_id ORDER BY id DESC) AS position
            \\  FROM (SELECT max(id) AS id, feed_id, raw_sha256 FROM fetch_log
            \\        WHERE raw_sha256 IS NOT NULL GROUP BY feed_id, raw_sha256)
            \\) WHERE position > ?1
        , .{keep});
        defer _ = sqlite3_finalize(stmt);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            try pairs.append(arena, .{ .feed_id = sqlite3_column_int64(stmt, 0), .hash = try columnText(stmt, 1, arena) });
        }

        var stale: std.ArrayList([]const u8) = .empty;
        for (pairs.items) |pair| {
            try db.run("UPDATE fetch_log SET raw_sha256 = NULL WHERE feed_id = ?1 AND raw_sha256 = ?2", .{ pair.feed_id, pair.hash });
            const others = try db.prepare("SELECT 1 FROM fetch_log WHERE raw_sha256 = ?1 LIMIT 1", .{pair.hash});
            defer _ = sqlite3_finalize(others);
            if (sqlite3_step(others) != SQLITE_ROW) try stale.append(arena, pair.hash);
        }
        return stale.items;
    }

    /// Trims logs that would otherwise grow forever.
    pub fn prune(db: *Db, now: i64) Error!void {
        const week: i64 = 7 * 24 * 3600 * 1000;
        try db.run("DELETE FROM events WHERE at < ?1", .{now - week});
        try db.run("DELETE FROM fetch_log WHERE started_at < ?1 AND raw_sha256 IS NULL", .{now - 4 * week});
    }

    /// Runs one read-only statement written by a user or agent, and returns JSON:
    /// {"columns":[...],"rows":[[...]],"truncated":bool}, or {"error":"..."}.
    /// Call this only on a `.sandbox` connection.
    pub fn query(db: *Db, arena: std.mem.Allocator, sql: []const u8, max_rows: usize) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const sql_z = try arena.dupeSentinel(u8, sql, 0);

        var stmt: ?*Stmt = null;
        var tail: ?[*:0]const u8 = null;
        if (sqlite3_prepare_v2(db.handle, sql_z, -1, &stmt, @ptrCast(&tail)) != 0) {
            try writeError(w, db.errorMessage());
            return out.written();
        }
        if (stmt == null) {
            try writeError(w, "empty statement");
            return out.written();
        }
        defer _ = sqlite3_finalize(stmt.?);
        if (tail) |rest| {
            if (std.mem.trim(u8, std.mem.span(rest), " \t\r\n;").len != 0) {
                try writeError(w, "only one statement is allowed");
                return out.written();
            }
        }
        if (sqlite3_stmt_readonly(stmt.?) == 0) {
            try writeError(w, "only read-only statements are allowed");
            return out.written();
        }

        var steps: u32 = 0;
        sqlite3_progress_handler(db.handle, 1000, countProgress, &steps);
        defer sqlite3_progress_handler(db.handle, 0, null, null);

        const columns: usize = @intCast(sqlite3_column_count(stmt.?));
        w.writeAll("{\"columns\":[") catch return error.OutOfMemory;
        for (0..columns) |i| {
            if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
            blocks.writeString(w, std.mem.span(sqlite3_column_name(stmt.?, @intCast(i)))) catch return error.OutOfMemory;
        }
        w.writeAll("],\"rows\":[") catch return error.OutOfMemory;

        var rows: usize = 0;
        var value_bytes: usize = 0;
        var truncated = false;
        while (true) {
            const rc = sqlite3_step(stmt.?);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) {
                out.clearRetainingCapacity();
                try writeError(w, db.errorMessage());
                return out.written();
            }
            value_bytes += rowBytes(stmt.?, columns);
            if (rows == max_rows or value_bytes > query_max_bytes) {
                truncated = true;
                break;
            }
            if (rows != 0) w.writeByte(',') catch return error.OutOfMemory;
            rows += 1;
            w.writeByte('[') catch return error.OutOfMemory;
            for (0..columns) |i| {
                if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
                writeColumn(w, stmt.?, @intCast(i)) catch return error.OutOfMemory;
            }
            w.writeByte(']') catch return error.OutOfMemory;
        }
        w.print("],\"truncated\":{}}}", .{truncated}) catch return error.OutOfMemory;
        return out.written();
    }

    /// Text and blobs only, since asking for the size of a number converts it.
    fn rowBytes(stmt: *Stmt, columns: usize) usize {
        var total: usize = 0;
        for (0..columns) |i| {
            const type_code = sqlite3_column_type(stmt, @intCast(i));
            if (type_code == SQLITE_INTEGER or type_code == SQLITE_FLOAT or type_code == SQLITE_NULL) continue;
            total += @intCast(sqlite3_column_bytes(stmt, @intCast(i)));
        }
        return total;
    }

    fn writeError(w: *std.Io.Writer, message: []const u8) error{OutOfMemory}!void {
        w.writeAll("{\"error\":") catch return error.OutOfMemory;
        blocks.writeString(w, message) catch return error.OutOfMemory;
        w.writeByte('}') catch return error.OutOfMemory;
    }

    fn writeColumn(w: *std.Io.Writer, stmt: *Stmt, index: c_int) std.Io.Writer.Error!void {
        switch (sqlite3_column_type(stmt, index)) {
            SQLITE_NULL => try w.writeAll("null"),
            SQLITE_INTEGER => try w.print("{d}", .{sqlite3_column_int64(stmt, index)}),
            SQLITE_FLOAT => try w.print("{d}", .{sqlite3_column_double(stmt, index)}),
            SQLITE_TEXT => {
                const pointer = sqlite3_column_text(stmt, index) orelse return w.writeAll("null");
                try blocks.writeString(w, pointer[0..@intCast(sqlite3_column_bytes(stmt, index))]);
            },
            else => try w.print("\"<blob of {d} bytes>\"", .{sqlite3_column_bytes(stmt, index)}),
        }
    }

    pub fn updateFeed(db: *Db, update: FeedUpdate) Error!void {
        try db.run(
            \\UPDATE feeds SET
            \\  site_url = COALESCE(?2, site_url), title = COALESCE(?3, title),
            \\  description = COALESCE(?4, description), format = COALESCE(?5, format),
            \\  status = COALESCE(?6, status), etag = COALESCE(?7, etag),
            \\  last_modified = COALESCE(?8, last_modified), poll_seconds = COALESCE(?9, poll_seconds),
            \\  next_fetch_at = ?10, last_fetch_at = ?11, last_success_at = COALESCE(?12, last_success_at),
            \\  error_count = ?13, last_error = ?14, skip_hours = COALESCE(?15, skip_hours),
            \\  skip_days = COALESCE(?16, skip_days)
            \\WHERE id = ?1
        , .{
            update.id,           update.site_url,      update.title,         update.description,
            update.format,       update.status,        update.etag,          update.last_modified,
            update.poll_seconds, update.next_fetch_at, update.last_fetch_at, update.last_success_at,
            update.error_count,  update.last_error,    update.skip_hours,    update.skip_days,
        });
        if (update.url) |url| {
            // Another subscription may already hold the new URL. Keeping the old
            // one then is harmless, since it still redirects.
            db.run("UPDATE OR IGNORE feeds SET url = ?2 WHERE id = ?1", .{ update.id, url }) catch {};
        }
    }

    pub fn logFetch(db: *Db, log: FetchLog) Error!void {
        try db.run(
            \\INSERT INTO fetch_log (feed_id, started_at, duration_ms, http_status, bytes, raw_sha256,
            \\  new_entries, updated_entries, error) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        , .{ log.feed_id, log.started_at, log.duration_ms, log.http_status, log.bytes, log.raw_sha256, log.new_entries, log.updated_entries, log.err });
    }

    /// Hash of the last body that was stored and parsed, for skipping bodies that have
    /// not changed. A failed body does not count, or repeating it would read as success.
    pub fn lastRawHash(db: *Db, arena: std.mem.Allocator, feed_id: i64) Error!?[]const u8 {
        const stmt = try db.prepare(
            \\SELECT raw_sha256 FROM fetch_log WHERE feed_id = ?1 AND raw_sha256 IS NOT NULL AND error IS NULL
            \\ORDER BY id DESC LIMIT 1
        , .{feed_id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return try columnText(stmt, 0, arena);
    }

    pub const IngestResult = struct { new: usize = 0, updated: usize = 0 };

    /// Stores a batch in one transaction. Read state lives in `entry_state`, so
    /// nothing here can disturb it.
    pub fn ingest(db: *Db, feed_id: i64, entries: []const NewEntry, now: i64) Error!IngestResult {
        var result: IngestResult = .{};
        try db.exec("BEGIN IMMEDIATE");
        errdefer db.exec("ROLLBACK") catch {};

        for (entries) |entry| {
            const lookup = try db.prepare("SELECT id, content_hash FROM entries WHERE feed_id = ?1 AND identity = ?2", .{ feed_id, entry.identity });
            defer _ = sqlite3_finalize(lookup);

            if (sqlite3_step(lookup) == SQLITE_ROW) {
                const id = sqlite3_column_int64(lookup, 0);
                const pointer = sqlite3_column_text(lookup, 1) orelse continue;
                const stored = pointer[0..@intCast(sqlite3_column_bytes(lookup, 1))];
                if (std.mem.eql(u8, stored, entry.content_hash)) {
                    // The address is not part of the hash, so entries stored before it
                    // was kept gain it here without counting as changed.
                    if (entry.discussion_url) |address| {
                        try db.run("UPDATE entries SET discussion_url = ?2 WHERE id = ?1 AND discussion_url IS NOT ?2", .{ id, address });
                    }
                    continue;
                }
                try db.run(
                    \\UPDATE entries
                    \\SET url = ?2, article_host=article_host(?2),article_path=article_path(?2),canonical_url = ?3,
                    \\title = ?4, author = ?5,
                    \\  published_at = ?6, updated_at = ?7, content_blocks_json = ?8, content_text = ?9,
                    \\  content_hash = ?10, revision = revision + 1, full_status = NULL,
                    \\  full_attempts = 0, full_retry_at = NULL, discussion_url = ?11 WHERE id = ?1
                , .{ id, entry.url, entry.canonical_url, entry.title, entry.author, entry.published_at, entry.updated_at, entry.content_blocks_json, entry.content_text, entry.content_hash, entry.discussion_url });
                try db.run("INSERT INTO events (at, type, subject_id) VALUES (?1, 'entry.updated', ?2)", .{ now, id });
                result.updated += 1;
                continue;
            }

            // A date in the future must not pin an entry to the top of the timeline.
            // Many Atom feeds give only <updated>, which is still better than now.
            const sort_at = @min(entry.published_at orelse entry.updated_at orelse now, now);
            try db.run(
                \\INSERT INTO entries (feed_id, identity, url, canonical_url, title, author, published_at,
                \\updated_at, first_seen_at, sort_at, content_blocks_json, content_text,
                \\content_hash,article_host,article_path,discussion_url)
                \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,article_host(?3),article_path(?3),?14)
            , .{ feed_id, entry.identity, entry.url, entry.canonical_url, entry.title, entry.author, entry.published_at, entry.updated_at, now, sort_at, entry.content_blocks_json, entry.content_text, entry.content_hash, entry.discussion_url });
            const id = sqlite3_last_insert_rowid(db.handle);
            for (entry.enclosures) |enclosure| {
                try db.run("INSERT OR IGNORE INTO enclosures (entry_id, url, mime_type, bytes) VALUES (?1, ?2, ?3, ?4)", .{ id, enclosure.url, enclosure.mime_type, enclosure.bytes });
            }
            try db.run("INSERT INTO events (at, type, subject_id) VALUES (?1, 'entry.new', ?2)", .{ now, id });
            result.new += 1;
        }
        try db.exec("COMMIT");
        return result;
    }

    /// SQL for a folder's id and the ids of every folder inside it.
    fn folderTree(comptime id: []const u8) []const u8 {
        return "WITH RECURSIVE tree(id) AS (SELECT " ++ id ++
            " UNION ALL SELECT f.id FROM folders f JOIN tree ON f.parent_id = tree.id) SELECT id FROM tree";
    }

    const summary_columns =
        \\SELECT e.id, e.feed_id, COALESCE(f.title_override, f.title), e.title, e.url, e.sort_at,
        \\  s.read_at IS NOT NULL, s.starred_at IS NOT NULL,
        \\  CASE WHEN ?8 THEN substr(e.content_text, 1, 200) END, s.later_at IS NOT NULL
        \\FROM entries e JOIN feeds f ON f.id = e.feed_id LEFT JOIN entry_state s ON s.entry_id = e.id
    ;

    fn readSummary(stmt: *Stmt, arena: std.mem.Allocator) error{OutOfMemory}!EntrySummary {
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .feed_id = sqlite3_column_int64(stmt, 1),
            .feed_title = try columnOptionalText(stmt, 2, arena),
            .title = try columnOptionalText(stmt, 3, arena),
            .url = try columnOptionalText(stmt, 4, arena),
            .sort_at = sqlite3_column_int64(stmt, 5),
            .date = try formatDate(arena, sqlite3_column_int64(stmt, 5)),
            .read = sqlite3_column_int64(stmt, 6) != 0,
            .starred = sqlite3_column_int64(stmt, 7) != 0,
            .summary = try columnOptionalText(stmt, 8, arena),
            .later = sqlite3_column_int64(stmt, 9) != 0,
        };
    }

    fn formatDate(arena: std.mem.Allocator, millis: i64) error{OutOfMemory}![]const u8 {
        var buffer: [20]u8 = undefined;
        return arena.dupe(u8, core.dates.formatIso(&buffer, millis));
    }

    /// Timeline, newest first. Paging is by keyset, so it costs the same at any depth.
    pub fn listEntries(db: *Db, arena: std.mem.Allocator, filter: Filter) Error![]const EntrySummary {
        const stmt = try db.prepare(summary_columns ++
            \\ WHERE (?1 IS NULL OR e.feed_id = ?1)
            \\   AND (?2 = 0 OR s.read_at IS NULL)
            \\   AND (?3 = 0 OR s.starred_at IS NOT NULL)
            \\   AND (?4 IS NULL OR (e.sort_at, e.id) < (?4, ?5))
            \\   AND (?7 IS NULL OR e.sort_at >= ?7)
            \\   AND (?9 IS NULL OR f.folder_id IN (
        ++ comptime folderTree("?9") ++
            \\   ))
            \\   AND s.hidden_at IS NULL
            \\ ORDER BY e.sort_at DESC, e.id DESC LIMIT ?6
        , .{
            filter.feed_id,
            filter.unread_only,
            filter.starred_only,
            if (filter.before) |c| c.sort_at else null,
            if (filter.before) |c| c.id else null,
            filter.limit,
            filter.since,
            filter.with_summary,
            filter.folder_id,
        });
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(EntrySummary) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) try rows.append(arena, try readSummary(stmt, arena));
        return rows.items;
    }

    pub fn getEntry(db: *Db, arena: std.mem.Allocator, id: i64) Error!?Entry {
        const stmt = try db.prepare(
            \\SELECT e.id, e.feed_id, COALESCE(f.title_override, f.title), e.title, e.url, e.author,
            \\  e.published_at, e.first_seen_at, e.sort_at, e.content_blocks_json, e.content_text,
            \\  e.revision, s.read_at IS NOT NULL, s.starred_at IS NOT NULL, s.later_at IS NOT NULL,
            \\  e.discussion_url
            \\FROM entries e JOIN feeds f ON f.id = e.feed_id LEFT JOIN entry_state s ON s.entry_id = e.id
            \\WHERE e.id = ?1
        , .{id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return null;
        return .{
            .id = sqlite3_column_int64(stmt, 0),
            .feed_id = sqlite3_column_int64(stmt, 1),
            .feed_title = try columnOptionalText(stmt, 2, arena),
            .title = try columnOptionalText(stmt, 3, arena),
            .url = try columnOptionalText(stmt, 4, arena),
            .author = try columnOptionalText(stmt, 5, arena),
            .published_at = columnOptionalInt(stmt, 6),
            .first_seen_at = sqlite3_column_int64(stmt, 7),
            .sort_at = sqlite3_column_int64(stmt, 8),
            .content_blocks_json = try columnText(stmt, 9, arena),
            .content_text = try columnText(stmt, 10, arena),
            .revision = sqlite3_column_int64(stmt, 11),
            .read = sqlite3_column_int64(stmt, 12) != 0,
            .starred = sqlite3_column_int64(stmt, 13) != 0,
            .later = sqlite3_column_int64(stmt, 14) != 0,
            .discussion_url = try columnOptionalText(stmt, 15, arena),
        };
    }

    /// Full-text search, newest first. See the spike results for why relevance
    /// ordering is not the default. Each word is quoted, so input cannot use FTS5
    /// query syntax and cannot produce a syntax error.
    ///
    /// Only the 2,000 most recently stored entries that match and pass the filters
    /// are considered. Snippets are costly, so the query narrows to the final rows
    /// first and builds snippets for those alone.
    pub fn search(db: *Db, arena: std.mem.Allocator, words_text: []const u8, options: SearchOptions) Error![]const EntrySummary {
        var match: std.ArrayList(u8) = .empty;
        var words = std.mem.tokenizeAny(u8, words_text, " \t\r\n");
        while (words.next()) |word| {
            if (match.items.len != 0) try match.append(arena, ' ');
            try match.append(arena, '"');
            for (word) |c| {
                if (c == '"') try match.append(arena, '"');
                try match.append(arena, c);
            }
            try match.append(arena, '"');
        }
        if (match.items.len == 0) return &.{};

        const text_rows = try db.searchText(arena, match.items, options);
        return db.addFeedMatches(arena, words_text, text_rows, options);
    }

    /// An entry can be about a subject without naming it, such as "0.17.1 Released"
    /// in a feed called "News" on ziglang.org. So a feed whose name or address
    /// matches every word contributes its entries too.
    fn addFeedMatches(db: *Db, arena: std.mem.Allocator, words_text: []const u8, text_rows: []const EntrySummary, options: SearchOptions) Error![]const EntrySummary {
        const feeds_stmt = try db.prepare("SELECT id, COALESCE(title_override, title), site_url, url FROM feeds", .{});
        defer _ = sqlite3_finalize(feeds_stmt);

        var rows: std.ArrayList(EntrySummary) = .empty;
        try rows.appendSlice(arena, text_rows);
        var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
        for (text_rows) |row| try seen.put(arena, row.id, {});

        var added = false;
        while (sqlite3_step(feeds_stmt) == SQLITE_ROW) {
            const title = try columnOptionalText(feeds_stmt, 1, arena);
            const site = try columnOptionalText(feeds_stmt, 2, arena);
            const url = try columnText(feeds_stmt, 3, arena);
            if (!feedMatches(words_text, title orelse "", core.url.split(site orelse "").authority orelse "", core.url.split(url).authority orelse "")) continue;
            const entries = try db.listEntries(arena, .{
                .feed_id = sqlite3_column_int64(feeds_stmt, 0),
                .unread_only = options.unread_only,
                .since = options.since,
                .limit = options.limit,
            });
            for (entries) |row| {
                if ((try seen.getOrPut(arena, row.id)).found_existing) continue;
                try rows.append(arena, row);
                added = true;
            }
        }
        if (!added) return text_rows;

        std.mem.sort(EntrySummary, rows.items, {}, struct {
            fn newerFirst(_: void, a: EntrySummary, b: EntrySummary) bool {
                return if (a.sort_at != b.sort_at) a.sort_at > b.sort_at else a.id > b.id;
            }
        }.newerFirst);
        return rows.items[0..@min(rows.items.len, @as(usize, @intCast(options.limit)))];
    }

    fn searchText(db: *Db, arena: std.mem.Allocator, match: []const u8, options: SearchOptions) Error![]const EntrySummary {
        const stmt = try db.prepare(
            \\WITH matches AS (
            \\  SELECT e.id, e.sort_at FROM entries_fts
            \\  CROSS JOIN entries e ON e.id = entries_fts.rowid
            \\  LEFT JOIN entry_state s ON s.entry_id = e.id
            \\  WHERE entries_fts MATCH ?1 AND (?3 = 0 OR s.read_at IS NULL)
            \\    AND (?4 IS NULL OR e.sort_at >= ?4) AND s.hidden_at IS NULL
            \\  ORDER BY entries_fts.rowid DESC LIMIT 2000
            \\), chosen AS (
            \\  SELECT id FROM matches ORDER BY sort_at DESC, id DESC LIMIT ?2
            \\)
            \\SELECT e.id, e.feed_id, COALESCE(f.title_override, f.title), e.title, e.url, e.sort_at,
            \\  s.read_at IS NOT NULL, s.starred_at IS NOT NULL,
            \\  snippet(entries_fts, -1, '', '', '...', 32), s.later_at IS NOT NULL
            \\FROM entries_fts JOIN entries e ON e.id = entries_fts.rowid
            \\JOIN feeds f ON f.id = e.feed_id LEFT JOIN entry_state s ON s.entry_id = e.id
            \\WHERE entries_fts MATCH ?1 AND entries_fts.rowid IN (SELECT id FROM chosen)
            \\ORDER BY e.sort_at DESC, e.id DESC
        , .{ match, options.limit, options.unread_only, options.since });
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(EntrySummary) = .empty;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            var row = try readSummary(stmt, arena);
            row.snippet = try columnOptionalText(stmt, 8, arena);
            row.summary = null;
            try rows.append(arena, row);
        }
        return rows.items;
    }

    /// Returns false when no such entry exists.
    pub fn mark(db: *Db, id: i64, marks: Marks, now: i64) Error!bool {
        const exists = try db.prepare("SELECT 1 FROM entries WHERE id = ?1", .{id});
        defer _ = sqlite3_finalize(exists);
        if (sqlite3_step(exists) != SQLITE_ROW) return false;

        try db.run("INSERT OR IGNORE INTO entry_state (entry_id) VALUES (?1)", .{id});
        if (marks.read) |read| {
            try db.run("UPDATE entry_state SET read_at = ?2 WHERE entry_id = ?1", .{ id, if (read) now else null });
        }
        if (marks.starred) |starred| {
            try db.run("UPDATE entry_state SET starred_at = ?2 WHERE entry_id = ?1", .{ id, if (starred) now else null });
        }
        if (marks.hidden) |hidden| {
            try db.run("UPDATE entry_state SET hidden_at = ?2 WHERE entry_id = ?1", .{ id, if (hidden) now else null });
        }
        if (marks.later) |later| try db.run(
            \\UPDATE entry_state
            \\SET later_at=?2
            \\WHERE entry_id=?1
        , .{ id, if (later) now else null });
        return true;
    }

    /// Reads JSON-shaped rows, decoding columns ending in _json into structured values.
    pub fn featureRows(db: *Db, a: std.mem.Allocator, sql: [*:0]const u8, args: anytype) ![]const std.json.Value {
        const stmt = try db.prepare(sql, args);
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(std.json.Value) = .empty;
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return error.Sqlite;
            var obj: std.json.ObjectMap = .empty;
            for (0..@intCast(sqlite3_column_count(stmt))) |i| {
                const col: c_int = @intCast(i);
                const name = std.mem.span(sqlite3_column_name(stmt, col));
                const value: std.json.Value = switch (sqlite3_column_type(stmt, col)) {
                    SQLITE_NULL => .null,
                    SQLITE_INTEGER => .{ .integer = sqlite3_column_int64(stmt, col) },
                    else => .{ .string = try columnText(stmt, col, a) },
                };
                if (std.mem.endsWith(u8, name, "_json") and value == .string) {
                    try obj.put(
                        a,
                        try a.dupe(u8, name[0 .. name.len - 5]),
                        try std.json.parseFromSliceLeaky(std.json.Value, a, value.string, .{}),
                    );
                } else try obj.put(a, try a.dupe(u8, name), value);
            }
            try rows.append(a, .{ .object = obj });
        }
        return rows.items;
    }

    /// Appends a change notification inside the caller’s write transaction.
    /// Returns the event's sequence number.
    pub fn featureEvent(db: *Db, kind: []const u8, id: i64, now: i64) !i64 {
        try db.run(
            \\INSERT INTO events(at,type,subject_id)
            \\VALUES(?1,?2,?3)
        , .{ now, kind, id });
        return sqlite3_last_insert_rowid(db.handle);
    }

    /// Rejects feed and folder ids that no longer exist before executing a selection.
    pub fn validateRule(db: *Db, a: std.mem.Allocator, r: core.selector.Rule) !void {
        const stmt = try db.prepare(
            \\SELECT EXISTS(SELECT 1
            \\FROM json_each(?1) x
            \\WHERE NOT EXISTS(SELECT 1
            \\FROM feeds
            \\WHERE id=x.value)),EXISTS(SELECT 1
            \\FROM json_each(?2) x
            \\WHERE NOT EXISTS(SELECT 1
            \\FROM folders
            \\WHERE id=x.value))
        , .{
            try std.fmt.allocPrint(
                a,
                "{f}",
                .{std.json.fmt(r.feeds, .{})},
            ),
            try std.fmt.allocPrint(
                a,
                "{f}",
                .{std.json.fmt(r.folders, .{})},
            ),
        });
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.Sqlite;
        if (sqlite3_column_int64(stmt, 0) != 0) return error.NoSuchFeed;
        if (sqlite3_column_int64(stmt, 1) != 0) return error.NoSuchFolder;
    }

    /// Resolves source names and renders the selection through the pure selector module.
    pub fn ruleSentence(db: *Db, a: std.mem.Allocator, r: core.selector.Rule) ![]const u8 {
        var feeds_names: std.ArrayList(core.selector.Name) = .empty;
        var folders_names: std.ArrayList(core.selector.Name) = .empty;
        for (try db.featureRows(a,
            \\SELECT id,coalesce(title_override,title,url) AS name
            \\FROM feeds
        , .{})) |f| try feeds_names.append(
            a,
            .{
                .id = f.object.get("id").?.integer,
                .name = f.object.get("name").?.string,
            },
        );
        for (try db.folders(a)) |f| try folders_names.append(a, .{ .id = f.id, .name = f.name });
        return core.selector.sentence(a, r, feeds_names.items, folders_names.items);
    }
    // Parameters 1–5 are the normalized rule, FTS query, publication cutoff and
    // arrival bounds. Paging uses 6–8; the separately chosen host predicate uses 9.
    const rule_from =
        \\ FROM entries e
        \\ JOIN feeds f ON f.id = e.feed_id
        \\ LEFT JOIN entry_state s ON s.entry_id = e.id
        \\ WHERE s.hidden_at IS NULL
        \\   AND (
        \\     json_array_length(?1, '$.feeds') + json_array_length(?1, '$.folders') = 0
        \\     OR e.feed_id IN (SELECT value FROM json_each(?1, '$.feeds'))
        \\     OR f.folder_id IN (
        \\       WITH RECURSIVE tree(id) AS (
        \\         SELECT value FROM json_each(?1, '$.folders')
        \\         UNION
        \\         SELECT folders.id
        \\         FROM folders
        \\         JOIN tree ON folders.parent_id = tree.id
        \\       )
        \\       SELECT id FROM tree
        \\     )
        \\   )
        \\   AND (
        \\     json_extract(?1, '$.state') = 'any'
        \\     OR (json_extract(?1, '$.state') = 'unread' AND s.read_at IS NULL)
        \\     OR (json_extract(?1, '$.state') = 'starred' AND s.starred_at IS NOT NULL)
        \\     OR (json_extract(?1, '$.state') = 'later' AND s.later_at IS NOT NULL)
        \\   )
        \\   AND (?2 IS NULL OR e.id IN (SELECT rowid FROM entries_fts WHERE entries_fts MATCH ?2))
        \\   AND (?3 IS NULL OR e.sort_at >= ?3)
        \\   AND (?4 IS NULL OR e.first_seen_at > ?4)
        \\   AND (?5 IS NULL OR e.first_seen_at <= ?5)
        \\   AND (
        \\     (json_extract(?1, '$.path_prefix') IS NULL AND json_array_length(?1, '$.exclude_path_prefix') = 0)
        \\     OR (
        \\       e.article_path IS NOT NULL
        \\       AND (
        \\         json_extract(?1, '$.path_prefix') IS NULL
        \\         OR json_extract(?1, '$.path_prefix') = '/'
        \\         OR e.article_path = json_extract(?1, '$.path_prefix')
        \\         OR substr(e.article_path, 1, length(json_extract(?1, '$.path_prefix')) + 1)
        \\           = json_extract(?1, '$.path_prefix') || '/'
        \\       )
        \\       AND NOT EXISTS (
        \\         SELECT 1
        \\         FROM json_each(?1, '$.exclude_path_prefix') x
        \\         WHERE x.value = '/'
        \\           OR e.article_path = x.value
        \\           OR substr(e.article_path, 1, length(x.value) + 1) = x.value || '/'
        \\       )
        \\     )
        \\   )
    ;

    /// A keyset page with exact counts for the whole rule, independent of the page cursor.
    pub const Selection = struct { items: []const EntrySummary, total: i64, unread: i64, next_cursor: ?[]const u8 };
    // Exact hosts use equality so SQLite can seek the normalized-host index.
    fn ruleHost(r: core.selector.Rule) []const u8 {
        return if (r.host == null)
            \\ AND ?9 IS NULL
        else if (r.subdomains)
            \\ AND (e.article_host=?9
            \\OR substr(e.article_host,-length(?9)-1)='.'||?9)
        else
            \\ AND e.article_host=?9
        ;
    }

    const RuleCounts = struct { total: i64, unread: i64 };
    // A single count path keeps sidebar badges and selection totals consistent.
    fn countRule(
        db: *Db,
        a: std.mem.Allocator,
        r: core.selector.Rule,
        now: i64,
        arrived_after: ?i64,
        arrived_until: ?i64,
    ) !RuleCounts {
        try db.validateRule(a, r);
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})});
        const match = try core.selector.fts(a, r);
        const since: ?i64 = if (r.within_days) |d| now - d * 86400000 else null;
        const host_sql = ruleHost(r);
        const count_sql = try std.fmt.allocPrintSentinel(a,
            \\SELECT count(*),coalesce(sum(s.read_at IS NULL),0){s}{s}
        , .{ rule_from, host_sql }, 0);
        const count = try db.prepare(
            count_sql,
            .{
                json,
                match,
                since,
                arrived_after,
                arrived_until,
                null,
                null,
                null,
                r.host,
            },
        );
        defer _ = sqlite3_finalize(count);
        if (sqlite3_step(count) != SQLITE_ROW) return error.Sqlite;
        return .{ .total = sqlite3_column_int64(count, 0), .unread = sqlite3_column_int64(count, 1) };
    }

    /// Counts and pages one rule with shared predicates, excluding hidden entries.
    pub fn selectRule(
        db: *Db,
        a: std.mem.Allocator,
        r: core.selector.Rule,
        now: i64,
        limit: i64,
        before: ?Cursor,
        arrived_after: ?i64,
        arrived_until: ?i64,
    ) !Selection {
        const counts = try db.countRule(a, r, now, arrived_after, arrived_until);
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(r, .{})});
        const match = try core.selector.fts(a, r);
        const since: ?i64 = if (r.within_days) |d| now - d * 86400000 else null;
        const host_sql = ruleHost(r);
        const list_sql = try std.fmt.allocPrintSentinel(a,
            \\SELECT e.id,e.feed_id,coalesce(f.title_override,f.title),e.title,e.url,e.sort_at,s.read_at IS NOT
            \\NULL,s.starred_at IS NOT NULL,substr(e.content_text,1,200),s.later_at IS NOT NULL{s}{s}
            \\AND (?6 IS NULL
            \\OR (e.sort_at,e.id)<(?6,?7))
            \\ORDER BY e.sort_at DESC,e.id DESC
            \\LIMIT ?8
        , .{ rule_from, host_sql }, 0);
        const stmt = try db.prepare(
            list_sql,
            .{
                json,
                match,
                since,
                arrived_after,
                arrived_until,
                if (before) |c| c.sort_at else null,
                if (before) |c| c.id else null,
                limit,
                r.host,
            },
        );
        defer _ = sqlite3_finalize(stmt);
        var rows: std.ArrayList(EntrySummary) = .empty;
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return error.Sqlite;
            var row = try readSummary(stmt, a);
            row.later = sqlite3_column_int64(stmt, 9) != 0;
            try rows.append(a, row);
        }
        const cursor = if (rows.items.len > 0 and rows.items.len == limit) try std.fmt.allocPrint(
            a,
            "{d}:{d}",
            .{
                rows.items[rows.items.len - 1].sort_at,
                rows.items[rows.items.len - 1].id,
            },
        ) else null;
        return .{ .items = rows.items, .total = counts.total, .unread = counts.unread, .next_cursor = cursor };
    }

    /// Loads a saved definition and its human-readable selection sentence.
    pub fn viewGet(db: *Db, a: std.mem.Allocator, id: i64) !std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT *
            \\FROM views
            \\WHERE id=?1
        , .{id});
        if (rows.len == 0) return error.NoSuchView;
        var row = rows[0];
        const r = try core.selector.parse(
            a,
            try std.fmt.allocPrint(
                a,
                "{f}",
                .{std.json.fmt(row.object.get("rule").?, .{})},
            ),
        );
        try row.object.put(a, "sentence", .{ .string = try db.ruleSentence(a, r) });
        return row;
    }

    /// Counts each saved rule through the same query planner path as an unsaved rule.
    /// In particular, an exact host condition can seek entries_article_host.
    pub fn viewsList(db: *Db, a: std.mem.Allocator, now: i64) ![]const std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT *
            \\FROM views
            \\ORDER BY position,id
        , .{});
        var feed_names: std.ArrayList(core.selector.Name) = .empty;
        var folder_names: std.ArrayList(core.selector.Name) = .empty;
        for (try db.featureRows(a,
            \\SELECT id,coalesce(title_override,title,url) AS name
            \\FROM feeds
        , .{})) |f| try feed_names.append(
            a,
            .{
                .id = f.object.get("id").?.integer,
                .name = f.object.get("name").?.string,
            },
        );
        for (try db.folders(a)) |f| try folder_names.append(a, .{ .id = f.id, .name = f.name });
        for (@constCast(rows)) |*row| {
            const r = try core.selector.parse(
                a,
                try std.fmt.allocPrint(
                    a,
                    "{f}",
                    .{std.json.fmt(row.object.get("rule").?, .{})},
                ),
            );
            const counts = try db.countRule(a, r, now, null, null);
            try row.object.put(a, "total", .{ .integer = counts.total });
            try row.object.put(a, "unread", .{ .integer = counts.unread });
            try row.object.put(
                a,
                "sentence",
                .{ .string = try core.selector.sentence(a, r, feed_names.items, folder_names.items) },
            );
        }
        return rows;
    }

    /// Creates or revises a view atomically, returning a conflict if its revision changed.
    pub fn viewPut(
        db: *Db,
        a: std.mem.Allocator,
        id: ?i64,
        name: []const u8,
        rule: []const u8,
        expected: ?i64,
        now: i64,
    ) !std.json.Value {
        try db.validateRule(a, try core.selector.parse(a, rule));
        try db.begin();
        errdefer db.rollback();
        var result_id: i64 = undefined;
        if (id) |v| {
            const current = try db.viewGet(a, v);
            if (expected == null or current.object.get("revision").?.integer != expected.?) {
                try db.commit();
                return conflict(a, current);
            }
            try db.run(
                \\UPDATE views
                \\SET name=?2,rule_json=?3,revision=revision+1,updated_at=?4
                \\WHERE id=?1
            , .{ v, name, rule, now });
            result_id = v;
        } else {
            try db.run(
                \\INSERT INTO views(name,rule_json,created_at,updated_at)
                \\VALUES(?1,?2,?3,?3)
            , .{ name, rule, now });
            result_id = sqlite3_last_insert_rowid(db.handle);
        }
        _ = try db.featureEvent("view.changed", result_id, now);
        try db.commit();
        return db.viewGet(a, result_id);
    }

    /// Updates sidebar order and emits the view change in the same transaction.
    pub fn viewMove(db: *Db, id: i64, position: i64, now: i64) !void {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\UPDATE views
            \\SET position=?2
            \\WHERE id=?1
        , .{ id, position });
        if (sqlite3_changes(db.handle) == 0) return error.NoSuchView;
        _ = try db.featureEvent("view.changed", id, now);
        try db.commit();
    }

    /// Refuses referenced views unless detaching also disables their routines.
    pub fn viewRemove(db: *Db, a: std.mem.Allocator, id: i64, detach: bool, now: i64) !std.json.Value {
        _ = try db.viewGet(a, id);
        const refs = try db.featureRows(a,
            \\SELECT id
            \\FROM routines
            \\WHERE view_id=?1
        , .{id});
        if (refs.len != 0 and !detach) {
            const ids = try a.alloc(i64, refs.len);
            for (refs, 0..) |ref, i| ids[i] = ref.object.get("id").?.integer;
            return object(a, .{ .kind = "in_use", .routine_ids = ids });
        }
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\UPDATE routines
            \\SET enabled=0,view_id=NULL
            \\WHERE view_id=?1
        , .{id});
        try db.run(
            \\DELETE
            \\FROM views
            \\WHERE id=?1
        , .{id});
        _ = try db.featureEvent("view.changed", id, now);
        try db.commit();
        return object(a, .{ .ok = true });
    }

    /// Loads immutable recipe text at the requested revision or the current revision.
    pub fn recipeGet(db: *Db, a: std.mem.Allocator, id: i64, revision: ?i64) !std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT r.id,r.name,r.builtin_text IS NOT NULL AS builtin,v.revision,v.text,v.note,v.created_at
            \\FROM recipes r
            \\JOIN recipe_revisions v ON v.recipe_id=r.id
            \\AND v.revision=coalesce(?2,r.revision)
            \\WHERE r.id=?1
        , .{ id, revision });
        if (rows.len == 0) return error.NoSuchRecipe;
        return rows[0];
    }

    /// Lists recipes with their current immutable text for the recipe picker.
    pub fn recipesList(db: *Db, a: std.mem.Allocator) ![]const std.json.Value {
        return db.featureRows(a,
            \\SELECT r.id,r.name,r.revision,r.builtin_text IS NOT NULL AS builtin,v.text,v.note,v.created_at
            \\FROM recipes r
            \\JOIN recipe_revisions v ON v.recipe_id=r.id
            \\AND v.revision=r.revision
            \\ORDER BY r.id
        , .{});
    }

    /// Lists immutable revisions newest first without discarding earlier instructions.
    pub fn recipeHistory(db: *Db, a: std.mem.Allocator, id: i64) ![]const std.json.Value {
        _ = try db.recipeGet(a, id, null);
        return db.featureRows(a,
            \\SELECT *
            \\FROM recipe_revisions
            \\WHERE recipe_id=?1
            \\ORDER BY revision DESC
        , .{id});
    }

    /// Appends a recipe revision atomically and checks the caller’s expected revision.
    pub fn recipePut(
        db: *Db,
        a: std.mem.Allocator,
        id: ?i64,
        name: []const u8,
        text: []const u8,
        note: []const u8,
        expected: ?i64,
        reset: bool,
        now: i64,
    ) !std.json.Value {
        try db.begin();
        errdefer db.rollback();
        var result_id: i64 = undefined;
        var rev: i64 = 1;
        var body = text;
        if (id) |v| {
            const current = try db.recipeGet(a, v, null);
            rev = current.object.get("revision").?.integer;
            if (expected == null or rev != expected.?) {
                try db.commit();
                return conflict(a, current);
            }
            rev += 1;
            result_id = v;
            if (reset) {
                const row = try db.featureRows(a,
                    \\SELECT builtin_text
                    \\FROM recipes
                    \\WHERE id=?1
                , .{v});
                const val = row[0].object.get("builtin_text").?;
                if (val != .string) return error.NotBuiltin;
                body = val.string;
            }
            try db.run(
                \\UPDATE recipes
                \\SET name=?2,revision=?3
                \\WHERE id=?1
            , .{ v, name, rev });
        } else {
            if (reset) return error.NoSuchRecipe;
            try db.run(
                \\INSERT INTO recipes(name,created_at)
                \\VALUES(?1,?2)
            , .{ name, now });
            result_id = sqlite3_last_insert_rowid(db.handle);
        }
        try db.run(
            \\INSERT INTO recipe_revisions(recipe_id,revision,text,note,created_at)
            \\VALUES(?1,?2,?3,?4,?5)
        , .{ result_id, rev, body, note, now });
        _ = try db.featureEvent("recipe.changed", result_id, now);
        try db.commit();
        return db.recipeGet(a, result_id, null);
    }

    /// Reading flags captured before a bulk write so clients can construct an undo.
    pub const Previous = struct { id: i64, read: bool, starred: bool, later: bool, hidden: bool };

    /// Applies explicit flags atomically and returns previous states for every entry.
    pub fn markMany(db: *Db, a: std.mem.Allocator, ids: []const i64, marks: Marks, now: i64) ![]const Previous {
        if (ids.len > 1000) return error.TooManyEntries;
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(ids, .{})});
        try db.begin();
        errdefer db.rollback();
        const rows = try db.featureRows(a,
            \\SELECT e.id,s.read_at IS NOT NULL AS read,s.starred_at IS NOT NULL AS starred,s.later_at IS NOT
            \\NULL AS later,s.hidden_at IS NOT NULL AS hidden
            \\FROM json_each(?1) requested
            \\LEFT JOIN entries e ON e.id=requested.value
            \\LEFT JOIN entry_state s ON s.entry_id=e.id
            \\ORDER BY requested.key
        , .{json});
        var old: std.ArrayList(Previous) = .empty;
        for (rows) |row| {
            const o = row.object;
            if (o.get("id").? == .null) return error.NoSuchEntry;
            try old.append(
                a,
                .{
                    .id = o.get("id").?.integer,
                    .read = o.get("read").?.integer != 0,
                    .starred = o.get("starred").?.integer != 0,
                    .later = o.get("later").?.integer != 0,
                    .hidden = o.get("hidden").?.integer != 0,
                },
            );
        }
        try db.run(
            \\INSERT
            \\OR IGNORE INTO entry_state(entry_id) SELECT value
            \\FROM json_each(?1)
        , .{json});
        try db.run(
            \\UPDATE entry_state
            \\SET read_at=CASE WHEN ?2 IS NULL THEN read_at WHEN ?2 THEN ?6 END,starred_at=CASE WHEN ?3 IS NULL
            \\THEN starred_at WHEN ?3 THEN ?6 END,later_at=CASE WHEN ?4 IS NULL THEN later_at WHEN ?4 THEN ?6
            \\END,hidden_at=CASE WHEN ?5 IS NULL THEN hidden_at WHEN ?5 THEN ?6 END
            \\WHERE entry_id IN (SELECT value
            \\FROM json_each(?1))
        , .{ json, marks.read, marks.starred, marks.later, marks.hidden, now });
        try db.run(
            \\INSERT INTO events(at,type,subject_id) SELECT ?2,'entry.state',value
            \\FROM json_each(?1)
            \\GROUP BY value
        , .{ json, now });
        try db.commit();
        return old.items;
    }

    /// Lists recent durable work for Activity with decoded input and progress fields.
    pub fn jobsList(db: *Db, a: std.mem.Allocator, limit: i64) ![]const std.json.Value {
        return db.featureRows(a,
            \\SELECT j.*,a.id AS artifact_id
            \\FROM jobs j
            \\LEFT JOIN artifacts a ON a.job_id=j.id
            \\ORDER BY j.created_at DESC,j.id DESC
            \\LIMIT ?1
        , .{limit});
    }

    /// Persisted lifecycle states used by workers and cancellation checks.
    pub const JobStatus = enum { queued, running, done, failed, cancelled };

    /// Reads only the lifecycle state for frequent subprocess cancellation checks.
    pub fn jobStatus(db: *Db, id: i64) !JobStatus {
        const stmt = try db.prepare(
            \\SELECT status
            \\FROM jobs
            \\WHERE id=?1
        , .{id});
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return error.NoSuchJob;
        const value = sqlite3_column_text(stmt, 0) orelse return error.Sqlite;
        return std.meta.stringToEnum(JobStatus, value[0..@intCast(sqlite3_column_bytes(stmt, 0))]) orelse error.Sqlite;
    }

    /// Loads one durable job, failing if its identity is unknown.
    pub fn jobGet(db: *Db, a: std.mem.Allocator, id: i64) !std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT j.*,a.id AS artifact_id
            \\FROM jobs j
            \\LEFT JOIN artifacts a ON a.job_id=j.id
            \\WHERE j.id=?1
        , .{id});
        if (rows.len == 0) return error.NoSuchJob;
        return rows[0];
    }

    /// Persists queued input and its change event in one transaction.
    pub fn jobQueue(db: *Db, a: std.mem.Allocator, stage: []const u8, input: []const u8, now: i64) !std.json.Value {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\INSERT INTO jobs(stage,input_json,created_at)
            \\VALUES(?1,?2,?3)
        , .{ stage, input, now });
        const id = sqlite3_last_insert_rowid(db.handle);
        _ = try db.featureEvent("job.changed", id, now);
        try db.commit();
        return db.jobGet(a, id);
    }

    /// Records a terminal result without overwriting an explicit cancellation.
    pub fn jobFinish(db: *Db, id: i64, status: []const u8, reason: ?[]const u8, now: i64) !void {
        try db.begin();
        errdefer db.rollback();
        if (std.mem.eql(u8, status, "cancelled")) try db.run(
            \\UPDATE routine_runs
            \\SET status='cancelled',finished_at=?2
            \\WHERE job_id=?1
            \\AND EXISTS(SELECT 1
            \\FROM jobs
            \\WHERE id=?1
            \\AND status='queued')
        , .{ id, now });
        try db.run(
            \\UPDATE jobs
            \\SET status=?2,error=?3,finished_at=?4,lease_until=NULL
            \\WHERE id=?1
            \\AND status IN ('queued','running')
        , .{ id, status, reason, now });
        if (sqlite3_changes(db.handle) > 0) {
            _ = try db.featureEvent("job.changed", id, now);
            try db.completeRoutineBrief(id, status, null, reason, now);
        }
        try db.commit();
    }

    /// Atomically takes the oldest queued job for the serial feature worker.
    pub fn jobClaim(db: *Db, a: std.mem.Allocator, now: i64) !?std.json.Value {
        try db.begin();
        errdefer db.rollback();
        const rows = try db.featureRows(a,
            \\SELECT *
            \\FROM jobs
            \\WHERE status='queued'
            \\AND run_after<=?1
            \\ORDER BY id
            \\LIMIT 1
        , .{now});
        if (rows.len == 0) {
            try db.commit();
            return null;
        }
        const id = rows[0].object.get("id").?.integer;
        try db.run(
            \\UPDATE jobs
            \\SET status='running',attempts=attempts+1,lease_until=?2
            \\WHERE id=?1
        , .{ id, now + 1260000 });
        _ = try db.featureEvent("job.changed", id, now);
        try db.commit();
        return rows[0];
    }

    /// Requeues interrupted work so durable jobs resume after a daemon restart.
    pub fn recoverJobs(db: *Db, now: i64) !void {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\UPDATE jobs
            \\SET status='queued',lease_until=NULL
            \\WHERE status='running'
        , .{});
        try db.run(
            \\INSERT INTO events(at,type,subject_id) SELECT ?1,'job.changed',id
            \\FROM jobs
            \\WHERE status='queued'
        , .{now});
        try db.commit();
    }

    /// Lists published briefs, excluding recipe trials from the reading destination.
    pub fn artifactsList(db: *Db, a: std.mem.Allocator, limit: i64) ![]const std.json.Value {
        return db.featureRows(a,
            \\SELECT id,title,created_at,writer,recipe_id,recipe_revision,input_count,omitted_count,view_id
            \\FROM artifacts
            \\WHERE kind='digest'
            \\AND preview=0
            \\ORDER BY created_at DESC,id DESC
            \\LIMIT ?1
        , .{limit});
    }

    /// Loads cited blocks and the immutable recipe and source provenance.
    pub fn artifactGet(db: *Db, a: std.mem.Allocator, id: i64, kind: []const u8) !std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT a.*,coalesce(json_extract(j.input_json,'$.recipe_text'),v.text) AS recipe_text,
            \\  r.name AS recipe_name,w.name AS view_name
            \\FROM artifacts a
            \\LEFT JOIN jobs j ON j.id=a.job_id
            \\LEFT JOIN recipe_revisions v ON v.recipe_id=a.recipe_id
            \\AND v.revision=a.recipe_revision
            \\LEFT JOIN recipes r ON r.id=a.recipe_id
            \\LEFT JOIN views w ON w.id=a.view_id
            \\WHERE a.id=?1
            \\AND a.kind=?2
        , .{ id, kind });
        if (rows.len == 0) return error.NoSuchArtifact;
        var row = rows[0];
        const sources = try db.featureRows(a,
            \\SELECT e.id,e.title,e.url,e.sort_at,coalesce(f.title_override,f.title) AS
            \\feed_title,substr(e.content_text,1,200) AS snippet,s.read_at IS NOT NULL AS read
            \\FROM artifact_sources src
            \\JOIN entries e ON e.id=src.entry_id
            \\JOIN feeds f ON f.id=e.feed_id
            \\LEFT JOIN entry_state s ON s.entry_id=e.id
            \\WHERE src.artifact_id=?1
            \\ORDER BY e.id
        , .{id});
        for (@constCast(sources), 0..) |*source, i| try source.object.put(a, "number", .{ .integer = @intCast(i + 1) });
        if (row.object.get("citations")) |raw| {
            try row.object.put(a, "output", raw);
            if (raw != .null) {
                const output = try std.json.parseFromValueLeaky(@import("writer.zig").Output, a, raw, .{});
                var sections: std.ArrayList(std.json.Value) = .empty;
                for (output.sections) |section| {
                    var claims: std.ArrayList(std.json.Value) = .empty;
                    for (section.claims) |claim| {
                        var numbers: std.ArrayList(i64) = .empty;
                        for (claim.sources) |entry| {
                            for (sources, 0..) |source, i| {
                                if (source.object.get("id").?.integer == entry) {
                                    try numbers.append(a, @intCast(i + 1));
                                    break;
                                }
                            }
                        }
                        try claims.append(a, try object(a, .{ .text = claim.text, .sources = numbers.items }));
                    }
                    try sections.append(a, try object(a, .{ .heading = section.heading, .claims = claims.items }));
                }
                try row.object.put(a, "sections", .{ .array = .fromOwnedSlice(a, sections.items) });
            }
        }
        try row.object.put(a, "sources", .{ .array = .fromOwnedSlice(a, @constCast(sources)) });
        try row.object.put(a, "citations", .{ .array = .fromOwnedSlice(a, @constCast(sources)) });
        try row.object.put(a, "blocks", row.object.get("body_blocks").?);
        return row;
    }

    /// Lists routine definitions with their persisted next occurrence.
    pub fn routinesList(db: *Db, a: std.mem.Allocator) ![]const std.json.Value {
        return db.featureRows(a,
            \\SELECT *
            \\FROM routines
            \\ORDER BY id
        , .{});
    }

    /// Loads one routine with decoded schedule and action definitions.
    pub fn routineGet(db: *Db, a: std.mem.Allocator, id: i64) !std.json.Value {
        const rows = try db.featureRows(a,
            \\SELECT *
            \\FROM routines
            \\WHERE id=?1
        , .{id});
        if (rows.len == 0) return error.NoSuchRoutine;
        return rows[0];
    }

    /// Saves a revision-checked routine and its precomputed next occurrence atomically.
    pub fn routinePut(
        db: *Db,
        a: std.mem.Allocator,
        id: ?i64,
        name: []const u8,
        view: i64,
        schedule: []const u8,
        actions: []const u8,
        enabled: bool,
        expected: ?i64,
        now: i64,
        next: ?i64,
    ) !std.json.Value {
        try db.begin();
        errdefer db.rollback();
        var result_id: i64 = undefined;
        if (id) |v| {
            const current = try db.routineGet(a, v);
            if (expected == null or current.object.get("revision").?.integer != expected.?) {
                try db.commit();
                return conflict(a, current);
            }
            try db.run(
                \\UPDATE routines
                \\SET
                \\name=?2,view_id=?3,schedule_json=?4,actions_json=?5,enabled=?6,revision=revision+1,next_run_at=?7
                \\WHERE id=?1
            , .{ v, name, view, schedule, actions, enabled, next });
            result_id = v;
        } else {
            try db.run(
                \\INSERT INTO routines(name,view_id,schedule_json,actions_json,enabled,created_at,next_run_at)
                \\VALUES(?1,?2,?3,?4,?5,?6,?7)
            , .{ name, view, schedule, actions, enabled, now, next });
            result_id = sqlite3_last_insert_rowid(db.handle);
        }
        _ = try db.featureEvent("routine.changed", result_id, now);
        try db.commit();
        return db.routineGet(a, result_id);
    }

    /// Deletes an idle routine while preserving the no-overlap invariant.
    pub fn routineRemove(db: *Db, a: std.mem.Allocator, id: i64, now: i64) !void {
        _ = try db.routineGet(a, id);
        const active = try db.featureRows(a,
            \\SELECT id
            \\FROM routine_runs
            \\WHERE routine_id=?1
            \\AND status='running'
        , .{id});
        if (active.len != 0) return error.RoutineBusy;
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\DELETE
            \\FROM routines
            \\WHERE id=?1
        , .{id});
        _ = try db.featureEvent("routine.changed", id, now);
        try db.commit();
    }

    /// Lists captured matches and per-action results for recent routine runs.
    pub fn routineRuns(db: *Db, a: std.mem.Allocator, id: i64, limit: i64) ![]const std.json.Value {
        _ = try db.routineGet(a, id);
        return db.featureRows(a,
            \\SELECT *
            \\FROM routine_runs
            \\WHERE routine_id=?1
            \\ORDER BY id DESC
            \\LIMIT ?2
        , .{ id, limit });
    }

    /// Finds enabled due routines that have no running occurrence.
    pub fn dueRoutines(db: *Db, a: std.mem.Allocator, now: i64) ![]const std.json.Value {
        return db.featureRows(a,
            \\SELECT *
            \\FROM routines
            \\WHERE enabled=1
            \\AND view_id IS NOT NULL
            \\AND next_run_at<=?1
            \\AND NOT EXISTS(SELECT 1
            \\FROM routine_runs rr
            \\WHERE rr.routine_id=routines.id
            \\AND rr.status='running')
            \\ORDER BY next_run_at
        , .{now});
    }

    /// Atomically captures one run, queues its job and coalesces missed occurrences.
    pub fn routineStart(
        db: *Db,
        a: std.mem.Allocator,
        id: i64,
        matches: []const i64,
        actions: std.json.Value,
        now: i64,
        next: ?i64,
        view_id: i64,
        rule: core.selector.Rule,
    ) !std.json.Value {
        try db.begin();
        errdefer db.rollback();
        const active = try db.featureRows(a,
            \\SELECT id
            \\FROM routine_runs
            \\WHERE routine_id=?1
            \\AND status='running'
        , .{id});
        if (active.len != 0) return error.RoutineBusy;
        const input = try std.fmt.allocPrint(
            a,
            "{f}",
            .{std.json.fmt(
                .{
                    .routine_id = id,
                    .matches = matches,
                    .actions = actions,
                    .view_id = view_id,
                    .rule = rule,
                },
                .{},
            )},
        );
        try db.run(
            \\INSERT INTO jobs(stage,input_json,created_at)
            \\VALUES('routine',?1,?2)
        , .{ input, now });
        const job = sqlite3_last_insert_rowid(db.handle);
        try db.run(
            \\INSERT INTO routine_runs(routine_id,job_id,started_at,matches_json)
            \\VALUES(?1,?2,?3,?4)
        , .{ id, job, now, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(matches, .{})}) });
        try db.run(
            \\UPDATE routines
            \\SET next_run_at=?2
            \\WHERE id=?1
        , .{ id, next });
        _ = try db.featureEvent("job.changed", job, now);
        _ = try db.featureEvent("routine.changed", id, now);
        try db.commit();
        return db.jobGet(a, job);
    }

    /// Records per-action outcomes for the run associated with a durable job.
    pub fn routineFinish(db: *Db, job: i64, results: []const u8, status: []const u8, now: i64) !void {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\UPDATE routines
            \\SET last_run_at=(SELECT started_at
            \\FROM routine_runs
            \\WHERE job_id=?1)
            \\WHERE id=(SELECT routine_id
            \\FROM routine_runs
            \\WHERE job_id=?1)
        , .{job});
        try db.run(
            \\UPDATE routine_runs
            \\SET results_json=?2,status=?3,finished_at=?4
            \\WHERE job_id=?1
        , .{ job, results, status, now });
        try db.commit();
    }

    /// Adds a tag to captured matches and records the routine as its actor.
    pub fn routineTag(
        db: *Db,
        a: std.mem.Allocator,
        ids: []const i64,
        tag: []const u8,
        source: []const u8,
        now: i64,
    ) !void {
        try db.begin();
        errdefer db.rollback();
        try db.run(
            \\INSERT
            \\OR IGNORE INTO tags(name)
            \\VALUES(?1)
        , .{tag});
        const json = try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(ids, .{})});
        try db.run(
            \\INSERT
            \\OR IGNORE INTO entry_tags(entry_id,tag_id,source) SELECT x.value,t.id,?3
            \\FROM json_each(?1) x
            \\JOIN tags t ON t.name=?2
        , .{ json, tag, source });
        try db.run(
            \\INSERT INTO events(at,type,subject_id) SELECT ?2,'entry.state',value
            \\FROM json_each(?1)
        , .{ json, now });
        try db.commit();
    }

    fn completeRoutineBrief(
        db: *Db,
        job: i64,
        status: []const u8,
        artifact: ?i64,
        reason: ?[]const u8,
        now: i64,
    ) !void {
        try db.run(
            \\UPDATE routine_runs
            \\SET results_json=(SELECT json_group_array(json(CASE WHEN json_extract(value,'$.job_id')=?1 THEN
            \\json_set(value,'$.status',?2,'$.artifact_id',?3,'$.error',?4) ELSE value END))
            \\FROM json_each(results_json))
            \\WHERE EXISTS(SELECT 1
            \\FROM json_each(results_json)
            \\WHERE json_extract(value,'$.job_id')=?1)
        , .{ job, status, artifact, reason });
        try db.run(
            \\INSERT INTO events(at,type,subject_id) SELECT ?2,'routine.changed',routine_id
            \\FROM routine_runs
            \\WHERE EXISTS(SELECT 1
            \\FROM json_each(results_json)
            \\WHERE json_extract(value,'$.job_id')=?1)
        , .{ job, now });
    }

    /// Commits cited output, source ids, provenance and completion as one transaction.
    pub fn artifactSave(
        db: *Db,
        a: std.mem.Allocator,
        job: i64,
        input: anytype,
        output: anytype,
        body: []const u8,
        ids: []const i64,
        omitted: i64,
        now: i64,
    ) !i64 {
        try db.begin();
        errdefer db.rollback();
        const current = try db.jobGet(a, job);
        if (!std.mem.eql(u8, current.object.get("status").?.string, "running")) return error.JobCancelled;
        try db.run(
            \\INSERT INTO
            \\artifacts(kind,job_id,producer,title,body_blocks_json,created_at,recipe_id,recipe_revision,
            \\  template_version,view_id,rule_json,writer,input_count,omitted_count,question,preview,citations_json)
            \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,1,?9,?10,?3,?11,?12,?13,?14,?15)
        , .{
            if (input.question != null) @as([]const u8, "answer") else "digest",
            job,
            input.writer,
            output.title,
            body,
            now,
            input.recipe_id,
            input.recipe_revision,
            input.view_id,
            try std.fmt.allocPrint(
                a,
                "{f}",
                .{std.json.fmt(input.rule, .{})},
            ),
            ids.len,
            omitted,
            input.question,
            input.preview,
            try std.fmt.allocPrint(
                a,
                "{f}",
                .{std.json.fmt(output, .{})},
            ),
        });
        const id = sqlite3_last_insert_rowid(db.handle);
        try db.run(
            \\INSERT INTO artifact_sources(artifact_id,entry_id) SELECT ?1,value
            \\FROM json_each(?2)
        , .{ id, try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(ids, .{})}) });
        try db.completeRoutineBrief(job, "done", id, null, now);
        _ = try db.featureEvent("artifact.new", id, now);
        try db.run(
            \\UPDATE jobs
            \\SET status='done',finished_at=?2,lease_until=NULL
            \\WHERE id=?1
        , .{ job, now });
        _ = try db.featureEvent("job.changed", job, now);
        try db.commit();
        return id;
    }

    /// Loads source text in the captured order so citations keep stable entry identities.
    pub fn writerSources(db: *Db, a: std.mem.Allocator, ids: []const i64) ![]const @import("writer.zig").Source {
        const rows = try db.featureRows(a,
            \\SELECT id,coalesce(title,'') AS title,substr(content_text,1,120000) AS text
            \\FROM entries
            \\WHERE id IN (SELECT value
            \\FROM json_each(?1))
            \\ORDER BY sort_at DESC,id DESC
            \\LIMIT 60
        , .{try std.fmt.allocPrint(a, "{f}", .{std.json.fmt(ids, .{})})});
        var sources: std.ArrayList(@import("writer.zig").Source) = .empty;
        for (rows) |row| {
            try sources.append(
                a,
                .{
                    .id = row.object.get("id").?.integer,
                    .title = row.object.get("title").?.string,
                    .text = row.object.get("text").?.string,
                },
            );
        }
        return sources.items;
    }
};

const testing = std.testing;

fn sample(identity: []const u8, title: []const u8, hash: []const u8) NewEntry {
    return .{
        .identity = identity,
        .url = "https://example.com/a",
        .canonical_url = "https://example.com/a",
        .title = title,
        .author = null,
        .published_at = 1000,
        .updated_at = null,
        .content_blocks_json = "[]",
        .content_text = "zig parser text",
        .content_hash = hash,
        .enclosures = &.{.{ .url = "https://example.com/a.mp3", .mime_type = "audio/mpeg", .bytes = 5 }},
    };
}

test "ingest separates new, changed and unchanged entries, and keeps read state" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    try testing.expectEqual(feed_id, try db.addFeed("https://example.com/feed", false, 2));

    var result = try db.ingest(feed_id, &.{ sample("1", "One", "h1"), sample("2", "Two", "h2") }, 2000);
    try testing.expectEqual(2, result.new);

    const listed = try db.listEntries(a, .{});
    try testing.expectEqual(2, listed.len);
    try testing.expect(try db.mark(listed[0].id, .{ .read = true }, 3000));

    result = try db.ingest(feed_id, &.{ sample("1", "One", "h1"), sample("2", "Two changed", "h2b") }, 4000);
    try testing.expectEqual(0, result.new);
    try testing.expectEqual(1, result.updated);

    const entry = (try db.getEntry(a, listed[0].id)).?;
    try testing.expect(entry.read);
    try testing.expectEqual(1, (try db.listEntries(a, .{ .unread_only = true })).len);
    const changed = for (try db.listEntries(a, .{})) |row| {
        if (std.mem.eql(u8, row.title.?, "Two changed")) break row;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(2, (try db.getEntry(a, changed.id)).?.revision);
}

test "sandboxed queries can read but cannot escape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/store-test.db", .{dir}, 0);
    var writer: Db = try .open(path, .writer);
    defer writer.close();
    _ = try writer.addFeed("https://example.com/feed", false, 1);

    var sandbox: Db = try .open(path, .sandbox);
    defer sandbox.close();

    try testing.expectEqualStrings(
        "{\"columns\":[\"url\",\"n\"],\"rows\":[[\"https://example.com/feed\",1]],\"truncated\":false}",
        try sandbox.query(a, "SELECT url, 1 AS n FROM feeds", 10),
    );
    const refused = [_][]const u8{
        "DELETE FROM feeds",
        "DROP TABLE feeds",
        "PRAGMA query_only=OFF",
        "ATTACH DATABASE '/tmp/x.db' AS x",
        "SELECT 1; DELETE FROM feeds",
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c",
        "not sql",
        "",
    };
    for (refused) |sql| {
        const result = try sandbox.query(a, sql, 10);
        try testing.expect(std.mem.startsWith(u8, result, "{\"error\":"));
    }
    try testing.expect(std.mem.indexOf(u8, try sandbox.query(a, "SELECT 1 UNION ALL SELECT 2", 1), "\"truncated\":true") != null);
    try testing.expectEqual(1, (try writer.stats(5)).feeds);
}

test "folders are found rather than duplicated, even at the top level" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    const top = try db.ensureFolder(null, "Tech");
    try testing.expectEqual(top, try db.ensureFolder(null, "Tech"));
    const nested = try db.ensureFolder(top, "Zig");
    try testing.expect(nested != top);
    try testing.expectEqual(nested, try db.ensureFolder(top, "Zig"));
}

test "only raw bodies past the newest for each feed are stale" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try db.addFeed("https://example.com/a", false, 1);
    const second = try db.addFeed("https://example.com/b", false, 1);
    for (0..5) |i| {
        const hash = try std.fmt.allocPrint(a, "a{d}", .{i});
        try db.logFetch(.{ .feed_id = first, .started_at = 1, .duration_ms = 1, .raw_sha256 = hash });
        // The same body fetched twice counts once.
        try db.logFetch(.{ .feed_id = first, .started_at = 1, .duration_ms = 1, .raw_sha256 = hash });
    }
    try db.logFetch(.{ .feed_id = second, .started_at = 1, .duration_ms = 1, .raw_sha256 = "b0" });

    const stale = try db.takeStaleRaw(a, 2);
    try testing.expectEqual(3, stale.len);
    try testing.expectEqualStrings("a4", (try db.lastRawHash(a, first)).?);
    try testing.expectEqualStrings("b0", (try db.lastRawHash(a, second)).?);
    try testing.expectEqual(0, (try db.takeStaleRaw(a, 2)).len);
}

test "full text replaces content, and a publisher's edit asks for it again" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(feed_id, &.{sample("1", "One", "h1")}, 2000);

    const due = try db.dueFullText(a, 0, 1000, 10, 5000);
    try testing.expectEqual(1, due.len);
    try db.saveFullText(due[0].id, "[]", "the whole article about gardens", 3000);
    try testing.expectEqual(0, (try db.dueFullText(a, 0, 1000, 10, 5000)).len);
    try testing.expectEqual(1, (try db.search(a, "gardens", .{})).len);

    // The same feed text again must not undo the article.
    _ = try db.ingest(feed_id, &.{sample("1", "One", "h1")}, 4000);
    try testing.expectEqual(1, (try db.search(a, "gardens", .{})).len);

    _ = try db.ingest(feed_id, &.{sample("1", "One", "h2")}, 5000);
    try testing.expectEqual(1, (try db.dueFullText(a, 0, 1000, 10, 5000)).len);
    try testing.expectEqual(0, (try db.dueFullText(a, 0, 5, 10, 5000)).len);
    try testing.expectEqual(0, (try db.dueFullText(a, 999999, 1000, 10, 5000)).len);
}

test "an enclosure size beyond SQLite's range is stored, not fatal" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    var entry = sample("1", "One", "h1");
    entry.enclosures = &.{.{ .url = "https://example.com/a", .mime_type = null, .bytes = std.math.maxInt(u64) }};
    try testing.expectEqual(1, (try db.ingest(feed_id, &.{entry}, 2000)).new);
}

test "a body another feed still needs is kept" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try db.addFeed("https://example.com/a", false, 1);
    const second = try db.addFeed("https://example.com/b", false, 1);
    try db.logFetch(.{ .feed_id = first, .started_at = 1, .duration_ms = 1, .raw_sha256 = "shared" });
    try db.logFetch(.{ .feed_id = first, .started_at = 1, .duration_ms = 1, .raw_sha256 = "newer" });
    try db.logFetch(.{ .feed_id = second, .started_at = 1, .duration_ms = 1, .raw_sha256 = "shared" });

    try testing.expectEqual(0, (try db.takeStaleRaw(a, 1)).len);
    try testing.expectEqualStrings("shared", (try db.lastRawHash(a, second)).?);
}

test "query output stops growing at its byte limit" {
    var db: Db = try .open(":memory:", .sandbox);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100) SELECT printf('%.*c', 1000000, 'x') FROM n";
    const json = try db.query(arena.allocator(), sql, 100);
    try testing.expect(json.len < Db.query_max_bytes + 4096);
    try testing.expect(std.mem.endsWith(u8, json, "\"truncated\":true}"));
}

test "one huge value cannot be built, or returned past the byte limit" {
    var db: Db = try .open(":memory:", .sandbox);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const too_long = try db.query(a, "SELECT hex(zeroblob(100000000))", 10);
    try testing.expect(std.mem.indexOf(u8, too_long, "too big") != null);

    const over_budget = try db.query(a, "SELECT hex(zeroblob(4000000))", 10);
    try testing.expect(over_budget.len < 4096);
    try testing.expect(std.mem.endsWith(u8, over_budget, "\"truncated\":true}"));
}

test "a failed body is tracked for pruning, but is not the last good body" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/a", false, 1);
    try db.logFetch(.{ .feed_id = feed_id, .started_at = 1, .duration_ms = 1, .raw_sha256 = "good" });
    try db.logFetch(.{ .feed_id = feed_id, .started_at = 1, .duration_ms = 1, .raw_sha256 = "bad", .err = "NotAFeed" });

    try testing.expectEqualStrings("good", (try db.lastRawHash(a, feed_id)).?);
    const stale = try db.takeStaleRaw(a, 1);
    try testing.expectEqual(1, stale.len);
    try testing.expectEqualStrings("good", stale[0]);
}

test "a hidden entry leaves lists and search until shown again" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(feed_id, &.{sample("1", "One", "h1")}, 2000);
    const id = (try db.listEntries(a, .{}))[0].id;

    try testing.expect(try db.mark(id, .{ .hidden = true }, 3000));
    try testing.expectEqual(0, (try db.listEntries(a, .{})).len);
    try testing.expectEqual(0, (try db.stats(5)).unread);
    try testing.expectEqual(0, (try db.feeds(a))[0].unread);
    try testing.expectEqual(0, (try db.search(a, "parser", .{})).len);
    try testing.expect(try db.mark(id, .{ .hidden = false }, 3000));
    try testing.expectEqual(1, (try db.listEntries(a, .{})).len);
}

test "search filters apply before the window of recent matches" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(feed_id, &.{sample("old", "Old", "h")}, 2000);
    const unread = (try db.listEntries(a, .{}))[0].id;

    var rows: std.ArrayList(NewEntry) = .empty;
    for (0..2100) |i| try rows.append(a, sample(try std.fmt.allocPrint(a, "n{d}", .{i}), "New", "h"));
    _ = try db.ingest(feed_id, rows.items, 2000);
    const stmt = try db.prepare("INSERT INTO entry_state (entry_id, read_at) SELECT id, 1 FROM entries WHERE id != ?1", .{unread});
    defer _ = sqlite3_finalize(stmt);
    _ = sqlite3_step(stmt);

    const found = try db.search(a, "zig", .{ .unread_only = true });
    try testing.expectEqual(1, found.len);
    try testing.expectEqual(unread, found[0].id);
}

test "long entries are settled, and short ones keep waiting" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    var long = sample("long", "Long", "h1");
    long.content_text = "a long enough body";
    var short = sample("short", "Short", "h2");
    short.content_text = "short";
    _ = try db.ingest(feed_id, &.{ long, short }, 2000);

    try db.skipLongEntries(0, 10, 3000);
    const due = try db.dueFullText(a, 0, 1000, 10, 3000);
    try testing.expectEqual(1, due.len);
    try testing.expectEqualStrings("Short", due[0].title.?);
}

test "a retry waits for its time, and an edit starts over" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(feed_id, &.{sample("1", "One", "h1")}, 2000);
    const id = (try db.dueFullText(a, 0, 1000, 10, 3000))[0].id;

    try db.retryFullText(id, 2, 9000, 3000);
    try testing.expectEqual(0, (try db.dueFullText(a, 0, 1000, 10, 8999)).len);
    try testing.expectEqual(2, (try db.dueFullText(a, 0, 1000, 10, 9000))[0].attempts);

    _ = try db.ingest(feed_id, &.{sample("1", "One", "h2")}, 3000);
    try testing.expectEqual(0, (try db.dueFullText(a, 0, 1000, 10, 3000))[0].attempts);
}

test "an old database is upgraded in place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}/migrate-test.db", .{dir}, 0);
    {
        var handle: ?*Handle = null;
        try testing.expectEqual(0, sqlite3_open(path, &handle));
        var old: Db = .{ .handle = handle.? };
        defer old.close();
        try old.exec(migrations[0]);
        try old.run("INSERT INTO feeds (url, created_at) VALUES ('https://example.com/', 1)", .{});
    }
    var db: Db = try .open(path, .writer);
    defer db.close();
    try testing.expectEqual(1, (try db.stats(5)).feeds);
    try testing.expectEqual(0, (try db.dueFullText(arena.allocator(), 0, 1000, 10, 5)).len);
}

test "due feeds and removal" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = try db.addFeed("https://example.com/feed", false, 1);
    try testing.expectEqual(1, (try db.dueFeeds(a, 100)).len);
    try db.updateFeed(.{ .id = id, .next_fetch_at = 5000, .last_fetch_at = 1, .error_count = 0 });
    try testing.expectEqual(0, (try db.dueFeeds(a, 100)).len);
    try testing.expectEqual(5000, (try db.nextDueAt()).?);
    try testing.expectEqual(1, try db.markAllDue());
    try testing.expectEqual(1, (try db.dueFeeds(a, 100)).len);
    try testing.expect(try db.removeFeed(id));
    try testing.expect(!try db.removeFeed(id));
}

test "search survives FTS5 syntax in user input" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(feed_id, &.{sample("1", "One", "h1")}, 2000);

    const found = try db.search(a, "zig parser", .{});
    try testing.expectEqual(1, found.len);
    try testing.expect(std.mem.indexOf(u8, found[0].snippet.?, "zig parser") != null);
    try testing.expectEqual(0, (try db.search(a, "\"unbalanced AND OR NOT ( * :", .{})).len);
    try testing.expectEqual(0, (try db.search(a, "   ", .{})).len);

    try testing.expectEqual(0, (try db.search(a, "zig", .{ .since = 5000 })).len);
    try testing.expect(try db.mark(found[0].id, .{ .read = true }, 3000));
    try testing.expectEqual(0, (try db.search(a, "zig", .{ .unread_only = true })).len);
    try testing.expectEqual(1, (try db.search(a, "zig", .{})).len);
}

test "search also finds entries of a feed named after the subject" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const feed_id = try db.addFeed("https://ziglang.org/news/index.xml", false, 1);
    try db.updateFeed(.{ .id = feed_id, .title = "News", .next_fetch_at = 0, .last_fetch_at = 1, .error_count = 0 });
    var entry = sample("1", "0.17.1 Released", "h");
    entry.content_text = "bug fixes";
    _ = try db.ingest(feed_id, &.{entry}, 2000);

    const other_id = try db.addFeed("https://example.com/feed", false, 1);
    _ = try db.ingest(other_id, &.{sample("2", "Other", "h2")}, 3000);

    const found = try db.search(a, "zig", .{});
    try testing.expectEqual(2, found.len); // The second matches by text.
    try testing.expectEqualStrings("Other", found[0].title.?);
    try testing.expectEqualStrings("0.17.1 Released", found[1].title.?);
    try testing.expectEqual(null, found[1].snippet);
    try testing.expectEqual(1, (try db.search(a, "zig", .{ .limit = 1 })).len);
    try testing.expectEqual(2, (try db.search(a, "zig", .{ .since = 500 })).len);
    try testing.expectEqual(0, (try db.search(a, "zig", .{ .since = 2500 })).len);
    // Every word must match, and short words never match a feed.
    try testing.expectEqual(0, (try db.search(a, "zig nothing", .{})).len);
    try testing.expectEqual(0, (try db.search(a, "zi", .{})).len);
}

test "feed names match on word prefixes only" {
    try testing.expect(feedMatches("zig", "News", "ziglang.org", ""));
    try testing.expect(feedMatches("ZIG", "Release notes from zig", "", ""));
    try testing.expect(feedMatches("news zig", "News", "ziglang.org", ""));
    try testing.expect(!feedMatches("lang", "News", "ziglang.org", ""));
    try testing.expect(!feedMatches("zig rust", "News", "ziglang.org", ""));
    try testing.expect(!feedMatches("", "News", "ziglang.org", ""));
}

test "keyset paging walks the whole timeline without repeats" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    var entries: [25]NewEntry = undefined;
    for (&entries, 0..) |*entry, i| {
        entry.* = sample(try std.fmt.allocPrint(a, "{d}", .{i}), "t", "h");
        entry.enclosures = &.{};
    }
    _ = try db.ingest(feed_id, &entries, 2000);

    var seen: usize = 0;
    var cursor: ?Cursor = null;
    var previous: i64 = std.math.maxInt(i64);
    while (true) {
        const page = try db.listEntries(a, .{ .limit = 10, .before = cursor });
        if (page.len == 0) break;
        for (page) |row| {
            try testing.expect(row.id < previous);
            previous = row.id;
        }
        seen += page.len;
        const last = page[page.len - 1];
        cursor = .{ .sort_at = last.sort_at, .id = last.id };
    }
    try testing.expectEqual(25, seen);
}

test "an entry with only an updated date sorts by it" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    var entry = sample("1", "Old", "h");
    entry.published_at = null;
    entry.updated_at = 500;
    _ = try db.ingest(feed_id, &.{entry}, 2000);
    try testing.expectEqual(500, (try db.listEntries(arena.allocator(), .{}))[0].sort_at);
}

test "a future date cannot outrank the present" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const feed_id = try db.addFeed("https://example.com/feed", false, 1);
    var entry = sample("1", "Future", "h");
    entry.published_at = 9_000_000;
    _ = try db.ingest(feed_id, &.{entry}, 2000);
    try testing.expectEqual(2000, (try db.listEntries(arena.allocator(), .{}))[0].sort_at);
}

/// Builds an arena-owned JSON value from a typed response without borrowing temporary text.
pub fn object(a: std.mem.Allocator, value: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        a,
        try std.fmt.allocPrint(
            a,
            "{f}",
            .{std.json.fmt(value, .{})},
        ),
        .{},
    );
}

fn conflict(a: std.mem.Allocator, current: std.json.Value) !std.json.Value {
    return object(a, .{ .kind = "revision_conflict", .current = current });
}
const Context = opaque {};
const SqlValue = opaque {};
extern fn sqlite3_create_function_v2(
    *Handle,
    [*:0]const u8,
    c_int,
    c_int,
    ?*anyopaque,
    ?*const fn (?*Context, c_int, [*]?*SqlValue) callconv(.c) void,
    ?*anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) c_int;
extern fn sqlite3_value_text(?*SqlValue) ?[*:0]const u8;
extern fn sqlite3_result_error_nomem(?*Context) void;

test "reader views, rule counts, revisions and bulk undo are transactional" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try db.ensureFolder(null, "Engineering");
    const child = try db.ensureFolder(folder, "Storage");
    const feed = try db.addFeed("https://example.com/feed", false, 1000);
    try db.setFeedDetails(feed, null, child);
    var one = sample("a", "Storage engine", "1");
    one.url = "https://NEWS.example.com:443/a/../blog/one?q=1#fragment";
    var two = sample("b", "Compiler", "2");
    two.url = "https://example.com/blog/jobs/two";
    var three = sample("c", "Addressless", "3");
    three.url = null;
    _ = try db.ingest(feed, &.{ one, two, three }, 2000);
    const rule = try core.selector.parse(
        a,
        try std.fmt.allocPrint(
            a,
            "{{\"folders\":[{d}],\"host\":\"example.com\",\"subdomains\":true,\"path_prefix\"" ++
                ":\"/blog/\",\"exclude_path_prefix\":[\"/blog/jobs/\"]}}",
            .{folder},
        ),
    );
    const selection = try db.selectRule(a, rule, 3000, 1, null, null, null);
    try testing.expectEqual(@as(i64, 1), selection.total);
    try testing.expectEqual(@as(i64, 1), selection.unread);
    const exact = try db.selectRule(
        a,
        .{
            .host = "news.example.com",
            .path_prefix = "/blog",
        },
        3000,
        50,
        null,
        null,
        null,
    );
    try testing.expectEqual(@as(i64, 1), exact.total);
    const expired = try db.selectRule(a, .{ .within_days = 1 }, 2 * 86400000, 50, null, null, null);
    try testing.expectEqual(@as(i64, 0), expired.total);
    const all = try db.selectRule(a, .{}, 3000, 1, null, null, null);
    const next = try db.selectRule(
        a,
        .{},
        3000,
        50,
        .{
            .sort_at = all.items[0].sort_at,
            .id = all.items[0].id,
        },
        null,
        null,
    );
    try testing.expectEqual(@as(i64, 3), next.total);
    try testing.expectEqual(@as(usize, 2), next.items.len);
    const union_scope = try db.selectRule(a, .{ .feeds = &.{feed}, .folders = &.{folder} }, 3000, 50, null, null, null);
    try testing.expectEqual(@as(i64, 3), union_scope.total);
    const id = selection.items[0].id;
    const old = try db.markMany(a, &.{id}, .{ .read = true, .later = true }, 4000);
    try testing.expect(!old[0].read and !old[0].later);
    try testing.expectEqual(
        @as(i64, 0),
        (try db.selectRule(
            a,
            .{
                .state = .unread,
                .host = "news.example.com",
            },
            5000,
            10,
            null,
            null,
            null,
        )).total,
    );
    try testing.expectEqual(
        @as(i64, 1),
        (try db.selectRule(
            a,
            .{ .state = .later },
            5000,
            10,
            null,
            null,
            null,
        )).total,
    );
    try testing.expectError(error.NoSuchEntry, db.markMany(a, &.{ id, 9999 }, .{ .read = false }, 5000));
    try testing.expect((try db.getEntry(a, id)).?.read);
    const view = try db.viewPut(
        a,
        null,
        "Engineering",
        try std.fmt.allocPrint(
            a,
            "{f}",
            .{std.json.fmt(rule, .{})},
        ),
        null,
        3000,
    );
    const view_id = view.object.get("id").?.integer;
    const conflict_value = try db.viewPut(a, view_id, "New", "{}", 0, 4000);
    try testing.expectEqualStrings("revision_conflict", conflict_value.object.get("kind").?.string);
    _ = try db.viewPut(a, view_id, "New", "{}", 1, 4000);
    _ = try db.recipePut(a, 1, "Morning brief", "Different", "note", 1, false, 5000);
    try testing.expectEqualStrings("Different", (try db.recipeGet(a, 1, null)).object.get("text").?.string);
    try testing.expect((try db.recipeGet(a, 1, 1)).object.get("text").?.string.len > 20);
    _ = try db.recipePut(a, 1, "Morning brief", "", "reset", 2, true, 6000);
    try testing.expectEqual(@as(usize, 3), (try db.recipeHistory(a, 1)).len);
    for ([_][]const u8{ "zig", "zig OR impossible", "\" OR *", "title:zig", "NOT", "*" }) |word| {
        const sel = try db.selectRule(a, .{ .words = word }, 5000, 10, null, null, null);
        try testing.expectEqual(sel.total, @as(i64, @intCast(sel.items.len)));
    }
}
extern fn sqlite3_result_text(?*Context, [*]const u8, c_int, ?*anyopaque) void;
extern fn sqlite3_result_null(?*Context) void;

fn articleHost(ctx: ?*Context, n: c_int, values: [*]?*SqlValue) callconv(.c) void {
    _ = n;
    addressPart(ctx, values, true);
}

fn articlePath(ctx: ?*Context, n: c_int, values: [*]?*SqlValue) callconv(.c) void {
    _ = n;
    addressPart(ctx, values, false);
}

fn addressPart(ctx: ?*Context, values: [*]?*SqlValue, host_part: bool) void {
    const raw = sqlite3_value_text(values[0]) orelse {
        sqlite3_result_null(ctx);
        return;
    };
    const address = std.mem.span(raw);
    if (!core.url.isHttp(address)) {
        sqlite3_result_null(ctx);
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parts = core.url.split(core.url.resolve(a, address, core.url.split(address).path) catch {
        sqlite3_result_error_nomem(ctx);
        return;
    });
    var host = parts.authority orelse {
        sqlite3_result_null(ctx);
        return;
    };
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    const result = if (host_part) a.dupe(u8, host) catch {
        sqlite3_result_error_nomem(ctx);
        return;
    } else a.dupe(u8, if (parts.path.len == 0) "/" else parts.path) catch {
        sqlite3_result_error_nomem(ctx);
        return;
    };
    if (host_part) for (result) |*c| {
        c.* = std.ascii.toLower(c.*);
    };
    sqlite3_result_text(ctx, result.ptr, @intCast(result.len), @ptrFromInt(std.math.maxInt(usize)));
}

test "routine claims coalesce missed runs and survive job lease recovery" {
    var db: Db = try .open(":memory:", .writer);
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const view = try db.viewPut(
        a,
        null,
        "All",
        try std.fmt.allocPrint(
            a,
            "{f}",
            .{std.json.fmt(
                core.selector.Rule{},
                .{},
            )},
        ),
        null,
        1000,
    );
    const vid = view.object.get("id").?.integer;
    const routine = try db.routinePut(
        a,
        null,
        "Daily",
        vid,
        "{\"kind\":\"daily\",\"time\":\"09:00\"}",
        "[{\"kind\":\"notify\"}]",
        true,
        null,
        1000,
        2000,
    );
    const rid = routine.object.get("id").?.integer;
    const now = 5 * 86400000;
    try testing.expectEqual(@as(usize, 1), (try db.dueRoutines(a, now)).len);
    const actions = try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"kind\":\"notify\"}]", .{});
    const job = try db.routineStart(a, rid, &.{}, actions, now, now + 86400000, vid, .{});
    const jid = job.object.get("id").?.integer;
    try testing.expectError(error.RoutineBusy, db.routineStart(a, rid, &.{}, actions, now, null, vid, .{}));
    try testing.expectEqual(@as(usize, 0), (try db.dueRoutines(a, now)).len);
    _ = (try db.jobClaim(a, now)).?;
    try testing.expectEqual(Db.JobStatus.running, try db.jobStatus(jid));
    try db.recoverJobs(now + 1);
    try testing.expectEqual(Db.JobStatus.queued, try db.jobStatus(jid));
    try testing.expectError(error.RoutineBusy, db.routineStart(a, rid, &.{}, actions, now, null, vid, .{}));
    _ = (try db.jobClaim(a, now + 2)).?;
    try db.routineFinish(jid, "[{\"kind\":\"notify\",\"status\":\"done\"}]", "done", now + 3);
    try db.jobFinish(jid, "done", null, now + 3);
    const runs = try db.routineRuns(a, rid, 10);
    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqualStrings("done", runs[0].object.get("status").?.string);
    try testing.expectEqual(@as(usize, 0), (try db.dueRoutines(a, now + 4)).len);
}
