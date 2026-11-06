//! Runs the parser over a directory of real feeds.
//!
//!   feedcheck corpus                    parse everything, print statistics
//!   feedcheck corpus --mutate 100 1     100 random mutations per feed, seed 1
//!   feedcheck corpus --dump             one JSON line per feed, for tools/oracle.py
//!   feedcheck corpus --hostile          time inputs built to trigger slow paths
//!   feedcheck corpus --html             convert every entry body to blocks
//!   feedcheck corpus --html-dump        bodies and their text, for tools/oracle_html.py
//!   feedcheck --extract page.html url   print the article found in a saved page
//!
//! Mutation mode reports the slowest parse relative to input size, since a
//! hostile feed that is slow to parse is as much a bug as one that crashes.

const std = @import("std");
const core = @import("core");
const Io = std.Io;
const feed = core.feed;

const Sample = struct { name: []const u8, bytes: []const u8 };

var current_name: []const u8 = "";
var current_iteration: u64 = 0;
var current_seed: u64 = 0;

pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(message: []const u8, return_address: ?usize) noreturn {
    std.debug.print("\nPANIC on {s}, seed {d}, iteration {d}\n", .{ current_name, current_seed, current_iteration });
    std.debug.defaultPanic(message, return_address);
}

fn now(io: Io) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, .awake);
}

fn elapsedNs(io: Io, from: Io.Clock.Timestamp) u64 {
    return @intCast(from.durationTo(now(io)).raw.nanoseconds);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingDirectory;

    if (args.len >= 4 and std.mem.eql(u8, args[1], "--extract")) {
        const page = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(64 << 20));
        const text = try core.encoding.toUtf8(arena, page);
        const nodes = (try core.extract.extract(arena, text, args[3])) orelse return;
        var out: Io.Writer.Allocating = .init(arena);
        try core.blocks.writeText(&out.writer, nodes);
        var buffer: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &buffer);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
        return;
    }

    var dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);

    var samples: std.ArrayList(Sample) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |item| {
        if (!std.mem.endsWith(u8, item.name, ".feed")) continue;
        const bytes = try dir.readFileAlloc(io, item.name, arena, .limited(64 << 20));
        try samples.append(arena, .{ .name = try arena.dupe(u8, item.name), .bytes = bytes });
    }
    std.mem.sort(Sample, samples.items, {}, struct {
        fn lessThan(_: void, a: Sample, b: Sample) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    if (args.len >= 5 and std.mem.eql(u8, args[2], "--mutate")) {
        const rounds = try std.fmt.parseInt(u64, args[3], 10);
        const seed = try std.fmt.parseInt(u64, args[4], 10);
        try mutate(init.gpa, io, samples.items, rounds, seed);
    } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--html")) {
        try htmlCheck(init.gpa, io, samples.items);
    } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--html-dump")) {
        try htmlDump(init.gpa, io, samples.items);
    } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--hostile")) {
        try hostile(init.gpa, io);
    } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--dump")) {
        try dump(init.gpa, io, samples.items);
    } else {
        try check(init.gpa, io, samples.items);
    }
}

/// Each unit is repeated to fill the input, after a prefix. Linear code costs the
/// same per byte at both sizes, so a rising figure means a quadratic path.
fn hostile(gpa: std.mem.Allocator, io: Io) !void {
    const rss = "<rss><channel><item><title>";
    const cases = [_]struct { prefix: []const u8, unit: []const u8 }{
        .{ .prefix = "", .unit = "<a>" },
        .{ .prefix = "", .unit = "<a " },
        .{ .prefix = "", .unit = "<" },
        .{ .prefix = "", .unit = "<a x=\"" },
        .{ .prefix = "", .unit = "<a x='>" },
        .{ .prefix = "", .unit = "<!" },
        .{ .prefix = "", .unit = "<!--" },
        .{ .prefix = "", .unit = "<?" },
        .{ .prefix = rss, .unit = "&" },
        .{ .prefix = rss, .unit = "&#" },
        .{ .prefix = rss, .unit = "&#x41;" },
        .{ .prefix = rss, .unit = "<![CDATA[" },
        .{ .prefix = rss, .unit = "<![CDATA[x]]<" },
        .{ .prefix = rss, .unit = "<![CDATA[x]]>" },
        .{ .prefix = rss, .unit = "x<![CDATA[y]]>" },
        .{ .prefix = rss, .unit = "</x>" },
        .{ .prefix = "<a><a><a><a><a><a><a><a><a><a><a><a><a><a><a><a>", .unit = "</b>" },
        .{ .prefix = "<rss xmlns:p=\"u\">", .unit = "<p:a xmlns:q=\"v\"/>" },
        .{ .prefix = "<rss><channel>", .unit = "<item><title>a</title></item>" },
        .{ .prefix = "<rss><channel>", .unit = "<item><guid>same</guid><title>a</title></item>" },
        .{ .prefix = "<rss><channel>", .unit = "<item><guid>s</guid><title>" },
        .{ .prefix = "<rss><channel><item>", .unit = "<category>a</category>" },
        .{ .prefix = "<rss><channel><item>", .unit = "<media:group>" },
        .{ .prefix = "<feed>", .unit = "<entry><author><name>" },
        .{ .prefix = "", .unit = "[" },
        .{ .prefix = "{\"version\":\"https://jsonfeed.org/version/1\",\"items\":", .unit = "[" },
        .{ .prefix = "{\"a\":", .unit = "{\"a\":" },
        .{ .prefix = "<?xml encoding=\"latin1\"?>", .unit = "\xE9" },
        .{ .prefix = "\xFF\xFE", .unit = "<\x00" },
    };
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var worst: f64 = 0;
    std.debug.print("{s:<36} {s:>9} {s:>9}\n", .{ "repeated unit", "1 MB", "8 MB" });
    for (cases) |case| {
        var rates: [2]f64 = undefined;
        for ([_]usize{ 1 << 20, 8 << 20 }, &rates) |size, *rate| {
            buffer.clearRetainingCapacity();
            try buffer.appendSlice(gpa, case.prefix);
            while (buffer.items.len < size) try buffer.appendSlice(gpa, case.unit);
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const start = now(io);
            if (feed.parse(arena_state.allocator(), buffer.items)) |value| {
                _ = try feed.identities(arena_state.allocator(), value.entries);
            } else |_| {}
            rate.* = @as(f64, @floatFromInt(elapsedNs(io, start))) / @as(f64, @floatFromInt(size));
        }
        worst = @max(worst, rates[1]);
        std.debug.print("{f:<36} {d:>6.1} ns {d:>6.1} ns\n", .{ std.ascii.hexEscape(case.unit[0..@min(case.unit.len, 30)], .lower), rates[0], rates[1] });
    }
    std.debug.print("worst {d:.1} ns per byte at 8 MB\n", .{worst});

    const html_units = [_][]const u8{
        "<",            "<a",       "<a ",         "<p>",    "</p>",          "<div>",    "</div>",            "<b>",   "<ul><li>", "<li>",           "<table><tr><td>",               "<td>", "<tr>",
        "<blockquote>", "<pre>",    "<pre></pre>", "<code>", "<code></code>", "<script>", "<script></script>", "</scr", "<!--",     "<a href=\"x\">", "<img src=\"http://e.test/a\">", "&",    "&amp;",
        "<br>",         "<iframe>", "<h1>",        "x ",     " ",
    };
    worst = 0;
    std.debug.print("\nHTML: {s:<28} {s:>9} {s:>9}\n", .{ "repeated unit", "1 MB", "8 MB" });
    for (html_units) |unit| {
        var rates: [2]f64 = undefined;
        for ([_]usize{ 1 << 20, 8 << 20 }, &rates) |size, *rate| {
            buffer.clearRetainingCapacity();
            while (buffer.items.len < size) try buffer.appendSlice(gpa, unit);
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const start = now(io);
            _ = try core.html.toBlocks(arena_state.allocator(), buffer.items, .{ .base = "https://example.com/a/b" });
            rate.* = @as(f64, @floatFromInt(elapsedNs(io, start))) / @as(f64, @floatFromInt(size));
        }
        worst = @max(worst, rates[1]);
        std.debug.print("{f:<34} {d:>6.1} ns {d:>6.1} ns\n", .{ std.ascii.hexEscape(unit, .lower), rates[0], rates[1] });
    }
    std.debug.print("worst {d:.1} ns per byte at 8 MB\n", .{worst});
}

fn bodyOf(entry: feed.Entry) ?feed.Body {
    return entry.content orelse entry.summary;
}

fn convert(arena: std.mem.Allocator, body: feed.Body) ![]const core.blocks.Node {
    return switch (body.kind) {
        .html => core.html.toBlocks(arena, body.value, .{ .base = "https://example.com/" }),
        .text => core.html.textToBlocks(arena, body.value),
    };
}

fn htmlCheck(gpa: std.mem.Allocator, io: Io, samples: []const Sample) !void {
    var bodies: usize = 0;
    var empty: usize = 0;
    var input_bytes: usize = 0;
    var json_bytes: usize = 0;
    var total_ns: u64 = 0;
    var laid_out: usize = 0;
    var overflowing: usize = 0;
    var counts: [@typeInfo(core.blocks.Kind).@"enum".field_names.len]usize = @splat(0);

    for (samples) |sample| {
        current_name = sample.name;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = feed.parse(arena, sample.bytes) catch continue;
        for (parsed.entries) |entry| {
            const body = bodyOf(entry) orelse continue;
            bodies += 1;
            input_bytes += body.value.len;
            const start = now(io);
            const nodes = try convert(arena, body);
            total_ns += elapsedNs(io, start);
            if (nodes.len == 0) empty += 1;
            for (nodes) |node| counts[@backingInt(node.kind)] += 1;

            var out: Io.Writer.Allocating = .init(arena);
            try core.blocks.writeJson(&out.writer, nodes);
            const json = out.written();
            json_bytes += json.len;

            // Stored JSON must read back to exactly the same JSON.
            var again: Io.Writer.Allocating = .init(arena);
            try core.blocks.writeJson(&again.writer, try core.blocks.parseJson(arena, json));
            for ([_]usize{ 24, 60, 80 }) |columns| {
                const article = try core.layout.lay(arena, nodes, columns);
                laid_out += article.lines.len;
                for (article.lines) |line| {
                    var used: usize = 0;
                    for (line.spans) |span| used += core.terminal.displayWidth(span.text);
                    const trimmed = if (line.spans.len != 0) std.mem.trimEnd(u8, line.spans[line.spans.len - 1].text, " ") else "";
                    const trailing = if (line.spans.len != 0) line.spans[line.spans.len - 1].text.len - trimmed.len else 0;
                    if (used -| trailing > columns) overflowing += 1;
                }
            }
            if (!std.mem.eql(u8, json, again.written())) {
                const at = std.mem.indexOfDiff(u8, json, again.written()).?;
                std.debug.print("first:  {s}\nsecond: {s}\n", .{ json[at -| 60..@min(json.len, at + 60)], again.written()[at -| 60..@min(again.written().len, at + 60)] });
                @panic("blocks did not round-trip");
            }
        }
    }
    std.debug.print("bodies {d}, empty after conversion {d}\n", .{ bodies, empty });
    std.debug.print("laid out {d} lines at 3 widths, {d} too wide\n", .{ laid_out, overflowing });
    std.debug.print("top-level blocks:", .{});
    inline for (@typeInfo(core.blocks.Kind).@"enum".field_names, 0..) |name, i| {
        if (counts[i] != 0) std.debug.print(" {s}={d}", .{ name, counts[i] });
    }
    const mb = @as(f64, @floatFromInt(input_bytes)) / 1e6;
    const seconds = @as(f64, @floatFromInt(total_ns)) / 1e9;
    std.debug.print("\n{d:.1} MB of HTML in {d:.3} s = {d:.0} MB/s, stored JSON is {d:.1} MB\n", .{ mb, seconds, mb / seconds, @as(f64, @floatFromInt(json_bytes)) / 1e6 });
}

fn htmlDump(gpa: std.mem.Allocator, io: Io, samples: []const Sample) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    for (samples) |sample| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = feed.parse(arena, sample.bytes) catch continue;
        for (parsed.entries) |entry| {
            const body = bodyOf(entry) orelse continue;
            if (body.kind != .html) continue;
            const nodes = try convert(arena, body);
            var text: Io.Writer.Allocating = .init(arena);
            try core.blocks.writeText(&text.writer, nodes);
            var json: Io.Writer.Allocating = .init(arena);
            try core.blocks.writeJson(&json.writer, nodes);
            try out.print("{f}\n", .{std.json.fmt(.{ .name = sample.name, .html = body.value, .text = text.written(), .blocks = json.written() }, .{})});
        }
    }
    try out.flush();
}

fn dump(gpa: std.mem.Allocator, io: Io, samples: []const Sample) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    for (samples) |sample| {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const parsed = feed.parse(arena_state.allocator(), sample.bytes) catch continue;
        try out.print("{f}\n", .{std.json.fmt(.{
            .name = sample.name,
            .format = @tagName(parsed.format),
            .title = parsed.title,
            .entries = parsed.entries,
        }, .{})});
    }
    try out.flush();
}

fn check(gpa: std.mem.Allocator, io: Io, samples: []const Sample) !void {
    var formats: [@typeInfo(feed.Format).@"enum".field_names.len]usize = @splat(0);
    var ok: usize = 0;
    var not_feed: usize = 0;
    var unsupported: usize = 0;
    var too_deep: usize = 0;
    var empty: usize = 0;
    var entries: usize = 0;
    var no_title: usize = 0;
    var no_url: usize = 0;
    var no_guid: usize = 0;
    var no_date: usize = 0;
    var no_body: usize = 0;
    var full_body: usize = 0;
    var bad_dates: usize = 0;
    var total_bytes: usize = 0;
    var total_ns: u64 = 0;
    var no_feed_title: usize = 0;
    var durations: std.ArrayList(u64) = .empty;
    defer durations.deinit(gpa);

    for (samples) |sample| {
        current_name = sample.name;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const start = now(io);
        const result = feed.parse(arena, sample.bytes);
        const ns = elapsedNs(io, start);

        const parsed = result catch |err| {
            switch (err) {
                error.NotAFeed => {
                    not_feed += 1;
                    const head = sample.bytes[0..@min(sample.bytes.len, 60)];
                    std.debug.print("not a feed: {s} {f}\n", .{ sample.name, std.ascii.hexEscape(head, .lower) });
                },
                error.UnsupportedEncoding => {
                    unsupported += 1;
                    std.debug.print("encoding: {s} {s}\n", .{ sample.name, core.encoding.declaredEncoding(sample.bytes) });
                },
                error.TooDeep => {
                    too_deep += 1;
                    std.debug.print("too deep: {s}\n", .{sample.name});
                },
                error.OutOfMemory => return err,
            }
            continue;
        };

        ok += 1;
        total_bytes += sample.bytes.len;
        total_ns += ns;
        try durations.append(gpa, ns * 100_000 / @max(sample.bytes.len, 1));
        formats[@backingInt(parsed.format)] += 1;
        if (parsed.entries.len == 0) {
            empty += 1;
            std.debug.print("no entries: {s}\n", .{sample.name});
        }
        if (parsed.title == null) no_feed_title += 1;
        bad_dates += parsed.unparsed_dates;
        if (parsed.sample_unparsed_date) |text| std.debug.print("bad date x{d}: {s} [{s}]\n", .{ parsed.unparsed_dates, sample.name, text });

        for (parsed.entries) |entry| {
            entries += 1;
            if (entry.title == null) no_title += 1;
            if (entry.url == null) no_url += 1;
            if (entry.guid == null) no_guid += 1;
            if (entry.published_at == null and entry.updated_at == null) no_date += 1;
            if (entry.content == null and entry.summary == null) no_body += 1;
            if (entry.content != null) full_body += 1;
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var duplicates: usize = 0;
        for (try feed.identities(arena, parsed.entries)) |id| {
            const slot = try seen.getOrPut(arena, id);
            if (slot.found_existing) duplicates += 1;
        }
        if (duplicates != 0) std.debug.print("repeated entry x{d}: {s}\n", .{ duplicates, sample.name });
    }

    std.mem.sort(u64, durations.items, {}, std.sort.asc(u64));
    std.debug.print("\nfiles {d}: parsed {d}, not a feed {d}, unsupported encoding {d}, too deep {d}\n", .{ samples.len, ok, not_feed, unsupported, too_deep });
    inline for (@typeInfo(feed.Format).@"enum".field_names, 0..) |name, i| {
        if (formats[i] != 0) std.debug.print("  {s}: {d}\n", .{ name, formats[i] });
    }
    std.debug.print("feeds with no entries {d}, no title {d}\n", .{ empty, no_feed_title });
    std.debug.print("entries {d}: no title {d}, no url {d}, no guid {d}, no date {d}, no body {d}, full content {d}, unreadable dates {d}\n", .{ entries, no_title, no_url, no_guid, no_date, no_body, full_body, bad_dates });
    const mb = @as(f64, @floatFromInt(total_bytes)) / 1e6;
    const seconds = @as(f64, @floatFromInt(total_ns)) / 1e9;
    std.debug.print("{d:.1} MB in {d:.3} s = {d:.0} MB/s\n", .{ mb, seconds, mb / seconds });
    if (durations.items.len != 0) {
        const items = durations.items;
        std.debug.print("per 100 KB: p50 {d} us, p95 {d} us\n", .{ items[items.len / 2] / 1000, items[items.len * 95 / 100] / 1000 });
    }
}

const dictionary = [_][]const u8{
    "<",      ">",                        "</",        "/>",      "&",                        "&#x",    ";",
    "\"",     "'",                        "<![CDATA[", "]]>",     "<!--",                     "-->",    "<?",
    "?>",     "<!DOCTYPE",                "<!ENTITY",  "[",       "]",                        "xmlns=", "xmlns:a=",
    "<item>", "</item>",                  "<entry>",   "<title>", "<content type=\"xhtml\">", "\x00",   "\xFF\xFE",
    "\xC3",   "<a><a><a><a><a><a><a><a>",
};

fn mutate(gpa: std.mem.Allocator, io: Io, samples: []const Sample, rounds: u64, seed: u64) !void {
    current_seed = seed;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);

    var runs: u64 = 0;
    var parsed: u64 = 0;
    var worst_rate: f64 = 0;
    var worst_name: []const u8 = "";
    var worst_iteration: u64 = 0;
    const started = now(io);

    for (samples, 0..) |sample, sample_index| {
        if (sample.bytes.len > 1 << 20) continue;
        current_name = sample.name;
        for (0..rounds) |round| {
            current_iteration = round;
            var prng: std.Random.DefaultPrng = .init(seed ^ (sample_index *% 0x9E3779B97F4A7C15) ^ (round *% 0xBF58476D1CE4E5B9));
            const r = prng.random();

            buffer.clearRetainingCapacity();
            try buffer.appendSlice(gpa, sample.bytes);
            const edits = 1 + r.uintLessThan(usize, 16);
            for (0..edits) |_| try applyMutation(gpa, r, &buffer, samples);

            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const start = now(io);
            const result = feed.parse(arena, buffer.items);
            const ns = elapsedNs(io, start);
            runs += 1;
            if (result) |value| {
                parsed += 1;
                _ = try feed.identities(arena, value.entries);
                for (value.entries[0..@min(value.entries.len, 8)]) |entry| {
                    const body = bodyOf(entry) orelse continue;
                    var out: Io.Writer.Allocating = .init(arena);
                    try core.blocks.writeMarkdown(&out.writer, try convert(arena, body));
                }
            } else |err| {
                if (err == error.OutOfMemory) return err;
            }

            var rate = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(buffer.items.len + 4096));
            if (rate > worst_rate) {
                // A candidate must be slow twice, or it was the OS pausing us.
                var retry_arena: std.heap.ArenaAllocator = .init(gpa);
                defer retry_arena.deinit();
                const retry = now(io);
                _ = feed.parse(retry_arena.allocator(), buffer.items) catch {};
                const retry_ns = elapsedNs(io, retry);
                rate = @min(rate, @as(f64, @floatFromInt(retry_ns)) / @as(f64, @floatFromInt(buffer.items.len + 4096)));
            }
            if (rate > worst_rate) {
                worst_rate = rate;
                worst_name = sample.name;
                worst_iteration = round;
            }
        }
    }

    const seconds = @as(f64, @floatFromInt(elapsedNs(io, started))) / 1e9;
    std.debug.print("{d} mutated inputs in {d:.1} s, {d} still parsed as feeds, no crashes\n", .{ runs, seconds, parsed });
    std.debug.print("slowest: {d:.0} ns per byte on {s}, iteration {d}\n", .{ worst_rate, worst_name, worst_iteration });
}

fn applyMutation(gpa: std.mem.Allocator, r: std.Random, buffer: *std.ArrayList(u8), samples: []const Sample) !void {
    const length = buffer.items.len;
    if (length == 0) return;
    const at = r.uintLessThan(usize, length);
    switch (r.uintLessThan(u8, 6)) {
        0 => buffer.items[at] = r.int(u8),
        1 => {
            const span = @min(length - at, 1 + r.uintLessThan(usize, 256));
            try buffer.replaceRange(gpa, at, span, "");
        },
        2 => try buffer.insertSlice(gpa, at, dictionary[r.uintLessThan(usize, dictionary.len)]),
        3 => buffer.shrinkRetainingCapacity(at),
        4 => {
            const span = @min(length - at, 1 + r.uintLessThan(usize, 512));
            const copy = try gpa.dupe(u8, buffer.items[at .. at + span]);
            defer gpa.free(copy);
            try buffer.insertSlice(gpa, r.uintLessThan(usize, length), copy);
        },
        else => {
            const other = samples[r.uintLessThan(usize, samples.len)].bytes;
            if (other.len == 0) return;
            const from = r.uintLessThan(usize, other.len);
            const span = @min(other.len - from, 1 + r.uintLessThan(usize, 1024));
            try buffer.insertSlice(gpa, at, other[from .. from + span]);
        },
    }
}
