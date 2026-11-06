//! Spike: SQLite amalgamation from build.zig, hand-written externs, real schema.
//! Usage: bench <db-path> <schema.sql> <rows>
const std = @import("std");
const Io = std.Io;

const Db = opaque {};
const Stmt = opaque {};
extern fn sqlite3_open(path: [*:0]const u8, db: *?*Db) c_int;
extern fn sqlite3_close(db: *Db) c_int;
extern fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*anyopaque) c_int;
extern fn sqlite3_errmsg(db: *Db) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: *Db, sql: [*:0]const u8, len: c_int, stmt: *?*Stmt, tail: ?*anyopaque) c_int;
extern fn sqlite3_finalize(stmt: *Stmt) c_int;
extern fn sqlite3_reset(stmt: *Stmt) c_int;
extern fn sqlite3_step(stmt: *Stmt) c_int;
extern fn sqlite3_bind_int64(stmt: *Stmt, i: c_int, v: i64) c_int;
extern fn sqlite3_bind_text(stmt: *Stmt, i: c_int, s: [*]const u8, n: c_int, destructor: ?*anyopaque) c_int;
extern fn sqlite3_column_int64(stmt: *Stmt, i: c_int) i64;
extern fn sqlite3_libversion() [*:0]const u8;

const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

fn check(db: *Db, rc: c_int) void {
    if (rc != 0 and rc != SQLITE_ROW and rc != SQLITE_DONE) {
        std.debug.print("sqlite error {d}: {s}\n", .{ rc, sqlite3_errmsg(db) });
        std.process.exit(1);
    }
}

fn exec(db: *Db, sql: [*:0]const u8) void {
    check(db, sqlite3_exec(db, sql, null, null, null));
}

fn prepare(db: *Db, sql: [*:0]const u8) *Stmt {
    var stmt: ?*Stmt = null;
    check(db, sqlite3_prepare_v2(db, sql, -1, &stmt, null));
    return stmt.?;
}

const vocab_size = 50_000;

/// Zipf-like draw, so that term frequencies resemble real text.
fn wordId(r: std.Random) u32 {
    const u = r.float(f64);
    const id: u32 = @intFromFloat(@floor(std.math.pow(f64, vocab_size, u)));
    return id -| 1;
}

fn writeWord(buf: []u8, id: u32) usize {
    return (std.fmt.bufPrint(buf, "w{d} ", .{id}) catch unreachable).len;
}

fn fill(r: std.Random, buf: []u8, words: usize) usize {
    var n: usize = 0;
    for (0..words) |_| n += writeWord(buf[n..], wordId(r));
    return n;
}

fn now(io: Io) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake);
}

fn elapsedUs(io: Io, from: Io.Clock.Timestamp) i64 {
    return @intCast(@divTrunc(from.durationTo(now(io)).raw.nanoseconds, 1000));
}

fn report(name: []const u8, samples: []i64) void {
    std.mem.sort(i64, samples, {}, std.sort.asc(i64));
    const p = struct {
        fn at(s: []i64, q: usize) f64 {
            return @as(f64, @floatFromInt(s[(s.len - 1) * q / 100])) / 1000.0;
        }
    }.at;
    std.debug.print("{s:<34} p50 {d:>8.2} ms   p95 {d:>8.2} ms   max {d:>8.2} ms\n", .{ name, p(samples, 50), p(samples, 95), p(samples, 100) });
}

/// Runs `stmt` to completion for each query term and records latency.
fn timeSearch(io: Io, db: *Db, name: []const u8, sql: [*:0]const u8, terms: []const u32, arena: std.mem.Allocator) !void {
    const stmt = prepare(db, sql);
    defer _ = sqlite3_finalize(stmt);
    const samples = try arena.alloc(i64, terms.len);
    var rows: usize = 0;
    for (terms, samples) |t, *s| {
        var term_buf: [16]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "w{d}", .{t});
        const start = now(io);
        check(db, sqlite3_bind_text(stmt, 1, term.ptr, @intCast(term.len), null));
        while (sqlite3_step(stmt) == SQLITE_ROW) rows += 1;
        check(db, sqlite3_reset(stmt));
        s.* = elapsedUs(io, start);
    }
    report(name, samples);
    std.debug.print("    rows returned per query: {d}\n", .{rows / terms.len});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const rows = try std.fmt.parseInt(usize, args[3], 10);
    const path = try arena.dupeSentinel(u8, args[1], 0);
    const schema = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 20));
    const schema_z = try arena.dupeSentinel(u8, schema, 0);

    var db_opt: ?*Db = null;
    check(db_opt orelse @ptrFromInt(8), sqlite3_open(path, &db_opt));
    const db = db_opt.?;
    defer _ = sqlite3_close(db);
    std.debug.print("sqlite {s}\n", .{sqlite3_libversion()});

    exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA mmap_size=4294967296; PRAGMA cache_size=-262144;");

    var prng: std.Random.DefaultPrng = .init(20261106);
    const r = prng.random();

    var count_stmt: ?*Stmt = null;
    const fresh = sqlite3_prepare_v2(db, "SELECT count(*) FROM entries", -1, &count_stmt, null) != 0;
    if (count_stmt) |s| _ = sqlite3_finalize(s);

    if (fresh) {
        exec(db, schema_z);
        exec(db, "BEGIN");
        for (0..1000) |i| {
            var b: [96:0]u8 = undefined;
            const sql = try std.fmt.bufPrintSentinel(&b, "INSERT INTO feeds(url,created_at) VALUES('https://e{d}.test/f',0)", .{i}, 0);
            exec(db, sql);
        }
        exec(db, "COMMIT");

        const insert = prepare(db,
            \\INSERT INTO entries(feed_id,identity,url,title,first_seen_at,sort_at,content_text,content_hash)
            \\VALUES(?1,?2,?3,?4,?5,?5,?6,?7)
        );
        defer _ = sqlite3_finalize(insert);

        const start = now(io);
        var text: [16 * 1024]u8 = undefined;
        var title: [512]u8 = undefined;
        var ident: [32]u8 = undefined;
        exec(db, "BEGIN");
        for (0..rows) |i| {
            const id = try std.fmt.bufPrint(&ident, "e{d}", .{i});
            const n_title = fill(r, &title, 8);
            const n_text = fill(r, &text, 100 + r.uintLessThan(usize, 300));
            check(db, sqlite3_bind_int64(insert, 1, @intCast(1 + r.uintLessThan(usize, 1000))));
            check(db, sqlite3_bind_text(insert, 2, id.ptr, @intCast(id.len), null));
            check(db, sqlite3_bind_text(insert, 3, id.ptr, @intCast(id.len), null));
            check(db, sqlite3_bind_text(insert, 4, &title, @intCast(n_title), null));
            check(db, sqlite3_bind_int64(insert, 5, @intCast(i * 60_000)));
            check(db, sqlite3_bind_text(insert, 6, &text, @intCast(n_text), null));
            check(db, sqlite3_bind_text(insert, 7, id.ptr, @intCast(id.len), null));
            check(db, sqlite3_step(insert));
            check(db, sqlite3_reset(insert));
            if (i % 1000 == 999) {
                exec(db, "COMMIT");
                exec(db, "BEGIN");
            }
        }
        exec(db, "COMMIT");
        const s: f64 = @as(f64, @floatFromInt(elapsedUs(io, start))) / 1e6;
        std.debug.print("inserted {d} rows in {d:.1}s ({d:.0} rows/s)\n", .{ rows, s, @as(f64, @floatFromInt(rows)) / s });
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE); ANALYZE;");
    }

    // Timeline: first page, then deep pages by keyset.
    {
        const stmt = prepare(db, "SELECT id,title,sort_at FROM entries WHERE sort_at < ?1 ORDER BY sort_at DESC, id DESC LIMIT 50");
        defer _ = sqlite3_finalize(stmt);
        var samples: [200]i64 = undefined;
        for (&samples) |*s| {
            const start = now(io);
            check(db, sqlite3_bind_int64(stmt, 1, @intCast(r.uintLessThan(usize, rows) * 60_000 + 1)));
            while (sqlite3_step(stmt) == SQLITE_ROW) {}
            check(db, sqlite3_reset(stmt));
            s.* = elapsedUs(io, start);
        }
        report("timeline page of 50, random depth", &samples);
    }

    // Unread timeline joins user state, which is what a reader shows by default.
    {
        const stmt = prepare(db,
            \\SELECT e.id,e.title FROM entries e LEFT JOIN entry_state s ON s.entry_id=e.id
            \\WHERE e.feed_id=?1 AND s.read_at IS NULL ORDER BY e.sort_at DESC, e.id DESC LIMIT 50
        );
        defer _ = sqlite3_finalize(stmt);
        var samples: [200]i64 = undefined;
        for (&samples) |*s| {
            const start = now(io);
            check(db, sqlite3_bind_int64(stmt, 1, @intCast(1 + r.uintLessThan(usize, 1000))));
            while (sqlite3_step(stmt) == SQLITE_ROW) {}
            check(db, sqlite3_reset(stmt));
            s.* = elapsedUs(io, start);
        }
        report("unread in one feed, page of 50", &samples);
    }

    const buckets = [_]struct { name: []const u8, lo: u32, hi: u32 }{
        .{ .name = "common", .lo = 0, .hi = 20 },
        .{ .name = "mid", .lo = 200, .hi = 2000 },
        .{ .name = "rare", .lo = 20000, .hi = 49000 },
    };
    for (buckets) |b| {
        var terms: [50]u32 = undefined;
        for (&terms) |*t| t.* = b.lo + r.uintLessThan(u32, b.hi - b.lo);
        var name: [64]u8 = undefined;
        try timeSearch(io, db, try std.fmt.bufPrint(&name, "search {s}, by relevance", .{b.name}),
            "SELECT rowid, snippet(entries_fts,2,'','','…',12) FROM entries_fts WHERE entries_fts MATCH ?1 ORDER BY rank LIMIT 20", &terms, arena);
        try timeSearch(io, db, try std.fmt.bufPrint(&name, "search {s}, newest first", .{b.name}),
            "SELECT rowid, snippet(entries_fts,2,'','','…',12) FROM entries_fts WHERE entries_fts MATCH ?1 ORDER BY rowid DESC LIMIT 20", &terms, arena);
    }
}
