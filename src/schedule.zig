//! Local civil-time schedules with an injected conversion from epoch minutes.
//! Injected civil-time conversion makes timezone transitions testable without changing the host clock.

const std = @import("std");

/// Supported local-time recurrence patterns; manual schedules have no automatic occurrence.
pub const Kind = enum { manual, daily, weekdays, weekly };

/// Wall-clock recurrence with Sunday-based weekday numbers for weekly schedules.
pub const Schedule = struct { kind: Kind = .manual, time: []const u8 = "09:00", days: []const i64 = &.{} };

/// A Gregorian local date and wall-clock minute; offset is seconds east of UTC.
pub const Civil = struct {
    year: i64,
    month: u8,
    day: i64,
    weekday: u8,
    minute: u16,
    utc_offset: i64 = 0,

    /// Date equality ignores the offset so an autumn fold cannot run twice.
    pub fn sameDate(a: Civil, b: Civil) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// Validates bounded JSON fields before a schedule reaches storage.
pub fn parse(a: std.mem.Allocator, text: []const u8) !Schedule {
    const s = std.json.parseFromSliceLeaky(Schedule, a, text, .{}) catch return error.InvalidSchedule;
    if (s.time.len != 5 or s.time[2] != ':') return error.InvalidSchedule;
    for ([_]usize{ 0, 1, 3, 4 }) |i| if (!std.ascii.isDigit(s.time[i])) return error.InvalidSchedule;
    const hour = std.fmt.parseInt(u8, s.time[0..2], 10) catch return error.InvalidSchedule;
    const minute = std.fmt.parseInt(u8, s.time[3..], 10) catch return error.InvalidSchedule;
    if (hour > 23 or minute > 59 or s.days.len > 7) return error.InvalidSchedule;
    for (s.days) |d| if (d < 0 or d > 6) return error.InvalidSchedule;
    if (s.kind == .weekly and s.days.len == 0) return error.InvalidSchedule;
    return s;
}

fn allowed(s: Schedule, weekday: u8) bool {
    return switch (s.kind) {
        .manual => false,
        .daily => true,
        .weekdays => weekday >= 1 and weekday <= 5,
        .weekly => std.mem.indexOfScalar(i64, s.days, weekday) != null,
    };
}

/// The first valid local minute at or after the requested time fires once per
/// civil day. A spring gap advances to the next minute; a repeated hour fires once.
pub fn next(s: Schedule, after: i64, context: anytype, convert: anytype) ?i64 {
    if (s.kind == .manual) return null;
    const hour = std.fmt.parseInt(u16, s.time[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u16, s.time[3..], 10) catch return null;
    const target = hour * 60 + minute;
    var epoch = @divFloor(after, 60000) * 60000 + 60000;
    const initial = convert(context, after);
    var previous = initial;
    for (0..9 * 25 * 60) |_| {
        const c = convert(context, epoch);
        const crossed = c.minute >= target and (!c.sameDate(previous) or previous.minute < target);
        if (allowed(s, c.weekday) and crossed and (!c.sameDate(initial) or initial.minute < target)) return epoch;
        previous = c;
        epoch += 60000;
    }
    return null;
}

// Synthetic conversions model a known transition without mutating the process TZ.
test "spring advances nonexistent 02:30 to 03:00" {
    const Spring = struct {
        fn civil(_: void, ms: i64) Civil {
            const epoch = @divFloor(ms, 60000);
            const local = if (epoch >= 120) epoch + 60 else epoch;
            const day = @divFloor(local, 1440);
            return .{
                .year = 2026,
                .month = 3,
                .day = 8 + day,
                .weekday = @intCast(@mod(day, 7)),
                .minute = @intCast(@mod(local, 1440)),
                .utc_offset = if (epoch >= 120) -14400 else -18000,
            };
        }
    };
    const daily = Schedule{ .kind = .daily, .time = "02:30" };
    try std.testing.expectEqual(@as(?i64, 120 * 60000), next(daily, 0, {}, Spring.civil));
    try std.testing.expectEqual(@as(?i64, 1530 * 60000), next(daily, 120 * 60000, {}, Spring.civil));
    try std.testing.expectEqual(@as(?i64, null), next(.{}, 0, {}, Spring.civil));
}

test "autumn repeated 01:30 runs once on the same civil date" {
    const Autumn = struct {
        fn civil(_: void, ms: i64) Civil {
            const epoch = @divFloor(ms, 60000);
            const local = if (epoch >= 120) epoch - 60 else epoch;
            const day = @divFloor(local, 1440);
            return .{
                .year = 2026,
                .month = 11,
                .day = 1 + day,
                .weekday = @intCast(@mod(day, 7)),
                .minute = @intCast(@mod(local, 1440)),
                .utc_offset = if (epoch >= 120) -18000 else -14400,
            };
        }
    };
    const daily = Schedule{ .kind = .daily, .time = "01:30" };
    const first = next(daily, 0, {}, Autumn.civil);
    try std.testing.expectEqual(@as(?i64, 90 * 60000), first);
    try std.testing.expectEqual(@as(?i64, 1590 * 60000), next(daily, first.?, {}, Autumn.civil));
}

const TestUtc = struct {
    fn civil(_: void, ms: i64) Civil {
        const minute = @divFloor(ms, 60000);
        const day = @divFloor(minute, 1440);
        return .{
            .year = 2026,
            .month = 6,
            .day = day + 1,
            .weekday = @intCast(@mod(day + 1, 7)),
            .minute = @intCast(@mod(minute, 1440)),
        };
    }
};

test "weekday and weekly schedules select the next eligible date" {
    const weekdays = Schedule{ .kind = .weekdays, .time = "09:00" };
    try std.testing.expectEqual(
        @as(?i64, (7 * 1440 + 540) * 60000),
        next(weekdays, (4 * 1440 + 541) * 60000, {}, TestUtc.civil),
    );
    try std.testing.expectEqual(
        @as(?i64, (14 * 1440 + 540) * 60000),
        next(weekdays, (13 * 1440 + 600) * 60000, {}, TestUtc.civil),
    );

    const weekly = Schedule{ .kind = .weekly, .time = "09:00", .days = &.{ 2, 4 } };
    const tuesday = (1440 + 540) * 60000;
    const thursday = (3 * 1440 + 540) * 60000;
    try std.testing.expectEqual(@as(?i64, tuesday), next(weekly, 0, {}, TestUtc.civil));
    try std.testing.expectEqual(@as(?i64, thursday), next(weekly, tuesday, {}, TestUtc.civil));
}

test "civil dates distinguish adjacent years and months" {
    const december = Civil{ .year = 2026, .month = 12, .day = 31, .weekday = 4, .minute = 1439 };
    const january = Civil{ .year = 2027, .month = 1, .day = 1, .weekday = 5, .minute = 0 };
    try std.testing.expect(!december.sameDate(january));
    var next_month = january;
    next_month.month = 2;
    try std.testing.expect(!january.sameDate(next_month));
}

test "invalid schedules are rejected before scheduling" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"kind\":\"hourly\"}",
        "{\"kind\":\"weekly\",\"days\":[]}",
        "{\"time\":\"24:00\"}",
        "{\"days\":[-1]}",
        "{\"days\":[7]}",
    }) |bad| {
        try std.testing.expectError(error.InvalidSchedule, parse(arena.allocator(), bad));
    }
}
