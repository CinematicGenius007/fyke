//! Reader jobs and routine orchestration. All persistence goes through store.
const std = @import("std");
const core = @import("core");
const store = @import("store.zig");
const service = @import("service.zig");
const schedule = @import("schedule.zig");
const writer = @import("writer.zig");
const runner = @import("runner.zig");
pub const Writing = struct { view_id: ?i64 = null, rule: core.selector.Rule = .{}, recipe_id: i64 = 1, recipe_revision: i64, recipe_text: []const u8, question: ?[]const u8 = null, writer: []const u8, timeout_seconds: i64 = 180, preview: bool = false, entry_ids: ?[]const i64 = null };
pub const Action = struct { kind: enum { brief, notify, mark_read, star, tag }, recipe_id: i64 = 1, tag: ?[]const u8 = null };
pub fn validateActions(a: std.mem.Allocator, value: std.json.Value) !void {
    const actions = std.json.parseFromValueLeaky([]const Action, a, value, .{}) catch return error.InvalidActions;
    if (actions.len == 0 or actions.len > 16) return error.InvalidActions;
    for (actions) |action| if (action.kind == .tag) {
        const tag = action.tag orelse return error.InvalidActions;
        if (std.mem.trim(u8, tag, " \t\r\n").len == 0 or tag.len > 200) return error.InvalidActions;
    };
}
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, offset: c_long, zone: ?[*:0]const u8 };
extern fn localtime_r(*const i64, *Tm) ?*Tm;
extern fn _localtime64_s(*Tm, *const i64) c_int;
fn localCivil(_: void, ms: i64) schedule.Civil {
    var tm: Tm = undefined;
    const seconds = @divFloor(ms, 1000);
    if (@import("builtin").os.tag == .windows) {
        _ = _localtime64_s(&tm, &seconds);
    } else {
        _ = localtime_r(&seconds, &tm);
    }
    return .{ .day = @as(i64, tm.year) * 366 + tm.yday, .weekday = @intCast(tm.wday), .minute = @intCast(tm.hour * 60 + tm.min) };
}
pub fn nextRun(s: schedule.Schedule, now: i64) !?i64 {
    return schedule.next(s, now, {}, localCivil);
}
pub fn dryRun(db: *store.Db, a: std.mem.Allocator, id: i64, now: i64) !std.json.Value {
    const routine = try db.routineGet(a, id);
    const view = routine.object.get("view_id").?;
    if (view != .integer) return error.NoSuchView;
    const v = try db.viewGet(a, view.integer);
    const rule = try core.selector.parse(a, try text(a, v.object.get("rule").?));
    var days: std.ArrayList(std.json.Value) = .empty;
    var end = now;
    var total: i64 = 0;
    for (0..7) |_| {
        const start = dayStart(end);
        const selection = try db.selectRule(a, rule, end, 1, null, start - 1, end);
        total += selection.total;
        var tm: Tm = undefined;
        const seconds = @divFloor(start, 1000);
        if (@import("builtin").os.tag == .windows) {
            _ = _localtime64_s(&tm, &seconds);
        } else {
            _ = localtime_r(&seconds, &tm);
        }
        const date = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ tm.year + 1900, tm.mon + 1, tm.mday });
        try days.append(a, try store.object(a, .{ .from = start, .start = start, .until = end, .date = date, .count = selection.total, .actions = try dryActions(a, routine.object.get("actions").?, selection.total) }));
        end = start - 1;
    }
    std.mem.reverse(std.json.Value, days.items);
    return store.object(a, .{ .days = days.items, .actions = try dryActions(a, routine.object.get("actions").?, total) });
}
fn dryActions(a: std.mem.Allocator, value: std.json.Value, count: i64) ![]const std.json.Value {
    const actions = try std.json.parseFromValueLeaky([]const Action, a, value, .{});
    var results: std.ArrayList(std.json.Value) = .empty;
    for (actions) |action| {
        const verb: []const u8 = switch (action.kind) {
            .brief => "Write a brief from",
            .notify => "Notify about",
            .mark_read => "Mark read",
            .star => "Star",
            .tag => "Tag",
        };
        try results.append(a, try store.object(a, .{ .kind = @tagName(action.kind), .count = count, .summary = try std.fmt.allocPrint(a, "{s} {d} articles", .{ verb, count }) }));
    }
    return results.items;
}
fn dayStart(ms: i64) i64 {
    const day = localCivil({}, ms).day;
    var minute = @divFloor(ms, 60000) * 60000;
    for (0..26 * 60) |_| {
        if (localCivil({}, minute - 60000).day != day) return minute;
        minute -= 60000;
    }
    return minute;
}
pub fn queueRoutine(db: *store.Db, a: std.mem.Allocator, id: i64, now: i64) !std.json.Value {
    const routine = try db.routineGet(a, id);
    const view = routine.object.get("view_id").?;
    if (view != .integer) return error.NoSuchView;
    const v = try db.viewGet(a, view.integer);
    const rule = try core.selector.parse(a, try text(a, v.object.get("rule").?));
    const last = routine.object.get("last_run_at").?;
    const after: ?i64 = if (last == .integer) last.integer else null;
    const selection = try db.selectRule(a, rule, now, 2147483647, null, after, now);
    const ids = try a.alloc(i64, selection.items.len);
    for (selection.items, 0..) |e, i| ids[i] = e.id;
    const timing = try schedule.parse(a, try text(a, routine.object.get("schedule").?));
    return db.routineStart(a, id, ids, routine.object.get("actions").?, now, try nextRun(timing, now), view.integer, rule);
}
fn text(a: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(value, .{})});
}
pub fn loop(s: *service.Service) std.Io.Cancelable!void {
    runner.cleanup(s) catch |err| std.debug.print("writer cleanup: {s}\n", .{@errorName(err)});
    {
        const db = s.lockWriter();
        defer s.unlockWriter();
        db.recoverJobs(s.now()) catch |err| std.debug.print("reader recovery: {s}\n", .{@errorName(err)});
    }
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        s.jobs_wake.reset();
        const worked = tick(s, a) catch |err| blk: {
            std.debug.print("reader worker: {s}\n", .{@errorName(err)});
            break :blk false;
        };
        if (!worked) s.jobs_wake.waitTimeout(s.io, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
}
fn tick(s: *service.Service, a: std.mem.Allocator) !bool {
    const job = blk: {
        const db = s.lockWriter();
        defer s.unlockWriter();
        for (try db.dueRoutines(a, s.now())) |r| {
            _ = queueRoutine(db, a, r.object.get("id").?.integer, s.now()) catch |err| {
                std.debug.print("routine: {s}\n", .{@errorName(err)});
                continue;
            };
        }
        break :blk try db.jobClaim(a, s.now());
    };
    const claimed = job orelse return false;
    const id = claimed.object.get("id").?.integer;
    s.eventsChanged();
    const stage = claimed.object.get("stage").?.string;
    if (std.mem.eql(u8, stage, "routine")) {
        runRoutine(s, a, id, claimed.object.get("input").?) catch |err| {
            const db = s.lockWriter();
            defer s.unlockWriter();
            try db.routineFinish(id, "[]", if (err == error.JobCancelled) "cancelled" else "failed", s.now());
            try db.jobFinish(id, "failed", @errorName(err), s.now());
        };
    } else {
        const input = try std.json.parseFromValueLeaky(Writing, a, claimed.object.get("input").?, .{});
        write(s, a, id, input) catch |err| {
            const db = s.lockWriter();
            defer s.unlockWriter();
            try db.jobFinish(id, "failed", @errorName(err), s.now());
        };
    }
    s.eventsChanged();
    return true;
}
fn write(s: *service.Service, a: std.mem.Allocator, id: i64, input: Writing) !void {
    var total: i64 = undefined;
    const selected = blk: {
        const db = s.lockReader();
        defer s.unlockReader();
        if (input.entry_ids) |ids| {
            total = @intCast(ids.len);
            break :blk try db.writerSources(a, ids);
        }
        const selection = try db.selectRule(a, input.rule, s.now(), 60, null, null, null);
        total = selection.total;
        const ids = try a.alloc(i64, selection.items.len);
        for (selection.items, 0..) |entry, i| ids[i] = entry.id;
        break :blk try db.writerSources(a, ids);
    };
    var sources: std.ArrayList(writer.Source) = .empty;
    var used: usize = 0;
    for (selected) |source| {
        if (sources.items.len == 60 or used >= 120000) break;
        var item = source;
        const bound = try writer.prefix(item.text, 120000 - used);
        item.text = item.text[0..bound.bytes];
        used += bound.characters;
        try sources.append(a, item);
    }
    if (sources.items.len == 0) {
        const db = s.lockWriter();
        defer s.unlockWriter();
        try db.jobFinish(id, "done", null, s.now());
        return;
    }
    const prompt = try writer.prompt(a, input.recipe_text, input.question, sources.items);
    var result: writer.Output = undefined;
    var valid = false;
    for (0..2) |attempt| {
        const output = try runner.execute(s, a, id, input.writer, if (attempt == 0) prompt else try std.fmt.allocPrint(a, "{s}\nThe previous output failed JSON or citation validation. Return valid JSON; cite only supplied ids.\n", .{prompt}), input.timeout_seconds);
        result = writer.validate(a, output, sources.items) catch |err| {
            if (attempt == 1) return err;
            continue;
        };
        valid = true;
        break;
    }
    if (!valid) return error.InvalidWriterOutput;
    const ids = try a.alloc(i64, sources.items.len);
    for (sources.items, 0..) |source, i| ids[i] = source.id;
    const body = try writer.toBlocks(a, result);
    const db = s.lockWriter();
    defer s.unlockWriter();
    _ = try db.artifactSave(a, id, input, result, body, ids, total - @as(i64, @intCast(ids.len)), s.now());
}
fn runRoutine(s: *service.Service, a: std.mem.Allocator, job: i64, value: std.json.Value) !void {
    const Input = struct { routine_id: i64, matches: []const i64, actions: []const Action, view_id: i64, rule: core.selector.Rule };
    const input = try std.json.parseFromValueLeaky(Input, a, value, .{});
    var results: std.ArrayList(std.json.Value) = .empty;
    for (input.actions) |action| {
        {
            const db = s.lockWriter();
            defer s.unlockWriter();
            const current = try db.jobGet(a, job);
            if (std.mem.eql(u8, current.object.get("status").?.string, "cancelled")) {
                try db.routineFinish(job, try text(a, results.items), "cancelled", s.now());
                return;
            }
        }
        const result = actionResult(s, a, job, input, action) catch |err| try store.object(a, .{ .kind = @tagName(action.kind), .status = "failed", .error_name = @errorName(err) });
        try results.append(a, result);
    }
    var failed = false;
    for (results.items) |result| {
        if (std.mem.eql(u8, result.object.get("status").?.string, "failed")) failed = true;
    }
    const db = s.lockWriter();
    defer s.unlockWriter();
    try db.routineFinish(job, try text(a, results.items), if (failed) "failed" else "done", s.now());
    try db.jobFinish(job, if (failed) "failed" else "done", if (failed) "RoutineActionFailed" else null, s.now());
}
fn actionResult(s: *service.Service, a: std.mem.Allocator, job: i64, input: anytype, action: Action) !std.json.Value {
    const db = s.lockWriter();
    defer s.unlockWriter();
    const current = try db.jobGet(a, job);
    if (std.mem.eql(u8, current.object.get("status").?.string, "cancelled")) return error.JobCancelled;
    switch (action.kind) {
        .mark_read, .star => {
            var offset: usize = 0;
            while (offset < input.matches.len) {
                const end = @min(offset + 1000, input.matches.len);
                _ = try db.markMany(a, input.matches[offset..end], if (action.kind == .mark_read) .{ .read = true } else .{ .starred = true }, s.now());
                offset = end;
            }
        },
        .tag => try db.routineTag(a, input.matches, action.tag.?, try std.fmt.allocPrint(a, "routine:{d}", .{input.routine_id}), s.now()),
        .notify => try db.featureEvent("routine.notify", input.routine_id, s.now()),
        .brief => {
            const recipe = try db.recipeGet(a, action.recipe_id, null);
            const writing = Writing{ .view_id = input.view_id, .rule = input.rule, .recipe_id = action.recipe_id, .recipe_revision = recipe.object.get("revision").?.integer, .recipe_text = recipe.object.get("text").?.string, .writer = try runner.selected(s, a), .entry_ids = input.matches };
            const queued = try db.jobQueue(a, "brief", try text(a, writing), s.now());
            return store.object(a, .{ .kind = "brief", .status = "queued", .job_id = queued.object.get("id").?.integer, .count = input.matches.len });
        },
    }
    return store.object(a, .{ .kind = @tagName(action.kind), .status = "done", .count = input.matches.len });
}
